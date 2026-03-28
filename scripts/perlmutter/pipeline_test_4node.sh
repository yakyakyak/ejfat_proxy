#!/bin/bash
#SBATCH -N 4
#SBATCH -C cpu
#SBATCH -q debug
#SBATCH -t 00:30:00
#SBATCH -J ejfat_pipeline_4node
#
# EJFAT ZMQ Pipeline End-to-End Test on Perlmutter — single-source pipeline (4 nodes)
#
#   Node 0 (sender)   : pipeline_sender -- ZMQ PUSH :5556  seqs [0, N)
#   Node 1 (bridge)   : zmq_ejfat_bridge -- PULL :5556 -> EJFAT (data-id=1)
#   Node 2 (proxy)    : ejfat_zmq_proxy  -- EJFAT Reassembler -> ZMQ PUSH
#   Node 3 (validator): pipeline_validator -- ZMQ PULL + seq/payload validation
#
# Usage:
#   export EJFAT_URI="ejfats://token@lb.es.net:443/lb/xyz?..."
#   export E2SAR_SCRIPTS_DIR="/path/to/ejfat_proxy/scripts/perlmutter"
#   sbatch -A <account> pipeline_test_4node.sh [OPTIONS]
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
echo "EJFAT ZMQ Pipeline Test (4-node) - SLURM Job $SLURM_JOB_ID"
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

NODE_SENDER="${NODE_ARRAY[0]}"    # N1 - sender -> bridge :5556
NODE_BRIDGE="${NODE_ARRAY[1]}"    # N2 - bridge (data-id=1)
NODE_PROXY="${NODE_ARRAY[2]}"     # N3 - ejfat_zmq_proxy
NODE_VALIDATOR="${NODE_ARRAY[3]}" # N4 - pipeline_validator

echo "Node assignments:"
echo "  N1 Sender    : $NODE_SENDER    (seqs 0..$(( SENDER_COUNT - 1 )) -> bridge :5556)"
echo "  N2 Bridge    : $NODE_BRIDGE    (data-id=1, pulls :5556)"
echo "  N3 Proxy     : $NODE_PROXY"
echo "  N4 Validator : $NODE_VALIDATOR"
echo ""

ZMQ_PORT="${ZMQ_PORT:-5556}"       # sender -> bridge
PROXY_ZMQ_PORT="${PROXY_ZMQ_PORT:-5555}" # proxy -> validator

export PROXY_ZMQ_PORT
export PROXY_NODE="$NODE_PROXY"
export ZMQ_PORT="$PROXY_ZMQ_PORT"

BPS=$(echo "$SENDER_RATE * $SENDER_SIZE * 8" | bc 2>/dev/null || true)
echo "Rate: ${SENDER_RATE} msg/s x ${SENDER_SIZE} B = ${BPS:-?} bps"
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

    sleep 3

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
        --expected '$SENDER_COUNT' --start-seq 0 --timeout 120" \
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
    bash -c "cd '$JOB_DIR' && \
        SENDER_NODE='$NODE_SENDER' \
        SENDER_ZMQ_PORT='$ZMQ_PORT' \
        BRIDGE_DATA_ID=1 \
        BRIDGE_SRC_ID=1 \
        BRIDGE_LOG=bridge.log \
        '$SCRIPT_DIR/run_zmq_ejfat_bridge.sh'" \
    > bridge_wrapper.log 2>&1 &

BRIDGE_PID=$!
echo "Bridge started (PID: $BRIDGE_PID) -- pulling :$ZMQ_PORT from $NODE_SENDER"
echo ""

#=============================================================================
# Phase 6: Run sender on N1 (wait for completion)
#=============================================================================

echo "========================================="
echo "Phase 6: Run Sender on $NODE_SENDER"
echo "========================================="
echo "  count=${SENDER_COUNT}  size=${SENDER_SIZE}  rate=${SENDER_RATE}"
echo ""

srun --nodes=1 --ntasks=1 --nodelist="$NODE_SENDER" \
    bash -c "cd '$JOB_DIR' && \
        SENDER_ZMQ_PORT='$ZMQ_PORT' \
        SENDER_LOG=sender.log \
        '$SCRIPT_DIR/run_pipeline_sender.sh' \
            --count '$SENDER_COUNT' --size '$SENDER_SIZE' \
            --rate '$SENDER_RATE' --start-seq 0" \
    > sender_wrapper.log 2>&1
SENDER_EXIT=$?

echo "Sender exited (exit code: $SENDER_EXIT)"
echo ""

#=============================================================================
# Phase 7: Wait for validator to finish
#=============================================================================

echo "========================================="
echo "Phase 7: Wait for Validator"
echo "========================================="

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
echo "--- Sender (last 10 lines) ---"
tail -10 sender.log 2>/dev/null || echo "  sender.log not found"

echo ""
echo "--- Validator (last 30 lines) ---"
tail -30 validator.log 2>/dev/null || echo "  validator.log not found"

echo ""
echo "--- Bridge (last 15 lines) ---"
tail -15 bridge.log 2>/dev/null || echo "  bridge.log not found"

echo ""
echo "--- Proxy (last 20 lines) ---"
tail -20 proxy.log 2>/dev/null || echo "  proxy.log not found"

echo ""
echo "========================================="
if [[ $VALIDATOR_EXIT -eq 0 && $SENDER_EXIT -eq 0 ]]; then
    echo "RESULT: PASS"
else
    echo "RESULT: FAIL (validator=$VALIDATOR_EXIT sender=$SENDER_EXIT)"
fi
echo "End time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Logs: $JOB_DIR"
echo "========================================="

FINAL_EXIT=0
[[ $VALIDATOR_EXIT -ne 0 ]] && FINAL_EXIT=$VALIDATOR_EXIT
[[ $SENDER_EXIT    -ne 0 ]] && FINAL_EXIT=$SENDER_EXIT
exit $FINAL_EXIT
