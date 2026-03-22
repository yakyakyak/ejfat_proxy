#!/bin/bash
# Run pipeline_sender (C++) on a Perlmutter compute node (pipeline test N1)
#
# Requires:
#   - SENDER_ZMQ_PORT (default: 5556)
#   - PROXY_IMAGE     : container image (default: ejfat-zmq-proxy:latest)
#
# Options passed through to pipeline_sender:
#   --count N, --size N, --rate N

set -euo pipefail

DELAY_BEFORE_SEND="${DELAY_BEFORE_SEND:-5}"

# Parse args to forward
SENDER_ARGS=("$@")

SENDER_ZMQ_PORT="${SENDER_ZMQ_PORT:-5556}"
PROXY_IMAGE="${PROXY_IMAGE:-ejfat-zmq-proxy:latest}"
SENDER_BIN="/build/ejfat_zmq_proxy/build/bin/pipeline_sender"

echo "========================================="
echo "Pipeline Sender Startup"
echo "========================================="
echo "Node : $(hostname)"
echo "Time : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Wait for downstream (bridge) to be ready before starting
echo "Waiting ${DELAY_BEFORE_SEND}s for bridge to connect..."
sleep "$DELAY_BEFORE_SEND"

ZMQ_ENDPOINT="tcp://*:${SENDER_ZMQ_PORT}"
echo "ZMQ PUSH endpoint: $ZMQ_ENDPOINT"
echo "Sender args: ${SENDER_ARGS[*]:-<defaults>}"
echo ""

podman-hpc run --rm --network host \
    "$PROXY_IMAGE" \
    "$SENDER_BIN" \
        --endpoint "$ZMQ_ENDPOINT" \
        "${SENDER_ARGS[@]}" \
    2>&1 | tee sender.log

EXIT_CODE=${PIPESTATUS[0]}
echo ""
echo "Sender exited with code: $EXIT_CODE"
exit $EXIT_CODE
