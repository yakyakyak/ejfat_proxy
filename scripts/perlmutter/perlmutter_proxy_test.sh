#!/bin/bash
#SBATCH -N 3
#SBATCH -C cpu
#SBATCH -q debug
#SBATCH -t 00:30:00
#SBATCH -J ejfat_proxy_test
#
# EJFAT ZMQ Proxy Test on Perlmutter
#
# Tests end-to-end data flow:
#   Node 0: ejfat_zmq_proxy (receives from LB, pushes to ZMQ)
#   Node 1: test_receiver.py (ZMQ consumer)
#   Node 2: e2sar_perf sender (sends data through LB)
#
# Usage:
#   export EJFAT_URI="ejfats://token@lb.es.net:443/lb/xyz?..."
#   export E2SAR_SCRIPTS_DIR="/path/to/ejfat_proxy/scripts/perlmutter"
#   sbatch -A <account> perlmutter_proxy_test.sh [SENDER_OPTIONS]
#
# Sender options are passed to minimal_sender.sh:
#   --rate RATE       Sending rate in Gbps (default: 1)
#   --num COUNT       Number of events to send (default: 100)
#   --length LENGTH   Event buffer length in bytes (default: 1048576)
#   --mtu MTU         MTU size in bytes (default: 9000)

set -euo pipefail

#=============================================================================
# Parse command-line arguments (forwarded to sender)
#=============================================================================

SENDER_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rate|--num|--length|--mtu)
            SENDER_ARGS+=("$1" "$2")
            shift 2
            ;;
        *)
            echo "ERROR: Unknown argument: $1"
            echo "Usage: $0 [--rate RATE] [--num NUM] [--length LEN] [--mtu MTU]"
            exit 1
            ;;
    esac
done

#=============================================================================
# Environment setup
#=============================================================================

echo "========================================="
echo "EJFAT ZMQ Proxy Test - SLURM Job $SLURM_JOB_ID"
echo "========================================="
echo "Start time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Validate EJFAT_URI
if [[ -z "${EJFAT_URI:-}" ]]; then
    echo "ERROR: EJFAT_URI is required"
    echo "Set via: EJFAT_URI='ejfats://...' sbatch $0"
    exit 1
fi

EJFAT_URI_REDACTED=$(echo "$EJFAT_URI" | sed -E 's|(://)(.{4})[^@]*(.{4})@|\1\2---\3@|')
echo "EJFAT_URI: $EJFAT_URI_REDACTED"
echo "Job nodes: $SLURM_JOB_NODELIST"
echo "Job ID: $SLURM_JOB_ID"
echo ""

# Validate E2SAR_SCRIPTS_DIR
if [[ -z "${E2SAR_SCRIPTS_DIR:-}" ]]; then
    echo "ERROR: E2SAR_SCRIPTS_DIR must be set to the scripts/perlmutter directory"
    echo "  export E2SAR_SCRIPTS_DIR=\$PWD/scripts/perlmutter"
    exit 1
fi
SCRIPT_DIR="$E2SAR_SCRIPTS_DIR"
echo "Script directory: $SCRIPT_DIR"

# Create runs directory if it doesn't exist
RUNS_DIR="${SLURM_SUBMIT_DIR}/runs"
mkdir -p "$RUNS_DIR"
echo "Runs directory: $RUNS_DIR"

# Create job-specific working directory for logs and artifacts
JOB_DIR="${RUNS_DIR}/slurm_job_${SLURM_JOB_ID}"
mkdir -p "$JOB_DIR"
cd "$JOB_DIR"
echo "Working directory: $JOB_DIR"
echo ""

# Parse node list - get three nodes
NODE_ARRAY=($(scontrol show hostname $SLURM_JOB_NODELIST))

if [[ ${#NODE_ARRAY[@]} -lt 3 ]]; then
    echo "ERROR: Need at least 3 nodes, got ${#NODE_ARRAY[@]}"
    exit 1
fi

NODE0="${NODE_ARRAY[0]}"  # Proxy
NODE1="${NODE_ARRAY[1]}"  # Consumer
NODE2="${NODE_ARRAY[2]}"  # Sender

echo "Node assignments:"
echo "  Proxy:    $NODE0"
echo "  Consumer: $NODE1"
echo "  Sender:   $NODE2"
echo ""

# ZMQ configuration
ZMQ_PORT="${ZMQ_PORT:-5555}"
export ZMQ_PORT
export PROXY_NODE="$NODE0"

echo "ZMQ endpoint: tcp://$NODE0:$ZMQ_PORT"
echo ""

#=============================================================================
# Install cleanup trap to free reservation on early exit
#=============================================================================

CLEANUP_DONE=false
PROXY_PID=""
CONSUMER_PID=""

cleanup() {
    if [[ "$CLEANUP_DONE" == "true" ]]; then
        return
    fi
    CLEANUP_DONE=true

    echo ""
    echo "========================================="
    echo "Cleanup: Stopping Processes"
    echo "========================================="

    # Stop proxy and consumer (if running)
    if [[ -n "$PROXY_PID" ]]; then
        echo "Stopping proxy (PID: $PROXY_PID)..."
        kill -TERM "$PROXY_PID" 2>/dev/null || true
    fi

    if [[ -n "$CONSUMER_PID" ]]; then
        echo "Stopping consumer (PID: $CONSUMER_PID)..."
        kill -TERM "$CONSUMER_PID" 2>/dev/null || true
    fi

    # Wait briefly for graceful shutdown
    sleep 2

    # Force kill if still running
    if [[ -n "$PROXY_PID" ]]; then
        kill -9 "$PROXY_PID" 2>/dev/null || true
    fi
    if [[ -n "$CONSUMER_PID" ]]; then
        kill -9 "$CONSUMER_PID" 2>/dev/null || true
    fi

    # Free load balancer reservation
    if [[ -f "$JOB_DIR/INSTANCE_URI" ]]; then
        echo ""
        echo "========================================="
        echo "Cleanup: Freeing Load Balancer"
        echo "========================================="
        cd "$JOB_DIR" || return
        "$SCRIPT_DIR/minimal_free.sh" 2>/dev/null || echo "WARNING: Failed to free LB reservation"
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

echo "Creating new LB reservation for job $SLURM_JOB_ID..."
if ! "$SCRIPT_DIR/minimal_reserve.sh"; then
    echo "ERROR: Failed to reserve load balancer"
    exit 1
fi

# Verify INSTANCE_URI file exists
if [[ ! -f "INSTANCE_URI" ]]; then
    echo "ERROR: INSTANCE_URI file not found after reservation"
    exit 1
fi

echo ""
echo "Reservation ready"
echo ""

#=============================================================================
# Phase 2: Start Proxy (background on Node 0)
#=============================================================================

echo "========================================="
echo "Phase 2: Start Proxy on $NODE0"
echo "========================================="

srun --nodes=1 --ntasks=1 --nodelist="$NODE0" \
    bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/run_proxy.sh'" \
    > proxy_wrapper.log 2>&1 &

PROXY_PID=$!
echo "Proxy started (PID: $PROXY_PID)"
echo ""

#=============================================================================
# Phase 3: Start Consumer (background on Node 1)
#=============================================================================

echo "========================================="
echo "Phase 3: Start Consumer on $NODE1"
echo "========================================="

srun --nodes=1 --ntasks=1 --nodelist="$NODE1" \
    bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/run_consumer.sh'" \
    > consumer_wrapper.log 2>&1 &

CONSUMER_PID=$!
echo "Consumer started (PID: $CONSUMER_PID)"
echo ""

#=============================================================================
# Phase 4: Wait for Registration
#=============================================================================

echo "========================================="
echo "Phase 4: Wait for Worker Registration"
echo "========================================="

WAIT_TIME=15
echo "Waiting ${WAIT_TIME}s for proxy to register with load balancer..."
sleep $WAIT_TIME

echo "Checking proxy status..."
if ! kill -0 "$PROXY_PID" 2>/dev/null; then
    echo "ERROR: Proxy process died during registration"
    cat proxy_wrapper.log proxy.log 2>/dev/null || true
    exit 1
fi

echo "Proxy is running"
echo ""

#=============================================================================
# Phase 5: Run Sender (foreground on Node 2)
#=============================================================================

echo "========================================="
echo "Phase 5: Start Sender on $NODE2"
echo "========================================="

echo "Sender arguments: ${SENDER_ARGS[*]:-<defaults>}"
echo ""

# Run sender in foreground (wait for completion)
srun --nodes=1 --ntasks=1 --nodelist="$NODE2" \
    bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/minimal_sender.sh' ${SENDER_ARGS[*]:-}"

SENDER_EXIT_CODE=$?

echo ""
echo "Sender completed with exit code: $SENDER_EXIT_CODE"
echo ""

#=============================================================================
# Phase 6: Wait for Proxy/Consumer to Process Data
#=============================================================================

echo "========================================="
echo "Phase 6: Wait for Data Processing"
echo "========================================="

DRAIN_TIME=5
echo "Waiting ${DRAIN_TIME}s for proxy/consumer to drain buffers..."
sleep $DRAIN_TIME

echo ""

#=============================================================================
# Phase 7: Display Summary
#=============================================================================

echo "========================================="
echo "Test Summary"
echo "========================================="

# Count lines in logs (approximate metric)
echo ""
echo "Log sizes:"
ls -lh proxy.log consumer.log minimal_sender.log 2>/dev/null || echo "  Some logs missing"

echo ""
echo "Proxy output (last 50 lines):"
echo "---"
tail -50 proxy.log 2>/dev/null || echo "  proxy.log not found"

echo ""
echo "Consumer output (last 50 lines):"
echo "---"
tail -50 consumer.log 2>/dev/null || echo "  consumer.log not found"

echo ""
echo "Sender output (last 50 lines):"
echo "---"
tail -50 minimal_sender.log 2>/dev/null || echo "  minimal_sender.log not found"

echo ""
echo "========================================="
echo "Test Complete"
echo "========================================="
echo "End time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Logs saved to: $JOB_DIR"
echo ""

# Cleanup will run via trap
exit $SENDER_EXIT_CODE
