#!/bin/bash
# start_proxy.sh — Launch ejfat_zmq_proxy on a remote host
#
# Generates the proxy YAML config locally via envsubst, uploads it to the
# remote host via scp, then starts the proxy via SSH. Waits until the proxy
# logs "All components started" before returning.
#
# Usage (from scripts/MacOS/distributed/):
#   ./start_proxy.sh                     # uses PROXY_HOST from distributed_env.sh
#   ./start_proxy.sh user@myhost         # override PROXY_HOST
#   PROXY_HOST=user@myhost ./start_proxy.sh
#
# The script can be run standalone or called by run_pipeline.sh.
# When standalone, it creates a new run directory under runs/distributed_<timestamp>/.
# When called from run_pipeline.sh, DIST_RUN_ID is already set, so both share
# the same run directory.
#
# Exit codes:
#   0 — Proxy launched and ready
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
[[ -n "${1:-}" ]] && PROXY_HOST="$1"

#=============================================================================
# Initialize
#=============================================================================
dist_init

echo "=== Starting proxy on ${PROXY_HOST} ==="
echo "    Run directory: ${LOCAL_RUN_DIR}"
echo ""

#=============================================================================
# Validate environment
#=============================================================================
if [[ -z "${PROXY_HOST:-}" ]]; then
    echo "ERROR: PROXY_HOST is not set. Set it in distributed_env.local.sh or pass as argument." >&2
    exit 1
fi
if [[ -z "${PROXY_DATA_IP:-}" ]]; then
    echo "ERROR: PROXY_DATA_IP is not set." >&2
    exit 1
fi

#=============================================================================
# EJFAT URI
#=============================================================================
if [[ "${PIPELINE_MODE}" == "b2b" ]]; then
    EJFAT_URI="$(dist_construct_b2b_uri)"
fi
if [[ -z "${EJFAT_URI:-}" ]]; then
    echo "ERROR: EJFAT_URI is required (or use PIPELINE_MODE=b2b for auto-construction)." >&2
    exit 1
fi

#=============================================================================
# Generate config locally
#=============================================================================
echo "Generating proxy config..."
CONFIG_FILE="$(dist_generate_config)"
echo "  Config: ${CONFIG_FILE}"
echo ""

#=============================================================================
# Create remote run directory and upload config
#=============================================================================
echo "Creating remote run directory on ${PROXY_HOST}..."
REMOTE_RUN_DIR="$(dist_make_remote_dir "${PROXY_HOST}")"
echo "  Remote dir: ${REMOTE_RUN_DIR}"

echo "Uploading config..."
dist_scp_to "${CONFIG_FILE}" "${PROXY_HOST}" "${REMOTE_RUN_DIR}/proxy_config.yaml"
echo "  Uploaded to ${PROXY_HOST}:${REMOTE_RUN_DIR}/proxy_config.yaml"
echo ""

#=============================================================================
# Launch proxy
#=============================================================================
PROXY_LOG="${LOCAL_RUN_DIR}/proxy.log"
echo "Launching proxy..."
dist_ssh_bg \
    "${PROXY_HOST}" \
    "${REMOTE_PROXY_BIN} -c ${REMOTE_RUN_DIR}/proxy_config.yaml" \
    "${PROXY_LOG}" \
    "DIST_PROXY_SSH_PID"

echo "  SSH PID: ${DIST_PROXY_SSH_PID}"
echo "  Log: ${PROXY_LOG}"

# Write PID file for stop_all.sh and run_pipeline.sh
echo "${DIST_PROXY_SSH_PID}" > "${LOCAL_RUN_DIR}/proxy_ssh.pid"
echo "${PROXY_HOST}" > "${LOCAL_RUN_DIR}/proxy.host"

#=============================================================================
# Wait for readiness
#=============================================================================
echo ""
echo "Waiting for proxy to become ready (timeout: ${PROXY_READY_TIMEOUT}s)..."
if ! dist_poll_log \
        "${PROXY_LOG}" \
        "All components started" \
        "${PROXY_READY_TIMEOUT}" \
        "Proxy" \
        "${DIST_PROXY_SSH_PID}"; then
    echo "ERROR: Proxy failed to start." >&2
    exit 1
fi

#=============================================================================
# Fetch and record remote PID
#=============================================================================
REMOTE_PID="$(dist_remote_pid "${PROXY_HOST}" "ejfat_zmq_proxy")"
echo "${REMOTE_PID}" > "${LOCAL_RUN_DIR}/proxy_remote.pid"
echo "  Remote PID: ${REMOTE_PID}"

echo ""
echo "Proxy is running on ${PROXY_HOST}"
echo "  Config:     ${REMOTE_RUN_DIR}/proxy_config.yaml"
echo "  Data port:  ${PROXY_DATA_IP}:${DATA_PORT} (E2SAR UDP)"
echo "  ZMQ port:   ${PROXY_DATA_IP}:${ZMQ_PORT} (PUSH)"
echo ""
echo "To stop: dist_stop_remote ${PROXY_HOST} ejfat_zmq_proxy"
echo "         or: ./stop_all.sh"
