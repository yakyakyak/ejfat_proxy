#!/bin/bash
# Wrapper script to run ejfat_zmq_proxy locally via docker or podman-hpc
#
# Usage:
#   ./run_proxy.sh
#
# Requires:
#   - INSTANCE_URI file in current directory (or B2B_MODE=true for back-to-back)
#   - Container image ejfat-zmq-proxy:latest
#
# Environment:
#   PROXY_IMAGE   Container image (default: ejfat-zmq-proxy:latest)
#   B2B_MODE      Set to 'true' to use back-to-back config (no LB required)
#   + all config variables accepted by generate_config.sh / b2b_generate_config.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=container_runtime.sh
source "$SCRIPT_DIR/container_runtime.sh"

PROXY_IMAGE="${PROXY_IMAGE:-ejfat-zmq-proxy:latest}"
PROXY_BIN="/build/ejfat_zmq_proxy/build/bin/ejfat_zmq_proxy"

echo "========================================="
echo "EJFAT ZMQ Proxy Startup"
echo "========================================="
echo "Node:    $(hostname)"
echo "Time:    $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Runtime: $CONTAINER_RT"
echo ""

# Generate config
echo "Generating config..."
if [[ "${B2B_MODE:-false}" == "true" ]]; then
    "$SCRIPT_DIR/b2b_generate_config.sh" proxy_config.yaml
else
    "$SCRIPT_DIR/generate_config.sh" proxy_config.yaml
fi

if [[ ! -f proxy_config.yaml ]]; then
    echo "ERROR: Failed to generate config"
    exit 1
fi

echo ""
echo "Proxy image: $PROXY_IMAGE"
echo "Config: $(pwd)/proxy_config.yaml"
echo ""

# Run container in background so we can trap SIGTERM and forward it.
echo "Starting proxy..."
echo ""

CONTAINER_PID=""
cleanup_container() {
    if [[ -n "$CONTAINER_PID" ]]; then
        echo "run_proxy.sh: forwarding SIGTERM to $CONTAINER_RT (PID $CONTAINER_PID)..."
        kill -TERM "$CONTAINER_PID" 2>/dev/null || true
    fi
}
trap cleanup_container TERM INT

$CONTAINER_RT run --rm --network host \
    -v "$(pwd):/job:ro" \
    "$PROXY_IMAGE" \
    "$PROXY_BIN" -c /job/proxy_config.yaml > proxy.log 2>&1 &
CONTAINER_PID=$!

wait "$CONTAINER_PID"
EXIT_CODE=$?

echo ""
echo "Proxy exited with code: $EXIT_CODE"

exit $EXIT_CODE
