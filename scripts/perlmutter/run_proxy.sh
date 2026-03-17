#!/bin/bash
# Wrapper script to run ejfat_zmq_proxy on Perlmutter compute node
#
# Usage:
#   ./run_proxy.sh
#
# Requires:
#   - SLURM_SUBMIT_DIR environment variable (set by SLURM)
#   - INSTANCE_URI file in current directory
#   - Container image ejfat-zmq-proxy:latest migrated via: podman-hpc migrate ejfat-zmq-proxy:latest

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROXY_IMAGE="${PROXY_IMAGE:-ejfat-zmq-proxy:latest}"
PROXY_BIN="/build/ejfat_zmq_proxy/build/bin/ejfat_zmq_proxy"

echo "========================================="
echo "EJFAT ZMQ Proxy Startup"
echo "========================================="
echo "Node: $(hostname)"
echo "Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Generate config
echo "Generating config..."
"$SCRIPT_DIR/generate_config.sh" perlmutter_config.yaml

if [[ ! -f perlmutter_config.yaml ]]; then
    echo "ERROR: Failed to generate config"
    exit 1
fi

echo ""
echo "Proxy image: $PROXY_IMAGE"
echo "Config: $(pwd)/perlmutter_config.yaml"
echo ""

# Run proxy inside container, bind-mounting current dir (JOB_DIR) read-only for config access.
# stdout/stderr are captured by tee on the host — no write access needed inside the container.
echo "Starting proxy..."
echo ""

podman-hpc run --rm --network host \
    -v "$(pwd):/job:ro" \
    "$PROXY_IMAGE" \
    "$PROXY_BIN" -c /job/perlmutter_config.yaml 2>&1 | tee proxy.log

# Capture exit code
EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "Proxy exited with code: $EXIT_CODE"

exit $EXIT_CODE
