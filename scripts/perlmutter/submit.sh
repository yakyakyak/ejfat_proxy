#!/bin/bash
# Convenience wrapper for submitting Perlmutter test jobs
#
# Usage:
#   ./submit.sh --account m4386 [OPTIONS] [SENDER_ARGS]
#
# Options:
#   --account ACC         SLURM account (required)
#   --pre-reserve         Reserve LB before submitting job
#   --test-type TYPE      Test type: normal (default), backpressure, pipeline, or backpressure-suite
#   --consumer-delay MS   Consumer delay for backpressure test (default: 10)
#   --help                Show this help
#
# SLURM Options (passed through):
#   --nodes N, -N N       Number of nodes (default: 3)
#   --time T, -t T        Time limit (default: 00:30:00)
#   --qos Q, -q Q         QOS (default: debug)
#
# Sender Arguments (passed through):
#   --rate RATE           Sending rate in Gbps
#   --num COUNT           Number of events to send
#   --length LENGTH       Event buffer length in bytes
#   --mtu MTU             MTU size in bytes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Defaults
ACCOUNT=""
PRE_RESERVE=false
TEST_TYPE="normal"
CONSUMER_DELAY="10"

# SLURM options
SBATCH_OPTS=()
SENDER_ARGS=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --account)
            ACCOUNT="$2"
            shift 2
            ;;
        --pre-reserve)
            PRE_RESERVE=true
            shift
            ;;
        --test-type)
            TEST_TYPE="$2"
            shift 2
            ;;
        --consumer-delay)
            CONSUMER_DELAY="$2"
            shift 2
            ;;
        --nodes|-N)
            SBATCH_OPTS+=("-N" "$2")
            shift 2
            ;;
        --time|-t)
            SBATCH_OPTS+=("-t" "$2")
            shift 2
            ;;
        --qos|-q)
            SBATCH_OPTS+=("-q" "$2")
            shift 2
            ;;
        --help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        --rate|--num|--length|--mtu)
            SENDER_ARGS+=("$1" "$2")
            shift 2
            ;;
        --count|--size)
            SENDER_ARGS+=("$1" "$2")
            shift 2
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$ACCOUNT" ]]; then
    echo "ERROR: --account is required"
    echo "Usage: $0 --account <account> [OPTIONS]"
    exit 1
fi

if [[ "$TEST_TYPE" != "normal" && "$TEST_TYPE" != "backpressure" && \
      "$TEST_TYPE" != "pipeline" && "$TEST_TYPE" != "backpressure-suite" ]]; then
    echo "ERROR: --test-type must be 'normal', 'backpressure', 'pipeline', or 'backpressure-suite'"
    exit 1
fi

# Check EJFAT_URI
if [[ -z "${EJFAT_URI:-}" ]]; then
    echo "ERROR: EJFAT_URI environment variable is required"
    echo "Set it with: export EJFAT_URI='ejfats://token@lb.es.net:443/lb/xyz?...'"
    exit 1
fi

echo "========================================="
echo "EJFAT ZMQ Proxy Test Submission"
echo "========================================="
echo "Project root: $PROJECT_ROOT"
echo "Account: $ACCOUNT"
echo "Test type: $TEST_TYPE"
if [[ "$TEST_TYPE" == "backpressure" ]]; then
    echo "Consumer delay: ${CONSUMER_DELAY}ms"
elif [[ "$TEST_TYPE" == "backpressure-suite" ]]; then
    echo "Running all 5 backpressure scenarios (15 min)"
fi
echo "SBATCH options: ${SBATCH_OPTS[*]:-<defaults>}"
echo "Sender arguments: ${SENDER_ARGS[*]:-<defaults>}"
echo ""

# Pre-reserve LB if requested
if [[ "$PRE_RESERVE" == "true" ]]; then
    echo "========================================="
    echo "Pre-Reserving Load Balancer"
    echo "========================================="

    RESERVE_DIR="/tmp/ejfat_reserve_$$"
    mkdir -p "$RESERVE_DIR"
    cd "$RESERVE_DIR"

    export EJFAT_URI
    if "$SCRIPT_DIR/minimal_reserve.sh"; then
        echo "Pre-reservation successful"
        cat INSTANCE_URI
        echo ""
        echo "NOTE: Reservation will be freed automatically by the SLURM job"
        echo "      If job is cancelled, manually free with: minimal_free.sh"
        echo ""
    else
        echo "ERROR: Pre-reservation failed"
        rm -rf "$RESERVE_DIR"
        exit 1
    fi

    cd "$PROJECT_ROOT"
    rm -rf "$RESERVE_DIR"
fi

# Select test script
if [[ "$TEST_TYPE" == "backpressure" ]]; then
    TEST_SCRIPT="$SCRIPT_DIR/perlmutter_backpressure_test.sh"
    SENDER_ARGS+=("--consumer-delay" "$CONSUMER_DELAY")
elif [[ "$TEST_TYPE" == "pipeline" ]]; then
    TEST_SCRIPT="$SCRIPT_DIR/perlmutter_pipeline_test.sh"
elif [[ "$TEST_TYPE" == "backpressure-suite" ]]; then
    TEST_SCRIPT="$SCRIPT_DIR/perlmutter_backpressure_suite.sh"
else
    TEST_SCRIPT="$SCRIPT_DIR/perlmutter_proxy_test.sh"
fi

# Build sbatch command
SBATCH_CMD=(
    sbatch
    -A "$ACCOUNT"
    "${SBATCH_OPTS[@]}"
    "$TEST_SCRIPT"
    "${SENDER_ARGS[@]}"
)

echo "========================================="
echo "Submitting Job"
echo "========================================="
echo "Test script: $(basename "$TEST_SCRIPT")"
echo ""
echo "Command: ${SBATCH_CMD[*]}"
echo ""

# Set E2SAR_SCRIPTS_DIR for the job
export E2SAR_SCRIPTS_DIR="$SCRIPT_DIR"
export EJFAT_URI

# Submit job
cd "$PROJECT_ROOT"
"${SBATCH_CMD[@]}"

echo ""
echo "Job submitted!"
echo "Monitor with: squeue -u \$USER"
echo "View output: tail -f runs/slurm_job_<JOBID>/proxy.log"
