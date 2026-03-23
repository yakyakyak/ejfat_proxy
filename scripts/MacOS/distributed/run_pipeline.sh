#!/bin/bash
# run_pipeline.sh — Orchestrate the full distributed pipeline test
#
# Launches all 4 components in the correct order across remote hosts:
#   Phase 0: Pre-flight (SSH connectivity + binary checks)
#   Phase 1: Start proxy   (waits for "All components started")
#   Phase 2: Start validator (background, brief settle)
#   Phase 3: Start sender  (background, must bind before bridge connects)
#   Phase 4: Start bridge  (waits for "ZMQ EJFAT Bridge started")
#   Phase 5: Wait for sender to finish
#   Phase 6: Drain pipeline (DRAIN_TIME), wait for validator
#   Phase 7: Print summary (PASS/FAIL)
#   Cleanup: SIGTERM all remote components in reverse order
#
# Usage (from scripts/MacOS/distributed/):
#   ./run_pipeline.sh                    # uses distributed_env.local.sh
#   ./run_pipeline.sh --count 500        # override message count
#   ./run_pipeline.sh --skip-preflight   # skip SSH/binary checks
#
# Environment:
#   Source distributed_env.local.sh before running, or set variables inline:
#   SENDER_COUNT=2000 ./run_pipeline.sh
#
# Exit codes:
#   0 — PASS (validator exited 0)
#   1 — FAIL (validator errors, timeout, or component failure)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/ssh_common.sh"

#=============================================================================
# Argument parsing
#=============================================================================
SKIP_PREFLIGHT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --count)          SENDER_COUNT="$2";    shift 2 ;;
        --size)           SENDER_SIZE="$2";     shift 2 ;;
        --rate)           SENDER_RATE="$2";     shift 2 ;;
        --drain)          DRAIN_TIME="$2";      shift 2 ;;
        --skip-preflight) SKIP_PREFLIGHT=true;  shift ;;
        --help|-h)
            sed -n '2,/^set /p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1 (use --help)"; exit 1 ;;
    esac
done

#=============================================================================
# Initialize shared state
# dist_init is called once here; all start_*.sh scripts that use DIST_RUN_ID
# share the same run directory.
#=============================================================================
dist_init

echo "╔══════════════════════════════════════════════════════════╗"
echo "║           Distributed Pipeline Test                      ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Run ID:    ${DIST_RUN_ID}"
echo "  Run dir:   ${LOCAL_RUN_DIR}"
echo "  Mode:      ${PIPELINE_MODE}"
echo "  Sender:    ${SENDER_HOST}"
echo "  Bridge:    ${BRIDGE_HOST}"
echo "  Proxy:     ${PROXY_HOST}"
echo "  Validator: ${VALIDATOR_HOST}"
echo ""

#=============================================================================
# Process tracking (SSH PIDs of background components)
#=============================================================================
PROXY_SSH_PID=""
BRIDGE_SSH_PID=""
SENDER_SSH_PID=""
VALIDATOR_SSH_PID=""
CLEANUP_DONE=false
VALIDATOR_EXIT=0

#=============================================================================
# Cleanup trap
# Runs on EXIT, INT, TERM. Stops all remote components in reverse order
# (bridge first so no new data enters the pipeline), then collects logs.
#=============================================================================
cleanup() {
    [[ "${CLEANUP_DONE}" == "true" ]] && return
    CLEANUP_DONE=true

    echo ""
    echo "--- Cleanup ---"

    # Kill remote processes via SSH (pkill -TERM)
    for spec in \
        "${BRIDGE_HOST:-}:zmq_ejfat_bridge:${BRIDGE_SSH_PID:-}" \
        "${SENDER_HOST:-}:pipeline_sender:${SENDER_SSH_PID:-}" \
        "${VALIDATOR_HOST:-}:pipeline_validator:${VALIDATOR_SSH_PID:-}" \
        "${PROXY_HOST:-}:ejfat_zmq_proxy:${PROXY_SSH_PID:-}"; do

        local host="${spec%%:*}"
        local rest="${spec#*:}"
        local binary="${rest%%:*}"
        local local_pid="${rest#*:}"

        [[ -z "${host}" ]] && continue

        echo "  Stopping ${binary} on ${host}..."
        dist_stop_remote "${host}" "${binary}" 5 "${local_pid}" 2>/dev/null || true
    done

    # Brief pause for ports to release
    sleep 2

    echo "  Collecting logs..."
    for spec in \
        "${PROXY_HOST:-}:proxy" \
        "${BRIDGE_HOST:-}:bridge" \
        "${SENDER_HOST:-}:sender" \
        "${VALIDATOR_HOST:-}:validator"; do

        local host="${spec%%:*}"
        local component="${spec#*:}"
        local remote_dir="${REMOTE_RUN_DIR_BASE}/${DIST_RUN_ID}"

        [[ -z "${host}" ]] && continue
        dist_collect_logs "${host}" "${remote_dir}" "${component}" || true
    done

    echo "  Cleanup done."
}

trap cleanup EXIT INT TERM

#=============================================================================
# Phase 0: Pre-flight
#=============================================================================
if [[ "${SKIP_PREFLIGHT}" == "false" ]]; then
    dist_preflight || exit 1
fi

#=============================================================================
# Phase 1: EJFAT URI
#=============================================================================
if [[ "${PIPELINE_MODE}" == "b2b" ]]; then
    EJFAT_URI="$(dist_construct_b2b_uri)"
    echo "B2B mode URI: ${EJFAT_URI}"
    echo ""
fi

# Resolve sender IP early (needed by bridge, printed in summary)
dist_resolve_sender_ip

#=============================================================================
# Phase 2: Start proxy
#=============================================================================
echo "┌─ Phase 1: Start proxy ─────────────────────────────────────┐"

CONFIG_FILE="$(dist_generate_config)"
echo "  Config: ${CONFIG_FILE}"

PROXY_REMOTE_DIR="$(dist_make_remote_dir "${PROXY_HOST}")"
dist_scp_to "${CONFIG_FILE}" "${PROXY_HOST}" "${PROXY_REMOTE_DIR}/proxy_config.yaml"

PROXY_LOG="${LOCAL_RUN_DIR}/proxy.log"
dist_ssh_bg \
    "${PROXY_HOST}" \
    "${REMOTE_PROXY_BIN} -c ${PROXY_REMOTE_DIR}/proxy_config.yaml" \
    "${PROXY_LOG}" \
    "PROXY_SSH_PID"

echo "${PROXY_SSH_PID}" > "${LOCAL_RUN_DIR}/proxy_ssh.pid"
echo "${PROXY_HOST}"    > "${LOCAL_RUN_DIR}/proxy.host"

echo "  Waiting for proxy ready..."
dist_poll_log \
    "${PROXY_LOG}" "All components started" \
    "${PROXY_READY_TIMEOUT}" "Proxy" "${PROXY_SSH_PID}" || exit 1

PROXY_REMOTE_PID="$(dist_remote_pid "${PROXY_HOST}" "ejfat_zmq_proxy")"
echo "${PROXY_REMOTE_PID}" > "${LOCAL_RUN_DIR}/proxy_remote.pid"

echo "└────────────────────────────────────────────────────────────┘"
echo ""

#=============================================================================
# Phase 3: Start validator
#=============================================================================
echo "┌─ Phase 2: Start validator ──────────────────────────────────┐"

VALIDATOR_REMOTE_DIR="$(dist_make_remote_dir "${VALIDATOR_HOST}")"
VALIDATOR_LOG="${LOCAL_RUN_DIR}/validator.log"

dist_ssh_bg \
    "${VALIDATOR_HOST}" \
    "${REMOTE_VALIDATOR_BIN} \
      --endpoint 'tcp://${PROXY_DATA_IP}:${ZMQ_PORT}' \
      --expected ${SENDER_COUNT} \
      --timeout ${VALIDATOR_TIMEOUT}" \
    "${VALIDATOR_LOG}" \
    "VALIDATOR_SSH_PID"

echo "${VALIDATOR_SSH_PID}"  > "${LOCAL_RUN_DIR}/validator_ssh.pid"
echo "${VALIDATOR_HOST}"     > "${LOCAL_RUN_DIR}/validator.host"

echo "  Validator running on ${VALIDATOR_HOST} (PID ${VALIDATOR_SSH_PID})"
echo "  Connecting to tcp://${PROXY_DATA_IP}:${ZMQ_PORT}"
sleep 1   # brief settle — let ZMQ PULL socket connect before data flows

echo "└────────────────────────────────────────────────────────────┘"
echo ""

#=============================================================================
# Phase 4: Start sender (background — must bind before bridge connects)
#=============================================================================
echo "┌─ Phase 3: Start sender ─────────────────────────────────────┐"

SENDER_REMOTE_DIR="$(dist_make_remote_dir "${SENDER_HOST}")"
SENDER_LOG="${LOCAL_RUN_DIR}/sender.log"

dist_ssh_bg \
    "${SENDER_HOST}" \
    "${REMOTE_SENDER_BIN} \
      --endpoint 'tcp://*:${SENDER_ZMQ_PORT}' \
      --count ${SENDER_COUNT} \
      --size ${SENDER_SIZE} \
      --rate ${SENDER_RATE}" \
    "${SENDER_LOG}" \
    "SENDER_SSH_PID"

echo "${SENDER_SSH_PID}" > "${LOCAL_RUN_DIR}/sender_ssh.pid"
echo "${SENDER_HOST}"    > "${LOCAL_RUN_DIR}/sender.host"

echo "  Sender running on ${SENDER_HOST} (PID ${SENDER_SSH_PID})"
echo "  Binding tcp://*:${SENDER_ZMQ_PORT}"
sleep 1   # allow sender to bind its ZMQ PUSH socket before bridge connects

echo "└────────────────────────────────────────────────────────────┘"
echo ""

#=============================================================================
# Phase 5: Start bridge
#=============================================================================
echo "┌─ Phase 4: Start bridge ─────────────────────────────────────┐"

NO_CP_FLAG=""
[[ "${PIPELINE_MODE}" == "b2b" ]] && NO_CP_FLAG="--no-cp"

BRIDGE_REMOTE_DIR="$(dist_make_remote_dir "${BRIDGE_HOST}")"
BRIDGE_LOG="${LOCAL_RUN_DIR}/bridge.log"

dist_ssh_bg \
    "${BRIDGE_HOST}" \
    "${REMOTE_BRIDGE_BIN} \
      --uri '${EJFAT_URI}' \
      --zmq-endpoint 'tcp://${SENDER_IP}:${SENDER_ZMQ_PORT}' \
      --mtu ${BRIDGE_MTU} \
      --sockets ${BRIDGE_SOCKETS} \
      --workers ${BRIDGE_WORKERS} \
      ${NO_CP_FLAG}" \
    "${BRIDGE_LOG}" \
    "BRIDGE_SSH_PID"

echo "${BRIDGE_SSH_PID}" > "${LOCAL_RUN_DIR}/bridge_ssh.pid"
echo "${BRIDGE_HOST}"    > "${LOCAL_RUN_DIR}/bridge.host"

echo "  Waiting for bridge ready..."
dist_poll_log \
    "${BRIDGE_LOG}" "ZMQ EJFAT Bridge started" \
    "${BRIDGE_READY_TIMEOUT}" "Bridge" "${BRIDGE_SSH_PID}" || exit 1

BRIDGE_REMOTE_PID="$(dist_remote_pid "${BRIDGE_HOST}" "zmq_ejfat_bridge")"
echo "${BRIDGE_REMOTE_PID}" > "${LOCAL_RUN_DIR}/bridge_remote.pid"

echo "└────────────────────────────────────────────────────────────┘"
echo ""
echo "All components running. Data is flowing."
echo ""

#=============================================================================
# Phase 6: Wait for sender to finish
#=============================================================================
echo "┌─ Phase 5: Waiting for sender to complete ───────────────────┐"
wait "${SENDER_SSH_PID}" 2>/dev/null || true
SENDER_EXIT=$?
echo "${SENDER_EXIT}" > "${LOCAL_RUN_DIR}/sender.exit"

if [[ "${SENDER_EXIT}" == "0" ]]; then
    echo "  Sender finished (exit 0) — all ${SENDER_COUNT} messages sent"
else
    echo "  WARNING: Sender exited with code ${SENDER_EXIT}"
fi
echo "└────────────────────────────────────────────────────────────┘"
echo ""

#=============================================================================
# Phase 7: Drain + wait for validator
#=============================================================================
echo "┌─ Phase 6: Draining pipeline (${DRAIN_TIME}s) ───────────────────────┐"
echo "  Waiting ${DRAIN_TIME}s for remaining messages to flush through..."
sleep "${DRAIN_TIME}"

echo "  Waiting for validator to finish..."
wait "${VALIDATOR_SSH_PID}" 2>/dev/null || true
VALIDATOR_EXIT=$?
echo "${VALIDATOR_EXIT}" > "${LOCAL_RUN_DIR}/validator.exit"
echo "  Validator exited with code ${VALIDATOR_EXIT}"
echo "└────────────────────────────────────────────────────────────┘"
echo ""

#=============================================================================
# Phase 8: Summary
#=============================================================================
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    TEST SUMMARY                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Run ID:  ${DIST_RUN_ID}"
echo "  Logs:    ${LOCAL_RUN_DIR}/"
echo ""

dist_print_log_tail "${LOCAL_RUN_DIR}/proxy.log"      "Proxy log"
dist_print_log_tail "${LOCAL_RUN_DIR}/bridge.log"     "Bridge log"
dist_print_log_tail "${LOCAL_RUN_DIR}/sender.log"     "Sender log"
dist_print_log_tail "${LOCAL_RUN_DIR}/validator.log"  "Validator log"

echo ""
case "${VALIDATOR_EXIT}" in
    0) echo "  ✓ RESULT: PASS (all messages received and validated)" ;;
    1) echo "  ✗ RESULT: FAIL (validation errors — see validator.log)" ;;
    2) echo "  ✗ RESULT: FAIL (timeout — not all messages received)" ;;
    *) echo "  ✗ RESULT: FAIL (validator exited ${VALIDATOR_EXIT})" ;;
esac
echo ""

# Cleanup runs via EXIT trap
exit "${VALIDATOR_EXIT}"
