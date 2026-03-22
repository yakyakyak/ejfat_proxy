#!/bin/bash
# local_pipeline_test.sh — Run the pipeline data-integrity test locally (macOS/Linux, no Slurm)
#
# Tests full round-trip data integrity through the pipeline:
#   pipeline_sender.py   (ZMQ PUSH bind :5556)
#     -> zmq_ejfat_bridge  (ZMQ PULL -> E2SAR Segmenter -> UDP :19522)
#     -> ejfat_zmq_proxy   (E2SAR Reassembler :19522 -> ZMQ PUSH :5555)
#     -> pipeline_validator.py  (ZMQ PULL, validates sequence + payload)
#
# All components run on 127.0.0.1. No Slurm, no containers, no load balancer.
#
# Prerequisites:
#   - build/bin/ejfat_zmq_proxy    (built locally)
#   - build/bin/zmq_ejfat_bridge   (built locally — requires --no-cp support)
#   - python3 with zmq package
#
# Usage (run from project root):
#   ./scripts/local_pipeline_test.sh                       # 1000 msgs, 4096B
#   ./scripts/local_pipeline_test.sh --count 100           # fewer messages
#   ./scripts/local_pipeline_test.sh --count 500 --size 1024 --rate 200
#
# Optional environment:
#   PROXY_BIN       Path to ejfat_zmq_proxy binary
#   BRIDGE_BIN      Path to zmq_ejfat_bridge binary

set -uo pipefail

#=============================================================================
# Resolve project root
#=============================================================================
SCRIPT_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

#=============================================================================
# Binary / script paths (overridable via environment)
#=============================================================================
PROXY_BIN="${PROXY_BIN:-$PROJECT_ROOT/build/bin/ejfat_zmq_proxy}"
BRIDGE_BIN="${BRIDGE_BIN:-$PROJECT_ROOT/build/bin/zmq_ejfat_bridge}"
SENDER_BIN="${SENDER_BIN:-$PROJECT_ROOT/build/bin/pipeline_sender}"
VALIDATOR_BIN="${VALIDATOR_BIN:-$PROJECT_ROOT/build/bin/pipeline_validator}"
TEMPLATE="$PROJECT_ROOT/config/perlmutter_b2b.yaml.template"

#=============================================================================
# Fixed local settings
#=============================================================================
DATA_IP="127.0.0.1"
DATA_PORT="19522"
SENDER_ZMQ_PORT="5556"     # pipeline_sender.py -> zmq_ejfat_bridge
ZMQ_PORT="5555"            # ejfat_zmq_proxy -> pipeline_validator.py

# Dummy EJFAT URI: no real LB; bridge uses data= to target proxy's UDP port
EJFAT_URI="ejfat://b2b-test@${DATA_IP}:9876/lb/1?data=${DATA_IP}:${DATA_PORT}&sync=${DATA_IP}:19523"

# Config template defaults (non-test-specific)
SLURM_JOB_ID="local"
RECV_THREADS="1"
RCV_BUF_SIZE="3145728"
VALIDATE_CERT="false"
USE_IPV6="false"
ZMQ_HWM="10000"
ZMQ_IO_THREADS="1"
POLL_SLEEP="100"
BP_PERIOD="50"
READY_THRESHOLD="0.95"
BP_LOG_INTERVAL="5"
LINGER_MS="5000"
ZMQ_SNDBUF="0"
PID_SETPOINT="0.5"
PID_KP="1.0"
PID_KI="0.0"
PID_KD="0.0"
BUFFER_SIZE="10000"
RECV_TIMEOUT="100"
LOG_VERBOSITY="1"
PROGRESS_INTERVAL="1000"

#=============================================================================
# Parse arguments
#=============================================================================
SENDER_COUNT="1000"
SENDER_SIZE="4096"
SENDER_RATE="0"   # 0 = unlimited

while [[ $# -gt 0 ]]; do
    case "$1" in
        --count) SENDER_COUNT="$2"; shift 2 ;;
        --size)  SENDER_SIZE="$2";  shift 2 ;;
        --rate)  SENDER_RATE="$2";  shift 2 ;;
        --help|-h)
            sed -n '2,/^set /p' "$SCRIPT_FILE" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1 (use --help)"
            exit 1
            ;;
    esac
done

#=============================================================================
# Pre-flight checks
#=============================================================================
preflight_check() {
    local ok=true
    echo "Pre-flight checks..."

    [[ -x "$PROXY_BIN" ]] \
        || { echo "  ERROR: proxy binary not found: $PROXY_BIN"; ok=false; }
    [[ -x "$BRIDGE_BIN" ]] \
        || { echo "  ERROR: bridge binary not found: $BRIDGE_BIN"; ok=false; }
    [[ -x "$SENDER_BIN" ]] \
        || { echo "  ERROR: pipeline_sender binary not found: $SENDER_BIN"; ok=false; }
    [[ -x "$VALIDATOR_BIN" ]] \
        || { echo "  ERROR: pipeline_validator binary not found: $VALIDATOR_BIN"; ok=false; }
    [[ -f "$TEMPLATE" ]] \
        || { echo "  ERROR: config template not found: $TEMPLATE"; ok=false; }
    command -v envsubst >/dev/null 2>&1 \
        || { echo "  ERROR: envsubst not found (brew install gettext)"; ok=false; }

    if [[ "$ok" == "false" ]]; then
        echo "Pre-flight FAILED"
        exit 1
    fi
    echo "  All checks passed."
    echo ""
}

#=============================================================================
# Run directory
#=============================================================================
RUN_DIR="$PROJECT_ROOT/runs/local_pipeline_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN_DIR"
echo "Run directory: $RUN_DIR"

#=============================================================================
# Process tracking
#=============================================================================
PROXY_PID=""
BRIDGE_PID=""
VALIDATOR_PID=""
CLEANUP_DONE=false

cleanup() {
    [[ "$CLEANUP_DONE" == "true" ]] && return
    CLEANUP_DONE=true

    echo ""
    echo "--- Cleanup ---"
    for pid_var in VALIDATOR_PID BRIDGE_PID PROXY_PID; do
        local pid="${!pid_var}"
        [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 2
    for pid_var in VALIDATOR_PID BRIDGE_PID PROXY_PID; do
        local pid="${!pid_var}"
        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    done
    VALIDATOR_PID=""
    BRIDGE_PID=""
    PROXY_PID=""
}

trap cleanup EXIT INT TERM

#=============================================================================
# Lifecycle functions
#=============================================================================

generate_config() {
    local out="$RUN_DIR/proxy_config.yaml"

    export EJFAT_URI DATA_IP DATA_PORT SLURM_JOB_ID ZMQ_PORT
    export RECV_THREADS RCV_BUF_SIZE VALIDATE_CERT USE_IPV6
    export ZMQ_HWM ZMQ_IO_THREADS POLL_SLEEP ZMQ_SNDBUF
    export BP_PERIOD READY_THRESHOLD BP_LOG_INTERVAL LINGER_MS
    export PID_SETPOINT PID_KP PID_KI PID_KD
    export BUFFER_SIZE RECV_TIMEOUT LOG_VERBOSITY PROGRESS_INTERVAL

    envsubst < "$TEMPLATE" > "$out"
    echo "$out"
}

start_proxy() {
    local config="$1"
    local log="$RUN_DIR/proxy.log"
    : > "$log"

    "$PROXY_BIN" -c "$config" >> "$log" 2>&1 &
    PROXY_PID=$!
    echo "Proxy started (PID=$PROXY_PID)"
}

wait_proxy_ready() {
    local log="$RUN_DIR/proxy.log"
    local i
    for i in $(seq 1 30); do
        if grep -q "All components started" "$log" 2>/dev/null; then
            echo "Proxy ready (after ${i}s)"
            return 0
        fi
        if ! kill -0 "$PROXY_PID" 2>/dev/null; then
            echo "ERROR: Proxy died during startup. Last lines:"
            tail -20 "$log" || true
            return 1
        fi
        sleep 1
    done
    echo "ERROR: Proxy never became ready (30s timeout). Last lines:"
    tail -20 "$log" || true
    return 1
}

stop_proxy() {
    if [[ -n "$PROXY_PID" ]]; then
        kill -TERM "$PROXY_PID" 2>/dev/null || true
        local i
        for i in $(seq 1 10); do
            kill -0 "$PROXY_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$PROXY_PID" 2>/dev/null || true
        wait "$PROXY_PID" 2>/dev/null || true
        PROXY_PID=""
        echo "Proxy stopped"
    fi
    sleep 2  # brief pause for port release
}

start_bridge() {
    local log="$RUN_DIR/bridge.log"
    : > "$log"

    "$BRIDGE_BIN" \
        --uri "$EJFAT_URI" \
        --zmq-endpoint "tcp://localhost:${SENDER_ZMQ_PORT}" \
        --mtu 1500 \
        --sockets 1 \
        --no-cp \
        >> "$log" 2>&1 &
    BRIDGE_PID=$!
    echo "Bridge started (PID=$BRIDGE_PID)"
}

wait_bridge_ready() {
    local log="$RUN_DIR/bridge.log"
    local i
    for i in $(seq 1 15); do
        if grep -q "ZMQ EJFAT Bridge started" "$log" 2>/dev/null; then
            echo "Bridge ready (after ${i}s)"
            return 0
        fi
        if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
            echo "ERROR: Bridge died during startup. Last lines:"
            tail -20 "$log" || true
            return 1
        fi
        sleep 1
    done
    echo "ERROR: Bridge never became ready (15s timeout). Last lines:"
    tail -20 "$log" || true
    return 1
}

start_validator() {
    local log="$RUN_DIR/validator.log"
    : > "$log"

    # Timeout: allow generous silence window for slow E2SAR reassembly pipelines
    local timeout="${VALIDATOR_TIMEOUT:-120}"

    "$VALIDATOR_BIN" \
        --endpoint "tcp://localhost:${ZMQ_PORT}" \
        --expected "$SENDER_COUNT" \
        --timeout "$timeout" \
        >> "$log" 2>&1 &
    VALIDATOR_PID=$!
    echo "Validator started (PID=$VALIDATOR_PID)"
}

run_sender() {
    local log="$RUN_DIR/sender.log"
    : > "$log"

    echo "  Sending $SENDER_COUNT messages (${SENDER_SIZE}B each)..."
    # Run sender foreground (blocks until all sent)
    "$SENDER_BIN" \
        --endpoint "tcp://*:${SENDER_ZMQ_PORT}" \
        --count "$SENDER_COUNT" \
        --size "$SENDER_SIZE" \
        --rate "$SENDER_RATE" \
        2>&1 | tee "$log"
    return ${PIPESTATUS[0]}
}

#=============================================================================
# Main
#=============================================================================
echo "========================================="
echo "EJFAT ZMQ Proxy — Local Pipeline Test"
echo "========================================="
echo "Start time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "  Messages : $SENDER_COUNT"
echo "  Size     : ${SENDER_SIZE}B"
echo "  Rate     : $([ "$SENDER_RATE" -eq 0 ] && echo unlimited || echo "${SENDER_RATE} msg/s")"
echo ""

preflight_check

#=============================================================================
# Phase 1: Generate config and start proxy
#=============================================================================
echo "========================================="
echo "Phase 1: Start Proxy"
echo "========================================="

CONFIG=$(generate_config)
echo "Config: $CONFIG"
start_proxy "$CONFIG"
wait_proxy_ready
echo ""

#=============================================================================
# Phase 2: Start validator (background)
#=============================================================================
echo "========================================="
echo "Phase 2: Start Validator"
echo "========================================="

start_validator
sleep 0.5  # brief settle
echo ""

#=============================================================================
# Phase 3: Start bridge (background)
#=============================================================================
echo "========================================="
echo "Phase 3: Start Bridge"
echo "========================================="

start_bridge
wait_bridge_ready
echo ""

#=============================================================================
# Phase 4: Run sender (foreground — blocks until done)
#=============================================================================
echo "========================================="
echo "Phase 4: Run Sender"
echo "========================================="

run_sender
SENDER_EXIT=$?
echo "Sender finished (exit=$SENDER_EXIT)"
echo ""

#=============================================================================
# Phase 5: Drain and wait for validator
#=============================================================================
echo "========================================="
echo "Phase 5: Drain and Wait for Validator"
echo "========================================="

DRAIN="${DRAIN_TIME:-30}"
echo "Waiting ${DRAIN}s for pipeline to drain..."
sleep $DRAIN

echo "Waiting for validator to finish..."
wait "$VALIDATOR_PID" && VALIDATOR_EXIT=0 || VALIDATOR_EXIT=$?
VALIDATOR_PID=""
echo "Validator exited (exit=$VALIDATOR_EXIT)"
echo ""

#=============================================================================
# Phase 6: Stop remaining processes and print summary
#=============================================================================
kill -TERM "$BRIDGE_PID" 2>/dev/null || true
wait "$BRIDGE_PID" 2>/dev/null || true
BRIDGE_PID=""

stop_proxy

echo "========================================="
echo "Test Summary"
echo "========================================="
echo ""
echo "--- Sender (last 10 lines) ---"
tail -10 "$RUN_DIR/sender.log" 2>/dev/null || echo "  sender.log not found"

echo ""
echo "--- Validator (last 20 lines) ---"
tail -20 "$RUN_DIR/validator.log" 2>/dev/null || echo "  validator.log not found"

echo ""
echo "--- Bridge (last 10 lines) ---"
tail -10 "$RUN_DIR/bridge.log" 2>/dev/null || echo "  bridge.log not found"

echo ""
echo "--- Proxy (last 10 lines) ---"
tail -10 "$RUN_DIR/proxy.log" 2>/dev/null || echo "  proxy.log not found"

echo ""
echo "========================================="
if [[ $VALIDATOR_EXIT -eq 0 ]]; then
    echo "RESULT: PASS"
else
    echo "RESULT: FAIL (validator exit code: $VALIDATOR_EXIT)"
fi
echo "End time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Logs: $RUN_DIR/"
echo "========================================="

exit $VALIDATOR_EXIT
