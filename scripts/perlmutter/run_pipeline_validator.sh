#!/bin/bash
# Run pipeline_validator.py on a Perlmutter compute node (pipeline test N4)
#
# Requires:
#   - SLURM_SUBMIT_DIR
#   - PROXY_NODE  : hostname of N3 (ejfat_zmq_proxy)
#   - ZMQ_PORT    (default: 5555)
#
# Options passed through to pipeline_validator.py:
#   --expected N, --timeout N

set -euo pipefail

VALIDATOR_ARGS=("$@")

ZMQ_PORT="${ZMQ_PORT:-5555}"
VALIDATOR_SCRIPT="${SLURM_SUBMIT_DIR}/scripts/pipeline_validator.py"

echo "========================================="
echo "Pipeline Validator Startup"
echo "========================================="
echo "Node : $(hostname)"
echo "Time : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

if [[ ! -f "$VALIDATOR_SCRIPT" ]]; then
    echo "ERROR: pipeline_validator.py not found: $VALIDATOR_SCRIPT"
    exit 1
fi

module load python 2>/dev/null || true

if ! python3 -c "import zmq" 2>/dev/null; then
    echo "ERROR: pyzmq not available. Install with: pip install --user pyzmq"
    exit 1
fi

if [[ -z "${PROXY_NODE:-}" ]]; then
    echo "ERROR: PROXY_NODE environment variable not set"
    exit 1
fi

ZMQ_ENDPOINT="tcp://${PROXY_NODE}:${ZMQ_PORT}"
echo "ZMQ PULL endpoint: $ZMQ_ENDPOINT"
echo "Validator args: ${VALIDATOR_ARGS[*]:-<defaults>}"
echo ""

python3 "$VALIDATOR_SCRIPT" \
    --endpoint "$ZMQ_ENDPOINT" \
    "${VALIDATOR_ARGS[@]}" \
    2>&1 | tee validator.log

EXIT_CODE=${PIPESTATUS[0]}
echo ""
echo "Validator exited with code: $EXIT_CODE"
exit $EXIT_CODE
