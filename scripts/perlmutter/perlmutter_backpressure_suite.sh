#!/bin/bash
# perlmutter_backpressure_suite.sh
#
# Submits all 5 backpressure test jobs as separate Slurm allocations.
# Each test gets its own 3-node job and LB reservation, so they may
# run in parallel (subject to queue availability).
#
# Tests:
#   1. Baseline       — no backpressure (fast consumer)
#   2. Mild BP        — 10ms delay, small buffer → activates and recovers
#   3. Heavy BP       — 100ms delay, small buffer → sustained saturation
#   4. Small-event    — 50ms delay, small buffer, 64KB events
#   5. 5-min soak     — 20ms delay, moderate buffer, looping sender
#
# Usage:
#   export EJFAT_URI="ejfats://token@lb.es.net:443/lb/xyz?..."
#   export E2SAR_SCRIPTS_DIR="/path/to/ejfat_proxy/scripts/perlmutter"
#   ./perlmutter_backpressure_suite.sh --account <account> [--sequential]
#
# Options:
#   --account ACC     Slurm account (required)
#   --sequential      Submit test N+1 only after test N completes (--dependency)
#   --tests LIST      Comma-separated test numbers to run, e.g. "1,3,5" (default: all)
#   --qos Q           QOS (default: debug)
#   --help            Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ACCOUNT=""
SEQUENTIAL=false
TESTS="1,2,3,4,5"
QOS="debug"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --account) ACCOUNT="$2"; shift 2 ;;
        --sequential) SEQUENTIAL=true; shift ;;
        --tests) TESTS="$2"; shift 2 ;;
        --qos) QOS="$2"; shift 2 ;;
        --help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "ERROR: Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$ACCOUNT" ]]; then
    echo "ERROR: --account is required"
    exit 1
fi

if [[ -z "${EJFAT_URI:-}" ]]; then
    echo "ERROR: EJFAT_URI is required"
    exit 1
fi

if [[ -z "${E2SAR_SCRIPTS_DIR:-}" ]]; then
    echo "ERROR: E2SAR_SCRIPTS_DIR must be set"
    exit 1
fi

export EJFAT_URI
export E2SAR_SCRIPTS_DIR

echo "========================================="
echo "EJFAT Backpressure Suite Submission"
echo "========================================="
echo "Account: $ACCOUNT"
echo "QOS: $QOS"
echo "Tests: $TESTS"
echo "Sequential: $SEQUENTIAL"
echo ""

# Convert comma-separated list to array
IFS=',' read -ra TEST_NUMS <<< "$TESTS"

declare -a JOB_IDS=()
PREV_JOB_ID=""

for t in "${TEST_NUMS[@]}"; do
    SCRIPT="$SCRIPT_DIR/bp_test${t}.sh"
    if [[ ! -f "$SCRIPT" ]]; then
        echo "ERROR: $SCRIPT not found"
        exit 1
    fi

    SBATCH_ARGS=(-A "$ACCOUNT" -q "$QOS")

    if [[ "$SEQUENTIAL" == "true" && -n "$PREV_JOB_ID" ]]; then
        SBATCH_ARGS+=(--dependency="afterany:${PREV_JOB_ID}")
    fi

    JOB_ID=$(sbatch "${SBATCH_ARGS[@]}" "$SCRIPT" | grep -oP '\d+$')
    JOB_IDS+=("$JOB_ID")
    PREV_JOB_ID="$JOB_ID"

    echo "  Test $t: submitted as job $JOB_ID"
done

echo ""
echo "All jobs submitted."
echo ""
echo "Monitor:   squeue -u \$USER"
echo "Job IDs:   ${JOB_IDS[*]}"
echo "Outputs:   runs/slurm_job_<JOBID>/"
