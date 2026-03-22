#!/bin/bash
# Run pipeline_validator (C++) on a Perlmutter compute node (pipeline test N4)
#
# Requires:
#   - PROXY_NODE  : hostname of N3 (ejfat_zmq_proxy)
#   - ZMQ_PORT    (default: 5555)
#   - PROXY_IMAGE : container image (default: ejfat-zmq-proxy:latest)
#
# Options passed through to pipeline_validator:
#   --expected N, --timeout N

set -euo pipefail

VALIDATOR_ARGS=("$@")

ZMQ_PORT="${ZMQ_PORT:-5555}"
PROXY_IMAGE="${PROXY_IMAGE:-ejfat-zmq-proxy:latest}"
VALIDATOR_BIN="/build/ejfat_zmq_proxy/build/bin/pipeline_validator"

echo "========================================="
echo "Pipeline Validator Startup"
echo "========================================="
echo "Node : $(hostname)"
echo "Time : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

if [[ -z "${PROXY_NODE:-}" ]]; then
    echo "ERROR: PROXY_NODE environment variable not set"
    exit 1
fi

ZMQ_ENDPOINT="tcp://${PROXY_NODE}:${ZMQ_PORT}"
echo "ZMQ PULL endpoint: $ZMQ_ENDPOINT"
echo "Validator args: ${VALIDATOR_ARGS[*]:-<defaults>}"
echo ""

podman-hpc run --rm --network host \
    "$PROXY_IMAGE" \
    "$VALIDATOR_BIN" \
        --endpoint "$ZMQ_ENDPOINT" \
        "${VALIDATOR_ARGS[@]}" \
    2>&1 | tee validator.log

EXIT_CODE=${PIPESTATUS[0]}
echo ""
echo "Validator exited with code: $EXIT_CODE"
exit $EXIT_CODE
