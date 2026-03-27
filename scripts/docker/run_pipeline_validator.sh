#!/bin/bash
# Run pipeline_validator (C++) locally via docker or podman-hpc
#
# Requires:
#   - PROXY_NODE  : hostname or IP of ejfat_zmq_proxy (required)
#   - ZMQ_PORT    : ZMQ port (default: 5555)
#   - PROXY_IMAGE : container image (default: ejfat-zmq-proxy:latest)
#
# Options passed through to pipeline_validator:
#   --expected N, --timeout N

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=container_runtime.sh
source "$SCRIPT_DIR/container_runtime.sh"

VALIDATOR_ARGS=("$@")

ZMQ_PORT="${ZMQ_PORT:-5555}"
PROXY_IMAGE="${PROXY_IMAGE:-ejfat-zmq-proxy:latest}"
VALIDATOR_BIN="/build/ejfat_zmq_proxy/build/bin/pipeline_validator"

echo "========================================="
echo "Pipeline Validator Startup"
echo "========================================="
echo "Node :    $(hostname)"
echo "Time :    $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Runtime : $CONTAINER_RT"
echo ""

if [[ -z "${PROXY_NODE:-}" ]]; then
    echo "ERROR: PROXY_NODE environment variable not set"
    exit 1
fi

ZMQ_ENDPOINT="tcp://${PROXY_NODE}:${ZMQ_PORT}"
echo "ZMQ PULL endpoint: $ZMQ_ENDPOINT"
echo "Validator args: ${VALIDATOR_ARGS[*]:-<defaults>}"
echo ""

$CONTAINER_RT run --rm --network host \
    "$PROXY_IMAGE" \
    "$VALIDATOR_BIN" \
        --endpoint "$ZMQ_ENDPOINT" \
        "${VALIDATOR_ARGS[@]}" \
    2>&1 | tee validator.log

EXIT_CODE=${PIPESTATUS[0]}
echo ""
echo "Validator exited with code: $EXIT_CODE"
exit $EXIT_CODE
