#!/bin/bash
# Run pipeline_sender (C++) locally via docker or podman-hpc
#
# Requires:
#   - SENDER_ZMQ_PORT : ZMQ port (default: 5556)
#   - SENDER_LOG      : log file name (default: sender.log)
#   - PROXY_IMAGE     : container image (default: ejfat-zmq-proxy:latest)
#
# Options passed through to pipeline_sender:
#   --count N, --size N, --rate N, --start-seq N

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=container_runtime.sh
source "$SCRIPT_DIR/container_runtime.sh"

DELAY_BEFORE_SEND="${DELAY_BEFORE_SEND:-5}"

# Parse args to forward
SENDER_ARGS=("$@")

SENDER_ZMQ_PORT="${SENDER_ZMQ_PORT:-5556}"
SENDER_LOG="${SENDER_LOG:-sender.log}"
PROXY_IMAGE="${PROXY_IMAGE:-ejfat-zmq-proxy:latest}"
SENDER_BIN="/build/ejfat_zmq_proxy/build/bin/pipeline_sender"

echo "========================================="
echo "Pipeline Sender Startup"
echo "========================================="
echo "Node :    $(hostname)"
echo "Time :    $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Runtime : $CONTAINER_RT"
echo ""

# Wait for downstream (bridge) to be ready before starting
echo "Waiting ${DELAY_BEFORE_SEND}s for bridge to connect..."
sleep "$DELAY_BEFORE_SEND"

ZMQ_ENDPOINT="tcp://*:${SENDER_ZMQ_PORT}"
echo "ZMQ PUSH endpoint: $ZMQ_ENDPOINT"
echo "Sender args: ${SENDER_ARGS[*]:-<defaults>}"
echo ""

$CONTAINER_RT run --rm --network host \
    "$PROXY_IMAGE" \
    "$SENDER_BIN" \
        --endpoint "$ZMQ_ENDPOINT" \
        "${SENDER_ARGS[@]}" \
    2>&1 | tee "$SENDER_LOG"

EXIT_CODE=${PIPESTATUS[0]}
echo ""
echo "Sender exited with code: $EXIT_CODE"
exit $EXIT_CODE
