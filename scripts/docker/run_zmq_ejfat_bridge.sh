#!/bin/bash
# Run zmq_ejfat_bridge locally via docker or podman-hpc
#
# Receives from ZMQ PULL (connected to pipeline_sender) and
# forwards events into EJFAT via the E2SAR Segmenter.
#
# Requires:
#   - INSTANCE_URI file in current directory (created by minimal_reserve.sh)
#   - SENDER_NODE      : hostname of ZMQ sender 1 (required)
#   - SENDER_ZMQ_PORT  : port for sender 1 (default: 5556)
#   - SENDER_NODE2     : hostname of ZMQ sender 2 (optional; enables second queue)
#   - SENDER_ZMQ_PORT2 : port for sender 2 (default: 5557)
#   - BRIDGE_DATA_ID   : E2SAR data ID (default: 1)
#   - BRIDGE_SRC_ID    : E2SAR source ID (default: 2)
#   - BRIDGE_LOG       : log file name (default: bridge.log)
#   - PROXY_IMAGE      : container image (default: ejfat-zmq-proxy:latest)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=container_runtime.sh
source "$SCRIPT_DIR/container_runtime.sh"

PROXY_IMAGE="${PROXY_IMAGE:-ejfat-zmq-proxy:latest}"
BRIDGE_BIN="/build/ejfat_zmq_proxy/build/bin/zmq_ejfat_bridge"
SENDER_ZMQ_PORT="${SENDER_ZMQ_PORT:-5556}"
SENDER_ZMQ_PORT2="${SENDER_ZMQ_PORT2:-5557}"
BRIDGE_DATA_ID="${BRIDGE_DATA_ID:-1}"
BRIDGE_SRC_ID="${BRIDGE_SRC_ID:-2}"
BRIDGE_LOG="${BRIDGE_LOG:-bridge.log}"

echo "========================================="
echo "ZMQ->EJFAT Bridge Startup"
echo "========================================="
echo "Node :    $(hostname)"
echo "Time :    $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Runtime : $CONTAINER_RT"
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
echo "ZMQ PULL[0]: $ZMQ_ENDPOINT"
if [[ -n "${SENDER_NODE2:-}" ]]; then
    ZMQ_ENDPOINT2="tcp://${SENDER_NODE2}:${SENDER_ZMQ_PORT2}"
    echo "ZMQ PULL[1]: $ZMQ_ENDPOINT2"
fi
echo "Data ID    : $BRIDGE_DATA_ID"
echo "Src ID     : $BRIDGE_SRC_ID"
echo "Image      : $PROXY_IMAGE"

# Auto-detect sender IP (HSN IP used for UDP sending) so the LB CP
# registers the same IP the Segmenter will actually send from.
LB_HOST=$(echo "$EJFAT_URI" | sed 's|.*@\([^:]*\):.*|\1|')
LB_IP=$(getent ahostsv4 "$LB_HOST" 2>/dev/null | head -1 | awk '{print $1}')
SENDER_IP=$(ip route get "$LB_IP" 2>/dev/null | head -1 | sed 's/^.*src//' | awk '{print $1}')
echo "Sender IP  : ${SENDER_IP:-<auto>}"
echo ""

echo "Starting bridge..."
echo ""

EXTRA_ENDPOINTS=()
if [[ -n "${SENDER_NODE2:-}" ]]; then
    EXTRA_ENDPOINTS=(--zmq-endpoint "$ZMQ_ENDPOINT2")
fi

$CONTAINER_RT run --rm --network host \
    -v "$(pwd):/job:ro" \
    -e "EJFAT_URI=${EJFAT_URI}" \
    "$PROXY_IMAGE" \
    "$BRIDGE_BIN" \
        --uri "$EJFAT_URI" \
        --zmq-endpoint "$ZMQ_ENDPOINT" \
        "${EXTRA_ENDPOINTS[@]}" \
        --data-id "$BRIDGE_DATA_ID" \
        --src-id "$BRIDGE_SRC_ID" \
        --mtu 9000 \
        --sockets 16 \
        ${SENDER_IP:+--sender-ip "$SENDER_IP"} \
    2>&1 | tee "$BRIDGE_LOG"

EXIT_CODE=${PIPESTATUS[0]}
echo ""
echo "Bridge exited with code: $EXIT_CODE"
exit $EXIT_CODE
