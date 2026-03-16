#!/bin/bash
# Wrapper script to run test_receiver.py on Perlmutter compute node
#
# Usage:
#   ./run_consumer.sh [--delay DELAY_MS]
#
# Options:
#   --delay MS    Add delay between messages (for backpressure testing)
#
# Requires:
#   - PROXY_NODE environment variable (hostname or IP of proxy node)
#   - ZMQ_PORT environment variable (default: 5555)
#   - SLURM_SUBMIT_DIR environment variable (set by SLURM)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
DELAY=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --delay)
            DELAY="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--delay DELAY_MS]"
            exit 1
            ;;
    esac
done

echo "========================================="
echo "EJFAT ZMQ Consumer Startup"
echo "========================================="
echo "Node: $(hostname)"
echo "Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Validate required environment
if [[ -z "${PROXY_NODE:-}" ]]; then
    echo "ERROR: PROXY_NODE environment variable not set"
    exit 1
fi

ZMQ_PORT="${ZMQ_PORT:-5555}"

# Locate test_receiver.py
RECEIVER_SCRIPT="${SLURM_SUBMIT_DIR}/scripts/test_receiver.py"

if [[ ! -f "$RECEIVER_SCRIPT" ]]; then
    echo "ERROR: test_receiver.py not found: $RECEIVER_SCRIPT"
    exit 1
fi

# Load Python module on Perlmutter
module load python 2>/dev/null || true

# Check if pyzmq is available
if ! python3 -c "import zmq" 2>/dev/null; then
    echo "ERROR: pyzmq not available"
    echo "Install with: pip install --user pyzmq"
    exit 1
fi

# Build ZMQ endpoint
ZMQ_ENDPOINT="tcp://${PROXY_NODE}:${ZMQ_PORT}"

echo "Proxy node: $PROXY_NODE"
echo "ZMQ endpoint: $ZMQ_ENDPOINT"

# Build command
CMD=(python3 "$RECEIVER_SCRIPT" --endpoint "$ZMQ_ENDPOINT")

if [[ -n "$DELAY" ]]; then
    CMD+=(--delay "$DELAY")
    echo "Message delay: ${DELAY}ms (backpressure mode)"
fi

echo ""
echo "Starting consumer..."
echo "Command: ${CMD[*]}"
echo ""

# Run consumer, tee output to log
"${CMD[@]}" 2>&1 | tee consumer.log

# Capture exit code
EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "Consumer exited with code: $EXIT_CODE"

exit $EXIT_CODE
