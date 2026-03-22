#!/bin/bash
# run_b2b_soak_sender.sh — Looping b2b_sender.sh for soak tests
#
# Same pattern as run_soak_sender.sh but calls b2b_sender.sh.
#
# Usage:
#   TARGET_IP=<proxy_ip> DATA_PORT=<port> \
#   ./run_b2b_soak_sender.sh [--duration SECONDS] [SENDER_OPTIONS...]
#
# Options:
#   --duration SECS   Total run time in seconds (default: 600)
#   All other options are passed through to b2b_sender.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DURATION=600
PASSTHROUGH_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration)
            DURATION="$2"
            shift 2
            ;;
        *)
            PASSTHROUGH_ARGS+=("$1")
            shift
            ;;
    esac
done

END_TIME=$(( $(date +%s) + DURATION ))
BATCH=0
TOTAL_EVENTS=0

echo "B2B soak sender started: will run for ${DURATION}s"
echo "Target: ${TARGET_IP:-?}:${DATA_PORT:-10000}"
echo "End time: $(date -u -d "@$END_TIME" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date -u -r "$END_TIME" '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

while [[ $(date +%s) -lt $END_TIME ]]; do
    BATCH=$(( BATCH + 1 ))
    REMAINING=$(( END_TIME - $(date +%s) ))
    echo "--- Soak batch $BATCH (${REMAINING}s remaining) ---"

    "$SCRIPT_DIR/b2b_sender.sh" ${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"} 2>&1 || true

    TOTAL_EVENTS=$(( TOTAL_EVENTS + ${NUM:-100} ))
    echo "Batch $BATCH complete. Total events sent so far: ~$TOTAL_EVENTS"
    echo ""
done

echo "B2B soak sender complete after $BATCH batches (~$TOTAL_EVENTS events)"
