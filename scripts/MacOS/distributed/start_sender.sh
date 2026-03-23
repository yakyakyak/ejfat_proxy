#!/bin/bash
# start_sender.sh — Launch pipeline_sender on a remote host
#
# The sender binds a ZMQ PUSH socket and produces sequenced, payload-checked
# messages. The bridge connects to this socket as a ZMQ PULL client.
#
# The sender exits naturally after --count messages are sent. When run
# standalone, this script blocks until the sender finishes. The orchestrator
# (run_pipeline.sh) uses --bg to run it in the background.
#
# Usage (from scripts/MacOS/distributed/):
#   ./start_sender.sh                    # foreground, blocks until done
#   ./start_sender.sh user@myhost        # override SENDER_HOST
#   ./start_sender.sh --bg               # background mode (for orchestrator use)
#   SENDER_COUNT=500 ./start_sender.sh
#
# Exit codes:
#   0 — Sender exited cleanly (all messages sent)
#   1 — Configuration error or sender failure

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/ssh_common.sh"

#=============================================================================
# Argument handling
#=============================================================================
BG_MODE=false
for arg in "$@"; do
    case "${arg}" in
        --bg) BG_MODE=true ;;
        --help|-h)
            sed -n '2,/^set /p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
            exit 0
            ;;
        --*) echo "Unknown option: ${arg}" >&2; exit 1 ;;
        *)   SENDER_HOST="${arg}" ;;
    esac
done

#=============================================================================
# Initialize
#=============================================================================
dist_init

echo "=== Starting sender on ${SENDER_HOST} ==="
echo "    Run directory: ${LOCAL_RUN_DIR}"
echo ""

#=============================================================================
# Validate environment
#=============================================================================
if [[ -z "${SENDER_HOST:-}" ]]; then
    echo "ERROR: SENDER_HOST is not set." >&2
    exit 1
fi

echo "Sender parameters:"
echo "  Endpoint: tcp://*:${SENDER_ZMQ_PORT} (binds, bridge connects here)"
echo "  Count:    ${SENDER_COUNT} messages"
echo "  Size:     ${SENDER_SIZE} bytes"
echo "  Rate:     ${SENDER_RATE} msg/s (0=unlimited)"
echo ""

#=============================================================================
# Create remote run directory
#=============================================================================
REMOTE_RUN_DIR="$(dist_make_remote_dir "${SENDER_HOST}")"

#=============================================================================
# Build sender command
#=============================================================================
SENDER_CMD="${REMOTE_SENDER_BIN} \
  --endpoint 'tcp://*:${SENDER_ZMQ_PORT}' \
  --count ${SENDER_COUNT} \
  --size ${SENDER_SIZE} \
  --rate ${SENDER_RATE}"

SENDER_LOG="${LOCAL_RUN_DIR}/sender.log"
echo "${SENDER_HOST}" > "${LOCAL_RUN_DIR}/sender.host"

#=============================================================================
# Launch sender
#=============================================================================
if [[ "${BG_MODE}" == "true" ]]; then
    # Background mode: used by run_pipeline.sh
    echo "Launching sender (background)..."
    dist_ssh_bg \
        "${SENDER_HOST}" \
        "${SENDER_CMD}" \
        "${SENDER_LOG}" \
        "DIST_SENDER_SSH_PID"

    echo "  SSH PID: ${DIST_SENDER_SSH_PID}"
    echo "  Log: ${SENDER_LOG}"
    echo "${DIST_SENDER_SSH_PID}" > "${LOCAL_RUN_DIR}/sender_ssh.pid"
    echo "  Sender running in background. Bridge can now connect."
else
    # Foreground mode: blocks until all messages sent
    echo "Launching sender (foreground, blocks until done)..."
    dist_ssh \
        "${SENDER_HOST}" \
        "stdbuf -oL ${SENDER_CMD}" \
        > "${SENDER_LOG}" 2>&1
    SENDER_EXIT=$?

    echo "${SENDER_EXIT}" > "${LOCAL_RUN_DIR}/sender.exit"
    echo ""
    if [[ "${SENDER_EXIT}" == "0" ]]; then
        echo "Sender completed successfully (exit 0)"
    else
        echo "ERROR: Sender exited with code ${SENDER_EXIT}" >&2
        tail -20 "${SENDER_LOG}" || true
        exit "${SENDER_EXIT}"
    fi
fi
