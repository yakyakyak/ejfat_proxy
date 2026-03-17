#!/bin/bash
# Run pipeline_sender.py on a Perlmutter compute node (pipeline test N1)
#
# Requires:
#   - SLURM_SUBMIT_DIR
#   - SENDER_ZMQ_PORT (default: 5556)
#
# Options passed through to pipeline_sender.py:
#   --count N, --size N, --rate N

set -euo pipefail

DELAY_BEFORE_SEND="${DELAY_BEFORE_SEND:-5}"

# Parse args to forward
SENDER_ARGS=("$@")

SENDER_ZMQ_PORT="${SENDER_ZMQ_PORT:-5556}"
SENDER_SCRIPT="${SLURM_SUBMIT_DIR}/scripts/pipeline_sender.py"

echo "========================================="
echo "Pipeline Sender Startup"
echo "========================================="
echo "Node : $(hostname)"
echo "Time : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

if [[ ! -f "$SENDER_SCRIPT" ]]; then
    echo "ERROR: pipeline_sender.py not found: $SENDER_SCRIPT"
    exit 1
fi

module load python 2>/dev/null || true

if ! python3 -c "import zmq" 2>/dev/null; then
    echo "ERROR: pyzmq not available. Install with: pip install --user pyzmq"
    exit 1
fi

# Wait for downstream (bridge) to be ready before starting
echo "Waiting ${DELAY_BEFORE_SEND}s for bridge to connect..."
sleep "$DELAY_BEFORE_SEND"

ZMQ_ENDPOINT="tcp://*:${SENDER_ZMQ_PORT}"
echo "ZMQ PUSH endpoint: $ZMQ_ENDPOINT"
echo "Sender args: ${SENDER_ARGS[*]:-<defaults>}"
echo ""

python3 "$SENDER_SCRIPT" \
    --endpoint "$ZMQ_ENDPOINT" \
    "${SENDER_ARGS[@]}" \
    2>&1 | tee sender.log

EXIT_CODE=${PIPESTATUS[0]}
echo ""
echo "Sender exited with code: $EXIT_CODE"
exit $EXIT_CODE
