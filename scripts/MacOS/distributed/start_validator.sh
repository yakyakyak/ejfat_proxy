#!/bin/bash
# start_validator.sh — Launch pipeline_validator on a remote host
#
# The validator connects to the proxy's ZMQ PUSH socket and verifies that
# all messages arrive with correct sequence numbers and payload patterns.
# It exits naturally after receiving --expected messages or when --timeout
# is reached.
#
# Readiness: The validator starts immediately (no readiness signal needed —
# it just connects and waits for data). Run it before the sender starts.
#
# Usage (from scripts/MacOS/distributed/):
#   ./start_validator.sh                 # background (default)
#   ./start_validator.sh user@myhost     # override VALIDATOR_HOST
#
# Exit codes (from the remote validator process):
#   0 — All messages received and validated
#   1 — Validation errors (missing/duplicate/corrupt messages)
#   2 — Timeout (not enough messages received)
#
# This script exits 0 once the validator is launched. The orchestrator
# (run_pipeline.sh) waits on the validator's SSH PID for the final result.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/ssh_common.sh"

#=============================================================================
# Argument handling
#=============================================================================
for arg in "$@"; do
    case "${arg}" in
        --help|-h)
            sed -n '2,/^set /p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
            exit 0
            ;;
        --*) echo "Unknown option: ${arg}" >&2; exit 1 ;;
        *)   VALIDATOR_HOST="${arg}" ;;
    esac
done

#=============================================================================
# Initialize
#=============================================================================
dist_init

echo "=== Starting validator on ${VALIDATOR_HOST} ==="
echo "    Run directory: ${LOCAL_RUN_DIR}"
echo ""

#=============================================================================
# Validate environment
#=============================================================================
if [[ -z "${VALIDATOR_HOST:-}" ]]; then
    echo "ERROR: VALIDATOR_HOST is not set." >&2
    exit 1
fi
if [[ -z "${PROXY_DATA_IP:-}" ]]; then
    echo "ERROR: PROXY_DATA_IP is not set (validator needs to know where to connect)." >&2
    exit 1
fi

echo "Validator parameters:"
echo "  Proxy endpoint: tcp://${PROXY_DATA_IP}:${ZMQ_PORT} (connects PULL)"
echo "  Expected:       ${SENDER_COUNT} messages"
echo "  Timeout:        ${VALIDATOR_TIMEOUT}s"
echo ""

#=============================================================================
# Create remote run directory
#=============================================================================
REMOTE_RUN_DIR="$(dist_make_remote_dir "${VALIDATOR_HOST}")"

#=============================================================================
# Launch validator (always in background)
#=============================================================================
VALIDATOR_CMD="${REMOTE_VALIDATOR_BIN} \
  --endpoint 'tcp://${PROXY_DATA_IP}:${ZMQ_PORT}' \
  --expected ${SENDER_COUNT} \
  --timeout ${VALIDATOR_TIMEOUT}"

VALIDATOR_LOG="${LOCAL_RUN_DIR}/validator.log"
echo "Launching validator..."
dist_ssh_bg \
    "${VALIDATOR_HOST}" \
    "${VALIDATOR_CMD}" \
    "${VALIDATOR_LOG}" \
    "DIST_VALIDATOR_SSH_PID"

echo "  SSH PID: ${DIST_VALIDATOR_SSH_PID}"
echo "  Log: ${VALIDATOR_LOG}"

echo "${DIST_VALIDATOR_SSH_PID}" > "${LOCAL_RUN_DIR}/validator_ssh.pid"
echo "${VALIDATOR_HOST}" > "${LOCAL_RUN_DIR}/validator.host"

REMOTE_PID="$(dist_remote_pid "${VALIDATOR_HOST}" "pipeline_validator")"
echo "${REMOTE_PID}" > "${LOCAL_RUN_DIR}/validator_remote.pid"
echo "  Remote PID: ${REMOTE_PID}"

echo ""
echo "Validator running on ${VALIDATOR_HOST}"
echo "  Listening on tcp://${PROXY_DATA_IP}:${ZMQ_PORT} for ${SENDER_COUNT} messages"
echo "  Results will appear in: ${VALIDATOR_LOG}"
echo ""
echo "To wait for result:"
echo "  wait ${DIST_VALIDATOR_SSH_PID}; echo \"Exit: \$?\""
