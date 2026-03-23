#!/bin/bash
# start_bridge.sh — Launch zmq_ejfat_bridge on a remote host
#
# The bridge pulls messages from the sender via ZMQ and forwards them as
# E2SAR UDP packets to the proxy. It must be started AFTER the proxy (so the
# UDP destination is ready) and AFTER the sender has bound its ZMQ port.
#
# Usage (from scripts/MacOS/distributed/):
#   ./start_bridge.sh                    # uses BRIDGE_HOST from distributed_env.sh
#   ./start_bridge.sh user@myhost        # override BRIDGE_HOST
#
# Readiness signal: "ZMQ EJFAT Bridge started" in bridge.log
#
# Exit codes:
#   0 — Bridge launched and ready
#   1 — Configuration error or launch failure

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/ssh_common.sh"

#=============================================================================
# Argument handling
#=============================================================================
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,/^set /p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit 0
fi
[[ -n "${1:-}" ]] && BRIDGE_HOST="$1"

#=============================================================================
# Initialize
#=============================================================================
dist_init

echo "=== Starting bridge on ${BRIDGE_HOST} ==="
echo "    Run directory: ${LOCAL_RUN_DIR}"
echo ""

#=============================================================================
# Validate environment
#=============================================================================
if [[ -z "${BRIDGE_HOST:-}" ]]; then
    echo "ERROR: BRIDGE_HOST is not set." >&2
    exit 1
fi
if [[ -z "${PROXY_DATA_IP:-}" ]]; then
    echo "ERROR: PROXY_DATA_IP is not set (bridge needs to know where to send UDP)." >&2
    exit 1
fi
if [[ -z "${SENDER_HOST:-}" ]]; then
    echo "ERROR: SENDER_HOST is not set (bridge needs to know where to pull ZMQ from)." >&2
    exit 1
fi

#=============================================================================
# EJFAT URI
#=============================================================================
if [[ "${PIPELINE_MODE}" == "b2b" ]]; then
    EJFAT_URI="$(dist_construct_b2b_uri)"
    echo "B2B mode: EJFAT_URI = ${EJFAT_URI}"
elif [[ -z "${EJFAT_URI:-}" ]]; then
    echo "ERROR: EJFAT_URI is required for PIPELINE_MODE=lb." >&2
    exit 1
fi

#=============================================================================
# Resolve sender IP (the bridge connects to this address)
#=============================================================================
dist_resolve_sender_ip

#=============================================================================
# Build bridge command
#=============================================================================
NO_CP_FLAG=""
[[ "${PIPELINE_MODE}" == "b2b" ]] && NO_CP_FLAG="--no-cp"

BRIDGE_CMD="${REMOTE_BRIDGE_BIN} \
  --uri '${EJFAT_URI}' \
  --zmq-endpoint 'tcp://${SENDER_IP}:${SENDER_ZMQ_PORT}' \
  --mtu ${BRIDGE_MTU} \
  --sockets ${BRIDGE_SOCKETS} \
  --workers ${BRIDGE_WORKERS} \
  ${NO_CP_FLAG}"

echo "Bridge command:"
echo "  ${BRIDGE_CMD}"
echo ""

#=============================================================================
# Create remote run directory
#=============================================================================
REMOTE_RUN_DIR="$(dist_make_remote_dir "${BRIDGE_HOST}")"

#=============================================================================
# Launch bridge
#=============================================================================
BRIDGE_LOG="${LOCAL_RUN_DIR}/bridge.log"
echo "Launching bridge..."
dist_ssh_bg \
    "${BRIDGE_HOST}" \
    "${BRIDGE_CMD}" \
    "${BRIDGE_LOG}" \
    "DIST_BRIDGE_SSH_PID"

echo "  SSH PID: ${DIST_BRIDGE_SSH_PID}"
echo "  Log: ${BRIDGE_LOG}"

echo "${DIST_BRIDGE_SSH_PID}" > "${LOCAL_RUN_DIR}/bridge_ssh.pid"
echo "${BRIDGE_HOST}" > "${LOCAL_RUN_DIR}/bridge.host"

#=============================================================================
# Wait for readiness
#=============================================================================
echo ""
echo "Waiting for bridge to become ready (timeout: ${BRIDGE_READY_TIMEOUT}s)..."
if ! dist_poll_log \
        "${BRIDGE_LOG}" \
        "ZMQ EJFAT Bridge started" \
        "${BRIDGE_READY_TIMEOUT}" \
        "Bridge" \
        "${DIST_BRIDGE_SSH_PID}"; then
    echo "ERROR: Bridge failed to start." >&2
    exit 1
fi

#=============================================================================
# Record remote PID
#=============================================================================
REMOTE_PID="$(dist_remote_pid "${BRIDGE_HOST}" "zmq_ejfat_bridge")"
echo "${REMOTE_PID}" > "${LOCAL_RUN_DIR}/bridge_remote.pid"
echo "  Remote PID: ${REMOTE_PID}"

echo ""
echo "Bridge is running on ${BRIDGE_HOST}"
echo "  ZMQ source:  tcp://${SENDER_IP}:${SENDER_ZMQ_PORT} (PULL)"
echo "  E2SAR dest:  ${PROXY_DATA_IP}:${DATA_PORT} (UDP)"
echo "  MTU: ${BRIDGE_MTU}, sockets: ${BRIDGE_SOCKETS}, workers: ${BRIDGE_WORKERS}"
echo ""
echo "To stop: ./stop_all.sh"
