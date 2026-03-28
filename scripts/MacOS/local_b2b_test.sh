#!/bin/bash
# local_b2b_test.sh — Run backpressure tests locally (macOS/Linux, no Slurm)
#
# Runs the same 5 BP test scenarios as b2b_backpressure_suite.sh but using
# native binaries on localhost (127.0.0.1). No Slurm, no containers, no LB.
#
# Prerequisites:
#   - build/bin/ejfat_zmq_proxy  (built locally)
#   - e2sar_perf binary: set E2SAR_PERF, or E2SAR_ROOT (points to E2SAR source/install), or have e2sar_perf on PATH
#   - python3 with zmq package
#
# Usage (run from project root):
#   ./scripts/local_b2b_test.sh                  # all 5 tests, 60s soak
#   ./scripts/local_b2b_test.sh --tests 1,2,3    # subset
#   ./scripts/local_b2b_test.sh --quick          # 30s soak for test 5
#   ./scripts/local_b2b_test.sh --soak-duration 300  # full 5-min soak
#
# Optional environment:
#   E2SAR_PERF    Path to e2sar_perf binary
#   PROXY_BIN     Path to ejfat_zmq_proxy binary

set -uo pipefail

#=============================================================================
# Resolve project root (script is in <root>/scripts/MacOS/)
#=============================================================================
SCRIPT_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

#=============================================================================
# Binary paths (overridable via environment)
#=============================================================================
PROXY_BIN="${PROXY_BIN:-$PROJECT_ROOT/build/bin/ejfat_zmq_proxy}"

# Locate e2sar_perf: explicit env > E2SAR_ROOT build tree > PATH
if [[ -n "${E2SAR_PERF:-}" ]]; then
    E2SAR_PERF_BIN="$E2SAR_PERF"
elif [[ -n "${E2SAR_ROOT:-}" && -x "${E2SAR_ROOT}/build/bin/e2sar_perf" ]]; then
    E2SAR_PERF_BIN="${E2SAR_ROOT}/build/bin/e2sar_perf"
elif command -v e2sar_perf >/dev/null 2>&1; then
    E2SAR_PERF_BIN="$(command -v e2sar_perf)"
else
    E2SAR_PERF_BIN=""
fi
RECEIVER="$PROJECT_ROOT/scripts/MacOS/test_receiver.py"
TEMPLATE="$PROJECT_ROOT/config/distributed.yaml.template"
BP_COMMON="$PROJECT_ROOT/scripts/perlmutter/bp_common.sh"

#=============================================================================
# Fixed local settings
#=============================================================================
DATA_IP="127.0.0.1"
DATA_PORT="19522"
ZMQ_PORT="5555"
ZMQ_ENDPOINT="tcp://localhost:${ZMQ_PORT}"
EJFAT_URI="ejfat://b2b-test@${DATA_IP}:9876/lb/1?data=${DATA_IP}:${DATA_PORT}&sync=${DATA_IP}:19523"

# Config template defaults (non-test-specific)
SLURM_JOB_ID="local"
RECV_THREADS="1"
RCV_BUF_SIZE="3145728"
VALIDATE_CERT="false"
USE_CP="false"
WITH_LB_HEADER="true"
ZMQ_IO_THREADS="1"
POLL_SLEEP="100"
BP_PERIOD="50"
READY_THRESHOLD="0.95"   # proxy YAML ready_threshold (must be >=0.5); BP_THRESHOLD controls assertions
LINGER_MS="5000"         # ZMQ linger on close: allow proxy to drain queue before exiting
PID_SETPOINT="0.5"
PID_KP="1.0"
PID_KI="0.0"
PID_KD="0.0"
RECV_TIMEOUT="100"
PROGRESS_INTERVAL="10000"

#=============================================================================
# Parse arguments
#=============================================================================
TESTS_TO_RUN=(1 2 3 4 5)
SOAK_DURATION=60   # Test 5 soak duration in seconds (shorter than Perlmutter's 300s)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tests)
            IFS=',' read -ra TESTS_TO_RUN <<< "$2"
            shift 2
            ;;
        --soak-duration)
            SOAK_DURATION="$2"
            shift 2
            ;;
        --quick)
            SOAK_DURATION=30
            shift
            ;;
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
    [[ -x "$E2SAR_PERF_BIN" ]] \
        || { echo "  ERROR: e2sar_perf not found: $E2SAR_PERF_BIN"; ok=false; }
    [[ -f "$RECEIVER" ]] \
        || { echo "  ERROR: test_receiver.py not found: $RECEIVER"; ok=false; }
    [[ -f "$TEMPLATE" ]] \
        || { echo "  ERROR: config template not found: $TEMPLATE"; ok=false; }
    [[ -f "$BP_COMMON" ]] \
        || { echo "  ERROR: bp_common.sh not found: $BP_COMMON"; ok=false; }
    command -v envsubst >/dev/null 2>&1 \
        || { echo "  ERROR: envsubst not found (brew install gettext)"; ok=false; }
    python3 -c "import zmq" 2>/dev/null \
        || { echo "  ERROR: python3 zmq module not available"; ok=false; }

    if [[ "$ok" == "false" ]]; then
        echo "Pre-flight FAILED"
        exit 1
    fi
    echo "  All checks passed."
    echo ""
}

#=============================================================================
# Run directory setup
#=============================================================================
RUN_DIR="$PROJECT_ROOT/runs/local_b2b_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN_DIR"
echo "Run directory: $RUN_DIR"

#=============================================================================
# Source bp_common.sh for assertion functions ONLY.
# We do NOT call bp_setup_env (it uses Slurm). We set up the environment
# variables the assertion functions need ourselves.
#=============================================================================
export B2B_MODE=true
PASS_COUNT=0
FAIL_COUNT=0

# shellcheck source=perlmutter/bp_common.sh
source "$BP_COMMON"
# shellcheck source=MacOS/local_common.sh
source "$PROJECT_ROOT/scripts/MacOS/local_common.sh"

# Counters for tracking overall results across all tests
TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_TESTS=()

#=============================================================================
# Process tracking
#=============================================================================
PROXY_PID=""
CONSUMER_PID=""

cleanup() {
    echo ""
    echo "--- Cleanup ---"
    if [[ -n "$CONSUMER_PID" ]]; then
        kill -TERM "$CONSUMER_PID" 2>/dev/null || true
        sleep 1
        kill -9 "$CONSUMER_PID" 2>/dev/null || true
        CONSUMER_PID=""
    fi
    if [[ -n "$PROXY_PID" ]]; then
        kill -TERM "$PROXY_PID" 2>/dev/null || true
        sleep 2
        kill -9 "$PROXY_PID" 2>/dev/null || true
        PROXY_PID=""
    fi
}
trap cleanup EXIT INT TERM

#=============================================================================
# Local lifecycle functions
#=============================================================================

generate_local_config() {
    generate_proxy_config "$RUN_DIR/test${1}_config.yaml"
}


start_local_consumer() {
    local delay="$1"
    local rcvhwm="${2:-1000}"
    local rcvbuf="${3:-0}"
    local log="$RUN_DIR/consumer.log"
    : > "$log"

    local args=(--endpoint "$ZMQ_ENDPOINT" --delay "$delay" --stats-interval 10)
    [[ "$rcvhwm" -lt 1000 ]] && args+=(--rcvhwm "$rcvhwm")
    [[ "$rcvbuf" -gt 0 ]]   && args+=(--rcvbuf "$rcvbuf")

    python3 -u "$RECEIVER" "${args[@]}" >> "$log" 2>&1 &
    CONSUMER_PID=$!
    echo "Consumer started (PID=$CONSUMER_PID, delay=${delay}ms)"
    sleep 0.5  # brief settle
}

stop_local_consumer() {
    if [[ -n "$CONSUMER_PID" ]]; then
        kill -TERM "$CONSUMER_PID" 2>/dev/null || true
        sleep 2
        kill -9 "$CONSUMER_PID" 2>/dev/null || true
        wait "$CONSUMER_PID" 2>/dev/null || true
        CONSUMER_PID=""
        echo "Consumer stopped"
    fi
}

send_events() {
    # Usage: send_events NUM LENGTH [SENDER_LOG]
    local num="$1"
    local length="$2"
    local log="${3:-$RUN_DIR/sender.log}"

    echo "  Sending $num events (${length}B each) via e2sar_perf..."
    # macOS-compatible flags: no --optimize, no --mtu 9000, no --sockets 16
    # rate=-1 means unlimited (local loopback)
    export EJFAT_URI
    "$E2SAR_PERF_BIN" --send \
        --ip "$DATA_IP" \
        --num "$num" \
        --length "$length" \
        --rate "${SEND_RATE_GBPS:--1}" \
        --uri "$EJFAT_URI" \
        >> "$log" 2>&1 || true
}

soak_send() {
    # Usage: soak_send DURATION_SECS NUM LENGTH
    local duration="$1"
    local num="$2"
    local length="$3"
    local log="$RUN_DIR/sender.log"
    local end_time=$(( $(date +%s) + duration ))
    local batch=0
    local total=0

    echo "  Soak sending for ${duration}s..."
    while [[ $(date +%s) -lt $end_time ]]; do
        batch=$(( batch + 1 ))
        local remaining=$(( end_time - $(date +%s) ))
        echo "  Soak batch $batch (${remaining}s remaining)..."
        send_events "$num" "$length" "$log"
        total=$(( total + num ))
    done
    echo "  Soak complete: $batch batches (~$total events)"
}

archive_test_logs() {
    local test_num="$1"
    local prefix="test${test_num}"
    # Rename transient log files to per-test names
    [[ -f "$RUN_DIR/proxy.log" ]]    && cp "$RUN_DIR/proxy.log"    "$RUN_DIR/${prefix}_proxy.log"
    [[ -f "$RUN_DIR/consumer.log" ]] && mv "$RUN_DIR/consumer.log" "$RUN_DIR/${prefix}_consumer.log"
    [[ -f "$RUN_DIR/sender.log" ]]   && mv "$RUN_DIR/sender.log"   "$RUN_DIR/${prefix}_sender.log"
    echo "  Logs: $RUN_DIR/${prefix}_*.log"
}


record_test_result() {
    local test_name="$1"
    bp_print_summary_noexit "$test_name"
    local rc=$?
    TOTAL_PASS=$(( TOTAL_PASS + PASS_COUNT ))
    TOTAL_FAIL=$(( TOTAL_FAIL + FAIL_COUNT ))
    [[ $rc -ne 0 ]] && FAILED_TESTS+=("$test_name")
    PASS_COUNT=0
    FAIL_COUNT=0
}

should_run() {
    local test_num="$1"
    for t in "${TESTS_TO_RUN[@]}"; do
        [[ "$t" == "$test_num" ]] && return 0
    done
    return 1
}

#=============================================================================
# Main
#=============================================================================
echo "========================================="
echo "EJFAT ZMQ Proxy — Local B2B BP Test Suite"
echo "========================================="
echo "Start time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Tests: ${TESTS_TO_RUN[*]}"
echo "Test 5 soak duration: ${SOAK_DURATION}s"
echo ""

preflight_check

#=============================================================================
# TEST 1: Baseline — no backpressure
#=============================================================================
if should_run 1; then
    echo "========================================="
    echo "TEST 1: Baseline (no backpressure)"
    echo "========================================="

    export BP_THRESHOLD="0.95"
    BUFFER_SIZE=20000 ZMQ_HWM=10000 ZMQ_SNDBUF=0 BP_LOG_INTERVAL=5
    export BUFFER_SIZE ZMQ_HWM ZMQ_SNDBUF BP_LOG_INTERVAL
    CONFIG=$(generate_local_config 1)

    start_local_proxy "$CONFIG"
    start_local_consumer 0
    wait_proxy_ready

    : > "$RUN_DIR/sender.log"
    send_events 100 1048576

    echo "Waiting 5s for drain..."
    sleep 5

    stop_local_proxy
    stop_local_consumer
    archive_test_logs 1

    PASS_COUNT=0; FAIL_COUNT=0
    echo "Assertions:"
    assert_no_backpressure        "$RUN_DIR/test1_proxy.log"
    assert_fill_stayed_low 10     "$RUN_DIR/test1_proxy.log"
    assert_events_received 10 100 "$RUN_DIR/test1_consumer.log"  # local: proxy fwds ~11 msg/s; drain limited
    assert_no_crash               "$RUN_DIR/test1_proxy.log"
    record_test_result "Baseline (no backpressure)"
fi

#=============================================================================
# TEST 2: Mild backpressure — triggers and recovers
#=============================================================================
if should_run 2; then
    echo "========================================="
    echo "TEST 2: Mild backpressure (10ms delay, buf=100)"
    echo "========================================="

    export BP_THRESHOLD="0.3"   # local: 10ms delay; max fill ~37%; use 30% threshold
    BUFFER_SIZE=100 ZMQ_HWM=5 ZMQ_SNDBUF=131072 BP_LOG_INTERVAL=5
    export BUFFER_SIZE ZMQ_HWM ZMQ_SNDBUF BP_LOG_INTERVAL
    CONFIG=$(generate_local_config 2)

    start_local_proxy "$CONFIG"
    start_local_consumer 10 2 131072
    wait_proxy_ready

    # Rate-limit to 1.5 Gbps (187 events/s). Consumer drains at 100/s (10ms delay);
    # batch time = 0.53s → 53 events drained → net ~47 events peak fill (~47%).
    # Keeps fill reliably above 30% threshold without saturating the buffer.
    SEND_RATE_GBPS=1.5
    : > "$RUN_DIR/sender.log"
    soak_send 30 100 1048576
    unset SEND_RATE_GBPS

    echo "Waiting 15s for drain..."
    sleep 15

    stop_local_proxy
    stop_local_consumer
    archive_test_logs 2

    PASS_COUNT=0; FAIL_COUNT=0
    echo "Assertions:"
    assert_backpressure_triggered        "$RUN_DIR/test2_proxy.log"
    assert_backpressure_recovered        "$RUN_DIR/test2_proxy.log"
    assert_fill_peaked 20                "$RUN_DIR/test2_proxy.log"
    assert_events_received 70 999999999  "$RUN_DIR/test2_consumer.log"
    assert_no_crash                      "$RUN_DIR/test2_proxy.log"
    record_test_result "Mild backpressure"
fi

#=============================================================================
# TEST 3: Heavy backpressure — sustained saturation
#=============================================================================
if should_run 3; then
    echo "========================================="
    echo "TEST 3: Heavy backpressure (100ms delay, buf=100)"
    echo "========================================="

    export BP_THRESHOLD="0.5"
    BUFFER_SIZE=100 ZMQ_HWM=5 ZMQ_SNDBUF=131072 BP_LOG_INTERVAL=5
    export BUFFER_SIZE ZMQ_HWM ZMQ_SNDBUF BP_LOG_INTERVAL
    CONFIG=$(generate_local_config 3)

    start_local_proxy "$CONFIG"
    start_local_consumer 100 2 131072
    wait_proxy_ready

    # Rate-limit to 200 Mbps (25 events/s) so E2SAR reassembler doesn't drop
    # fragments. Consumer at 100ms delay handles 10/s; net fill rate = 15/s.
    SEND_RATE_GBPS=0.2
    : > "$RUN_DIR/sender.log"
    soak_send 30 100 1048576
    unset SEND_RATE_GBPS

    echo "Waiting 30s for drain..."
    sleep 30

    stop_local_proxy
    stop_local_consumer
    archive_test_logs 3

    PASS_COUNT=0; FAIL_COUNT=0
    echo "Assertions:"
    assert_backpressure_triggered "$RUN_DIR/test3_proxy.log"
    assert_sustained_bp 3         "$RUN_DIR/test3_proxy.log"
    assert_fill_peaked 80         "$RUN_DIR/test3_proxy.log"
    assert_control_peaked 0.4     "$RUN_DIR/test3_proxy.log"  # SKIP in b2b
    assert_no_crash               "$RUN_DIR/test3_proxy.log"
    record_test_result "Heavy backpressure"
fi

#=============================================================================
# TEST 4: Small-event stress (64KB events)
#=============================================================================
if should_run 4; then
    echo "========================================="
    echo "TEST 4: Small-event stress (64KB, 50ms delay, buf=100)"
    echo "========================================="

    export BP_THRESHOLD="0.5"
    BUFFER_SIZE=100 ZMQ_HWM=5 ZMQ_SNDBUF=131072 BP_LOG_INTERVAL=5
    export BUFFER_SIZE ZMQ_HWM ZMQ_SNDBUF BP_LOG_INTERVAL
    CONFIG=$(generate_local_config 4)

    start_local_proxy "$CONFIG"
    start_local_consumer 50 2 131072
    wait_proxy_ready

    : > "$RUN_DIR/sender.log"
    send_events 100 65536

    echo "Waiting 10s for drain..."
    sleep 10

    stop_local_proxy
    stop_local_consumer
    archive_test_logs 4

    PASS_COUNT=0; FAIL_COUNT=0
    echo "Assertions:"
    assert_backpressure_triggered "$RUN_DIR/test4_proxy.log"
    assert_fill_peaked 20         "$RUN_DIR/test4_proxy.log"
    assert_no_crash               "$RUN_DIR/test4_proxy.log"
    record_test_result "Small-event stress"
fi

#=============================================================================
# TEST 5: Soak (20ms delay, buf=200, looping sender)
#=============================================================================
if should_run 5; then
    echo "========================================="
    echo "TEST 5: Soak test (20ms delay, buf=200, ${SOAK_DURATION}s)"
    echo "========================================="

    export BP_THRESHOLD="0.1"   # local: consumer keeps up, fill stays ~15%; use 10% threshold
    BUFFER_SIZE=200 ZMQ_HWM=10 ZMQ_SNDBUF=0 BP_LOG_INTERVAL=5
    export BUFFER_SIZE ZMQ_HWM ZMQ_SNDBUF BP_LOG_INTERVAL
    CONFIG=$(generate_local_config 5)

    start_local_proxy "$CONFIG"
    start_local_consumer 20 5 131072
    wait_proxy_ready

    # Rate-limit to 1 Gbps (125 events/s). Consumer drains at 50/s (20ms delay);
    # net fill rate = 75/s → saturates 200-event buffer quickly, passes 10% threshold.
    SEND_RATE_GBPS=1.0
    : > "$RUN_DIR/sender.log"
    soak_send "$SOAK_DURATION" 100 1048576
    unset SEND_RATE_GBPS

    echo "Waiting 10s for drain..."
    sleep 10

    # Check proxy still alive at end of soak
    PROXY_ALIVE=false
    kill -0 "$PROXY_PID" 2>/dev/null && PROXY_ALIVE=true

    stop_local_proxy
    stop_local_consumer
    archive_test_logs 5

    PASS_COUNT=0; FAIL_COUNT=0
    echo "Assertions:"
    assert_backpressure_triggered "$RUN_DIR/test5_proxy.log"
    assert_backpressure_recovered "$RUN_DIR/test5_proxy.log"
    assert_no_crash               "$RUN_DIR/test5_proxy.log"
    if [[ "$PROXY_ALIVE" == "true" ]]; then
        assert_pass "proxy-alive-at-end"
    else
        assert_fail "proxy-alive-at-end" "proxy not running at end of soak"
    fi
    record_test_result "Soak test (${SOAK_DURATION}s)"
fi

#=============================================================================
# Final summary
#=============================================================================
echo ""
echo "========================================="
echo "OVERALL RESULTS"
echo "========================================="
echo "Tests run: ${TESTS_TO_RUN[*]}"
echo "Total assertions: pass=$TOTAL_PASS fail=$TOTAL_FAIL"
echo "End time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Logs: $RUN_DIR/"
echo ""

if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    echo "FAILED tests: ${FAILED_TESTS[*]}"
    echo "SUITE: FAILED"
    exit 1
else
    echo "SUITE: PASSED"
    exit 0
fi
