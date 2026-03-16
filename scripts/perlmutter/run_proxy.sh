#!/bin/bash
# Wrapper script to run ejfat_zmq_proxy on Perlmutter compute node
#
# Usage:
#   ./run_proxy.sh
#
# Requires:
#   - SLURM_SUBMIT_DIR environment variable (set by SLURM)
#   - INSTANCE_URI file in current directory
#   - Proxy binary at $SLURM_SUBMIT_DIR/build/bin/ejfat_zmq_proxy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Locate proxy binary
PROXY_BIN="${SLURM_SUBMIT_DIR}/build/bin/ejfat_zmq_proxy"

if [[ ! -x "$PROXY_BIN" ]]; then
    echo "ERROR: Proxy binary not found or not executable: $PROXY_BIN"
    echo "Build the proxy first on the login node:"
    echo "  cd $SLURM_SUBMIT_DIR/build"
    echo "  cmake .. && make -j8"
    exit 1
fi

echo "Proxy binary: $PROXY_BIN"
echo "Config: perlmutter_config.yaml"
echo ""

# Run proxy with config, tee output to log
echo "Starting proxy..."
echo ""

"$PROXY_BIN" -c perlmutter_config.yaml 2>&1 | tee proxy.log

# Capture exit code
EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "Proxy exited with code: $EXIT_CODE"

exit $EXIT_CODE
