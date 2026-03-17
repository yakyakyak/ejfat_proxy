#!/bin/bash
# Run zmq_ejfat_bridge on a Perlmutter compute node (pipeline test N2)
#
# Receives from ZMQ PULL (connected to pipeline_sender on N1) and
# forwards events into EJFAT via the E2SAR Segmenter.
#
# Requires:
#   - INSTANCE_URI file in current directory (created by minimal_reserve.sh)
#   - SENDER_NODE  : hostname of N1 (pipeline_sender)
#   - SENDER_ZMQ_PORT (default: 5556)
#   - PROXY_IMAGE  : container image with zmq_ejfat_bridge binary
#     (default: ejfat-zmq-proxy:latest)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROXY_IMAGE="${PROXY_IMAGE:-ejfat-zmq-proxy:latest}"
BRIDGE_BIN="/build/ejfat_zmq_proxy/build/bin/zmq_ejfat_bridge"
SENDER_ZMQ_PORT="${SENDER_ZMQ_PORT:-5556}"

echo "========================================="
echo "ZMQ->EJFAT Bridge Startup"
echo "========================================="
echo "Node : $(hostname)"
echo "Time : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Load EJFAT instance URI
INSTANCE_URI_FILE="INSTANCE_URI"
if [[ ! -f "$INSTANCE_URI_FILE" ]]; then
    echo "ERROR: $INSTANCE_URI_FILE not found"
    exit 1
fi

EJFAT_URI=$(grep -E '^export EJFAT_URI=' "$INSTANCE_URI_FILE" | head -1 \
    | sed "s/^export EJFAT_URI=//; s/^['\"]//; s/['\"]$//")

if [[ -z "$EJFAT_URI" ]]; then
    echo "ERROR: EJFAT_URI not found in $INSTANCE_URI_FILE"
    exit 1
fi

EJFAT_URI_REDACTED=$(echo "$EJFAT_URI" \
    | sed -E 's|(://)(.{4})[^@]*(.{4})@|\1\2---\3@|')
echo "EJFAT_URI  : $EJFAT_URI_REDACTED"

# Validate required env
if [[ -z "${SENDER_NODE:-}" ]]; then
    echo "ERROR: SENDER_NODE environment variable not set"
    exit 1
fi

ZMQ_ENDPOINT="tcp://${SENDER_NODE}:${SENDER_ZMQ_PORT}"
echo "ZMQ PULL   : $ZMQ_ENDPOINT"
echo "Image      : $PROXY_IMAGE"
echo ""

echo "Starting bridge..."
echo ""

podman-hpc run --rm --network host \
    -v "$(pwd):/job:ro" \
    -e "EJFAT_URI=${EJFAT_URI}" \
    "$PROXY_IMAGE" \
    "$BRIDGE_BIN" \
        --uri "$EJFAT_URI" \
        --zmq-endpoint "$ZMQ_ENDPOINT" \
        --data-id 1 \
        --src-id 2 \
        --mtu 9000 \
        --sockets 16 \
    2>&1 | tee bridge.log

EXIT_CODE=${PIPESTATUS[0]}
echo ""
echo "Bridge exited with code: $EXIT_CODE"
exit $EXIT_CODE
