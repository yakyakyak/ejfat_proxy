#!/bin/bash
#SBATCH -N 4
#SBATCH -C cpu
#SBATCH -q debug
#SBATCH -t 00:30:00
#SBATCH -J ejfat_pipeline_test
#
# EJFAT ZMQ Pipeline End-to-End Test on Perlmutter
#
# Tests full round-trip data integrity:
#   Node 0 (sender)    : pipeline_sender.py   -- ZMQ PUSH (seq-numbered messages)
#   Node 1 (bridge)    : zmq_ejfat_bridge     -- ZMQ PULL -> EJFAT Segmenter
#   Node 2 (proxy)     : ejfat_zmq_proxy      -- EJFAT Reassembler -> ZMQ PUSH
#   Node 3 (validator) : pipeline_validator.py -- ZMQ PULL + seq/payload validation
#
# Usage:
#   export EJFAT_URI="ejfats://token@lb.es.net:443/lb/xyz?..."
#   export E2SAR_SCRIPTS_DIR="/path/to/ejfat_proxy/scripts/perlmutter"
#   sbatch -A <account> perlmutter_pipeline_test.sh [OPTIONS]
#
# Options:
#   --count N       Messages to send (default: 1000)
#   --size N        Message size in bytes (default: 4096)
#   --rate N        Messages per second (default: 100)

set -euo pipefail

#=============================================================================
# Parse arguments
#=============================================================================

SENDER_COUNT="1000"
SENDER_SIZE="4096"
SENDER_RATE="100"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --count) SENDER_COUNT="$2"; shift 2 ;;
        --size)  SENDER_SIZE="$2";  shift 2 ;;
        --rate)  SENDER_RATE="$2";  shift 2 ;;
        *)
            echo "ERROR: Unknown argument: $1"
            echo "Usage: $0 [--count N] [--size N] [--rate N]"
            exit 1
            ;;
    esac
done

#=============================================================================
# Environment setup
#=============================================================================

echo "========================================="
echo "EJFAT ZMQ Pipeline Test - SLURM Job $SLURM_JOB_ID"
echo "========================================="
echo "Start time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

if [[ -z "${EJFAT_URI:-}" ]]; then
    echo "ERROR: EJFAT_URI is required"
    exit 1
fi

EJFAT_URI_REDACTED=$(echo "$EJFAT_URI" \
    | sed -E 's|(://)(.{4})[^@]*(.{4})@|\1\2---\3@|')
echo "EJFAT_URI: $EJFAT_URI_REDACTED"
echo "Job nodes: $SLURM_JOB_NODELIST"
echo ""

if [[ -z "${E2SAR_SCRIPTS_DIR:-}" ]]; then
    echo "ERROR: E2SAR_SCRIPTS_DIR must be set to the scripts/perlmutter directory"
    exit 1
fi
SCRIPT_DIR="$E2SAR_SCRIPTS_DIR"

RUNS_DIR="${SLURM_SUBMIT_DIR}/runs"
mkdir -p "$RUNS_DIR"
JOB_DIR="${RUNS_DIR}/slurm_job_${SLURM_JOB_ID}"
mkdir -p "$JOB_DIR"
cd "$JOB_DIR"
echo "Working directory: $JOB_DIR"

# Assign nodes
NODE_ARRAY=($(scontrol show hostname $SLURM_JOB_NODELIST))
if [[ ${#NODE_ARRAY[@]} -lt 4 ]]; then
    echo "ERROR: Need at least 4 nodes, got ${#NODE_ARRAY[@]}"
    exit 1
fi

NODE_SENDER="${NODE_ARRAY[0]}"    # N1 - pipeline_sender
NODE_BRIDGE="${NODE_ARRAY[1]}"    # N2 - zmq_ejfat_bridge
NODE_PROXY="${NODE_ARRAY[2]}"     # N3 - ejfat_zmq_proxy
NODE_VALIDATOR="${NODE_ARRAY[3]}" # N4 - pipeline_validator

echo "Node assignments:"
echo "  N1 Sender    : $NODE_SENDER"
echo "  N2 Bridge    : $NODE_BRIDGE"
echo "  N3 Proxy     : $NODE_PROXY"
echo "  N4 Validator : $NODE_VALIDATOR"
echo ""

# ZMQ ports
SENDER_ZMQ_PORT="${SENDER_ZMQ_PORT:-5556}"   # N1 -> N2
ZMQ_PORT="${ZMQ_PORT:-5555}"                  # N3 -> N4

export SENDER_ZMQ_PORT ZMQ_PORT
export PROXY_NODE="$NODE_PROXY"
export SENDER_NODE="$NODE_SENDER"

echo "ZMQ N1->N2 : tcp://$NODE_SENDER:$SENDER_ZMQ_PORT"
echo "ZMQ N3->N4 : tcp://$NODE_PROXY:$ZMQ_PORT"
echo ""

#=============================================================================
# Cleanup trap
#=============================================================================

CLEANUP_DONE=false
PROXY_PID=""
BRIDGE_PID=""
VALIDATOR_PID=""

cleanup() {
    [[ "$CLEANUP_DONE" == "true" ]] && return
    CLEANUP_DONE=true

    echo ""
    echo "========================================="
    echo "Cleanup: Stopping Background Processes"
    echo "========================================="

    for pid_var in PROXY_PID BRIDGE_PID VALIDATOR_PID; do
        pid="${!pid_var}"
        [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
    done

    sleep 2

    for pid_var in PROXY_PID BRIDGE_PID VALIDATOR_PID; do
        pid="${!pid_var}"
        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    done

    if [[ -f "$JOB_DIR/INSTANCE_URI" ]]; then
        echo ""
        echo "Freeing load balancer reservation..."
        cd "$JOB_DIR"
        "$SCRIPT_DIR/minimal_free.sh" 2>/dev/null \
            || echo "WARNING: Failed to free LB reservation"
    fi
}

trap cleanup EXIT INT TERM

#=============================================================================
# Phase 1: Reserve Load Balancer
#=============================================================================

echo "========================================="
echo "Phase 1: Reserve Load Balancer"
echo "========================================="

export EJFAT_URI
if ! "$SCRIPT_DIR/minimal_reserve.sh"; then
    echo "ERROR: Failed to reserve load balancer"
    exit 1
fi

[[ -f "INSTANCE_URI" ]] || { echo "ERROR: INSTANCE_URI not found"; exit 1; }
echo "Reservation ready"
echo ""

#=============================================================================
# Phase 2: Start Proxy on N3 (background)
#=============================================================================

echo "========================================="
echo "Phase 2: Start Proxy on $NODE_PROXY"
echo "========================================="

srun --nodes=1 --ntasks=1 --nodelist="$NODE_PROXY" \
    bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/run_proxy.sh'" \
    > proxy_wrapper.log 2>&1 &

PROXY_PID=$!
echo "Proxy started (PID: $PROXY_PID)"
echo ""

#=============================================================================
# Phase 3: Start Validator on N4 (background)
#=============================================================================

echo "========================================="
echo "Phase 3: Start Validator on $NODE_VALIDATOR"
echo "========================================="

srun --nodes=1 --ntasks=1 --nodelist="$NODE_VALIDATOR" \
    bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/run_pipeline_validator.sh' \
        --expected '$SENDER_COUNT' --timeout 60" \
    > validator_wrapper.log 2>&1 &

VALIDATOR_PID=$!
echo "Validator started (PID: $VALIDATOR_PID)"
echo ""

#=============================================================================
# Phase 4: Wait for proxy to register with LB
#=============================================================================

echo "========================================="
echo "Phase 4: Wait for Proxy Registration"
echo "========================================="

WAIT_TIME=15
echo "Waiting ${WAIT_TIME}s for proxy to register with load balancer..."
sleep $WAIT_TIME

if ! kill -0 "$PROXY_PID" 2>/dev/null; then
    echo "ERROR: Proxy process died during registration"
    cat proxy_wrapper.log proxy.log 2>/dev/null || true
    exit 1
fi
echo "Proxy is running"
echo ""

#=============================================================================
# Phase 5: Start Bridge on N2 (background)
#=============================================================================

echo "========================================="
echo "Phase 5: Start Bridge on $NODE_BRIDGE"
echo "========================================="

srun --nodes=1 --ntasks=1 --nodelist="$NODE_BRIDGE" \
    bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/run_zmq_ejfat_bridge.sh'" \
    > bridge_wrapper.log 2>&1 &

BRIDGE_PID=$!
echo "Bridge started (PID: $BRIDGE_PID)"
echo ""

#=============================================================================
# Phase 6: Run Sender on N1 (foreground — job waits here)
#=============================================================================

echo "========================================="
echo "Phase 6: Run Sender on $NODE_SENDER"
echo "========================================="

echo "  count=${SENDER_COUNT}  size=${SENDER_SIZE}  rate=${SENDER_RATE}"
echo ""

srun --nodes=1 --ntasks=1 --nodelist="$NODE_SENDER" \
    bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/run_pipeline_sender.sh' \
        --count '$SENDER_COUNT' --size '$SENDER_SIZE' --rate '$SENDER_RATE'"

SENDER_EXIT=$?
echo ""
echo "Sender completed (exit code: $SENDER_EXIT)"
echo ""

#=============================================================================
# Phase 7: Wait for validator to finish
#=============================================================================

echo "========================================="
echo "Phase 7: Wait for Validator"
echo "========================================="

# Give the pipeline time to drain, then wait for validator to exit
DRAIN_TIME=10
echo "Waiting ${DRAIN_TIME}s for pipeline to drain..."
sleep $DRAIN_TIME

echo "Waiting for validator process to finish..."
wait "$VALIDATOR_PID" && VALIDATOR_EXIT=0 || VALIDATOR_EXIT=$?
VALIDATOR_PID=""

echo "Validator exited (exit code: $VALIDATOR_EXIT)"
echo ""

#=============================================================================
# Phase 8: Summary
#=============================================================================

echo "========================================="
echo "Test Summary"
echo "========================================="
echo ""
echo "Log sizes:"
ls -lh proxy.log bridge.log sender.log validator.log 2>/dev/null \
    || echo "  Some logs missing"

echo ""
echo "--- Sender (last 20 lines) ---"
tail -20 sender.log 2>/dev/null || echo "  sender.log not found"

echo ""
echo "--- Validator (last 30 lines) ---"
tail -30 validator.log 2>/dev/null || echo "  validator.log not found"

echo ""
echo "--- Bridge (last 20 lines) ---"
tail -20 bridge.log 2>/dev/null || echo "  bridge.log not found"

echo ""
echo "--- Proxy (last 20 lines) ---"
tail -20 proxy.log 2>/dev/null || echo "  proxy.log not found"

echo ""
echo "========================================="
if [[ $VALIDATOR_EXIT -eq 0 ]]; then
    echo "RESULT: PASS"
else
    echo "RESULT: FAIL (validator exit code: $VALIDATOR_EXIT)"
fi
echo "End time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Logs: $JOB_DIR"
echo "========================================="

# Exit with validator's code — it's the ground truth for pass/fail
exit $VALIDATOR_EXIT
