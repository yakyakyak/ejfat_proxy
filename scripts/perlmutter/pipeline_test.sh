#!/bin/bash
#SBATCH -N 8
#SBATCH -C cpu
#SBATCH -q debug
#SBATCH -t 00:30:00
#SBATCH -J ejfat_pipeline_test
#
# EJFAT ZMQ Pipeline End-to-End Test on Perlmutter — 2x(2 ZMQ) source pipelines
#
# Two bridges each pulling from two ZMQ senders (4 total sources):
#   Node 0 (sender1a) : pipeline_sender -- ZMQ PUSH :5556  seqs [0,     N)
#   Node 1 (sender1b) : pipeline_sender -- ZMQ PUSH :5557  seqs [N,   2*N)
#   Node 2 (sender2a) : pipeline_sender -- ZMQ PUSH :5558  seqs [2*N, 3*N)
#   Node 3 (sender2b) : pipeline_sender -- ZMQ PUSH :5559  seqs [3*N, 4*N)
#   Node 4 (bridge1)  : zmq_ejfat_bridge -- PULL :5556,:5557 -> EJFAT (data-id=1)
#   Node 5 (bridge2)  : zmq_ejfat_bridge -- PULL :5558,:5559 -> EJFAT (data-id=2)
#   Node 6 (proxy)    : ejfat_zmq_proxy  -- EJFAT Reassembler -> ZMQ PUSH
#   Node 7 (validator): pipeline_validator -- ZMQ PULL + seq/payload validation
#
# Usage:
#   export EJFAT_URI="ejfats://token@lb.es.net:443/lb/xyz?..."
#   export E2SAR_SCRIPTS_DIR="/path/to/ejfat_proxy/scripts/perlmutter"
#   sbatch -A <account> pipeline_test.sh [OPTIONS]
#
# Options:
#   --count N       Messages per source (default: 1000; validator expects 4*N)
#   --size N        Message size in bytes (default: 4096)
#   --rate N        Messages per second per source (default: 100)
#                   For 10 Gbps/bridge with --size 4096: --rate 152000

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
if [[ ${#NODE_ARRAY[@]} -lt 8 ]]; then
    echo "ERROR: Need at least 8 nodes, got ${#NODE_ARRAY[@]}"
    exit 1
fi

NODE_SENDER1A="${NODE_ARRAY[0]}"   # N1 - sender1a -> bridge1 :5556
NODE_SENDER1B="${NODE_ARRAY[1]}"   # N2 - sender1b -> bridge1 :5557
NODE_SENDER2A="${NODE_ARRAY[2]}"   # N3 - sender2a -> bridge2 :5558
NODE_SENDER2B="${NODE_ARRAY[3]}"   # N4 - sender2b -> bridge2 :5559
NODE_BRIDGE="${NODE_ARRAY[4]}"     # N5 - bridge1 (data-id=1)
NODE_BRIDGE2="${NODE_ARRAY[5]}"    # N6 - bridge2 (data-id=2)
NODE_PROXY="${NODE_ARRAY[6]}"      # N7 - ejfat_zmq_proxy
NODE_VALIDATOR="${NODE_ARRAY[7]}"  # N8 - pipeline_validator

echo "Node assignments:"
echo "  N1 Sender1a  : $NODE_SENDER1A  (seqs 0..$(( SENDER_COUNT - 1 )) -> bridge1 :5556)"
echo "  N2 Sender1b  : $NODE_SENDER1B  (seqs $SENDER_COUNT..$(( SENDER_COUNT * 2 - 1 )) -> bridge1 :5557)"
echo "  N3 Sender2a  : $NODE_SENDER2A  (seqs $(( SENDER_COUNT * 2 ))..$(( SENDER_COUNT * 3 - 1 )) -> bridge2 :5558)"
echo "  N4 Sender2b  : $NODE_SENDER2B  (seqs $(( SENDER_COUNT * 3 ))..$(( SENDER_COUNT * 4 - 1 )) -> bridge2 :5559)"
echo "  N5 Bridge1   : $NODE_BRIDGE    (data-id=1, pulls :5556 + :5557)"
echo "  N6 Bridge2   : $NODE_BRIDGE2   (data-id=2, pulls :5558 + :5559)"
echo "  N7 Proxy     : $NODE_PROXY"
echo "  N8 Validator : $NODE_VALIDATOR"
echo ""

# ZMQ ports
PORT_1A="${PORT_1A:-5556}"   # sender1a -> bridge1
PORT_1B="${PORT_1B:-5557}"   # sender1b -> bridge1
PORT_2A="${PORT_2A:-5558}"   # sender2a -> bridge2
PORT_2B="${PORT_2B:-5559}"   # sender2b -> bridge2
ZMQ_PORT="${ZMQ_PORT:-5555}" # proxy -> validator

# Non-overlapping sequence ranges (N per sender, 4*N total)
START_1A=0
START_1B=$SENDER_COUNT
START_2A=$(( SENDER_COUNT * 2 ))
START_2B=$(( SENDER_COUNT * 3 ))
TOTAL_COUNT=$(( SENDER_COUNT * 4 ))

export ZMQ_PORT
export PROXY_NODE="$NODE_PROXY"

echo "ZMQ topology:"
echo "  $NODE_SENDER1A:$PORT_1A -> bridge1 (seqs $START_1A..$(( START_1B - 1 )))"
echo "  $NODE_SENDER1B:$PORT_1B -> bridge1 (seqs $START_1B..$(( START_2A - 1 )))"
echo "  $NODE_SENDER2A:$PORT_2A -> bridge2 (seqs $START_2A..$(( START_2B - 1 )))"
echo "  $NODE_SENDER2B:$PORT_2B -> bridge2 (seqs $START_2B..$(( TOTAL_COUNT - 1 )))"
echo "  proxy -> validator :$ZMQ_PORT  (expects $TOTAL_COUNT total)"
echo ""

# Throughput estimate
BPS_PER_SENDER=$(echo "$SENDER_RATE * $SENDER_SIZE * 8" | bc 2>/dev/null || true)
echo "Rate per sender : ${SENDER_RATE} msg/s x ${SENDER_SIZE} B = ${BPS_PER_SENDER:-?} bps"
echo ""

#=============================================================================
# Cleanup trap
#=============================================================================

CLEANUP_DONE=false
PROXY_PID=""
BRIDGE_PID=""
BRIDGE2_PID=""
VALIDATOR_PID=""

cleanup() {
    [[ "$CLEANUP_DONE" == "true" ]] && return
    CLEANUP_DONE=true

    echo ""
    echo "========================================="
    echo "Cleanup: Stopping Background Processes"
    echo "========================================="

    for pid_var in PROXY_PID BRIDGE_PID BRIDGE2_PID VALIDATOR_PID; do
        pid="${!pid_var}"
        [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null || true
    done

    sleep 3

    for pid_var in PROXY_PID BRIDGE_PID BRIDGE2_PID VALIDATOR_PID; do
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
        --expected '$TOTAL_COUNT' --start-seq 0 --timeout 120" \
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
# Phase 5: Start Bridge 1 on N5 and Bridge 2 on N6 (background)
#           Each bridge pulls from 2 ZMQ endpoints
#=============================================================================

echo "========================================="
echo "Phase 5: Start Bridges on $NODE_BRIDGE and $NODE_BRIDGE2"
echo "========================================="

srun --nodes=1 --ntasks=1 --nodelist="$NODE_BRIDGE" \
    bash -c "cd '$JOB_DIR' && \
        SENDER_NODE='$NODE_SENDER1A' \
        SENDER_ZMQ_PORT='$PORT_1A' \
        SENDER_NODE2='$NODE_SENDER1B' \
        SENDER_ZMQ_PORT2='$PORT_1B' \
        BRIDGE_DATA_ID=1 \
        BRIDGE_SRC_ID=1 \
        BRIDGE_LOG=bridge.log \
        '$SCRIPT_DIR/run_zmq_ejfat_bridge.sh'" \
    > bridge_wrapper.log 2>&1 &

BRIDGE_PID=$!
echo "Bridge1 started (PID: $BRIDGE_PID) -- pulling :$PORT_1A and :$PORT_1B"

srun --nodes=1 --ntasks=1 --nodelist="$NODE_BRIDGE2" \
    bash -c "cd '$JOB_DIR' && \
        SENDER_NODE='$NODE_SENDER2A' \
        SENDER_ZMQ_PORT='$PORT_2A' \
        SENDER_NODE2='$NODE_SENDER2B' \
        SENDER_ZMQ_PORT2='$PORT_2B' \
        BRIDGE_DATA_ID=2 \
        BRIDGE_SRC_ID=2 \
        BRIDGE_LOG=bridge2.log \
        '$SCRIPT_DIR/run_zmq_ejfat_bridge.sh'" \
    > bridge2_wrapper.log 2>&1 &

BRIDGE2_PID=$!
echo "Bridge2 started (PID: $BRIDGE2_PID) -- pulling :$PORT_2A and :$PORT_2B"
echo ""

#=============================================================================
# Phase 6: Run all 4 senders in parallel (wait for all)
#=============================================================================

echo "========================================="
echo "Phase 6: Run Senders on 4 nodes"
echo "========================================="
echo "  count=${SENDER_COUNT}  size=${SENDER_SIZE}  rate=${SENDER_RATE} per sender"
echo ""

_run_sender() {
    local node="$1" port="$2" start="$3" log="$4"
    srun --nodes=1 --ntasks=1 --nodelist="$node" \
        bash -c "cd '$JOB_DIR' && \
            SENDER_ZMQ_PORT='$port' \
            SENDER_LOG='$log' \
            '$SCRIPT_DIR/run_pipeline_sender.sh' \
                --count '$SENDER_COUNT' --size '$SENDER_SIZE' \
                --rate '$SENDER_RATE' --start-seq '$start'" \
        > "${log%.log}_wrapper.log" 2>&1
}

_run_sender "$NODE_SENDER1A" "$PORT_1A" "$START_1A" "sender1a.log" &
PID_1A=$!
_run_sender "$NODE_SENDER1B" "$PORT_1B" "$START_1B" "sender1b.log" &
PID_1B=$!
_run_sender "$NODE_SENDER2A" "$PORT_2A" "$START_2A" "sender2a.log" &
PID_2A=$!
_run_sender "$NODE_SENDER2B" "$PORT_2B" "$START_2B" "sender2b.log" &
PID_2B=$!

echo "Waiting for all 4 senders to finish..."
wait "$PID_1A" && EXIT_1A=0 || EXIT_1A=$?
wait "$PID_1B" && EXIT_1B=0 || EXIT_1B=$?
wait "$PID_2A" && EXIT_2A=0 || EXIT_2A=$?
wait "$PID_2B" && EXIT_2B=0 || EXIT_2B=$?

echo ""
echo "Sender exits: 1a=$EXIT_1A  1b=$EXIT_1B  2a=$EXIT_2A  2b=$EXIT_2B"
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
ls -lh proxy.log bridge.log bridge2.log \
    sender1a.log sender1b.log sender2a.log sender2b.log \
    validator.log 2>/dev/null || echo "  Some logs missing"

for s in sender1a sender1b sender2a sender2b; do
    echo ""
    echo "--- ${s} (last 10 lines) ---"
    tail -10 "${s}.log" 2>/dev/null || echo "  ${s}.log not found"
done

echo ""
echo "--- Validator (last 30 lines) ---"
tail -30 validator.log 2>/dev/null || echo "  validator.log not found"

echo ""
echo "--- Bridge1 (last 15 lines) ---"
tail -15 bridge.log 2>/dev/null || echo "  bridge.log not found"

echo ""
echo "--- Bridge2 (last 15 lines) ---"
tail -15 bridge2.log 2>/dev/null || echo "  bridge2.log not found"

echo ""
echo "--- Proxy (last 20 lines) ---"
tail -20 proxy.log 2>/dev/null || echo "  proxy.log not found"

echo ""
echo "========================================="
SENDER_FAILURES=$(( EXIT_1A + EXIT_1B + EXIT_2A + EXIT_2B ))
if [[ $VALIDATOR_EXIT -eq 0 && $SENDER_FAILURES -eq 0 ]]; then
    echo "RESULT: PASS"
else
    echo "RESULT: FAIL (validator=$VALIDATOR_EXIT senders: 1a=$EXIT_1A 1b=$EXIT_1B 2a=$EXIT_2A 2b=$EXIT_2B)"
fi
echo "End time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Logs: $JOB_DIR"
echo "========================================="

FINAL_EXIT=0
[[ $VALIDATOR_EXIT  -ne 0 ]] && FINAL_EXIT=$VALIDATOR_EXIT
[[ $EXIT_1A -ne 0 ]] && FINAL_EXIT=$EXIT_1A
[[ $EXIT_1B -ne 0 ]] && FINAL_EXIT=$EXIT_1B
[[ $EXIT_2A -ne 0 ]] && FINAL_EXIT=$EXIT_2A
[[ $EXIT_2B -ne 0 ]] && FINAL_EXIT=$EXIT_2B
exit $FINAL_EXIT
