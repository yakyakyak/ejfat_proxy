#!/bin/bash
# status.sh — Check the status of all distributed pipeline components
#
# SSHes to each remote host and checks whether the component binary is
# currently running via pgrep. Prints a status table.
#
# Usage (from scripts/MacOS/distributed/):
#   ./status.sh                          # check all hosts from distributed_env.sh
#   ./status.sh runs/distributed_XYZ    # check hosts from a specific run directory
#
# Requires: PROXY_HOST, BRIDGE_HOST, SENDER_HOST, VALIDATOR_HOST to be set
# (either from distributed_env.sh or from the run directory's *.host files).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ssh_common.sh"

#=============================================================================
# Argument handling
#=============================================================================
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,/^set /p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit 0
fi

dist_init

# If a run directory is given, read hosts from its *.host files
TARGET_RUN_DIR=""
if [[ -n "${1:-}" ]]; then
    if [[ "${1}" == /* ]]; then
        TARGET_RUN_DIR="$1"
    else
        TARGET_RUN_DIR="${DIST_PROJECT_ROOT}/${1}"
    fi
elif [[ -d "${DIST_PROJECT_ROOT}/runs" ]]; then
    # Try latest run
    TARGET_RUN_DIR="$(ls -dt "${DIST_PROJECT_ROOT}/runs/distributed_"* 2>/dev/null | head -1)"
fi

if [[ -n "${TARGET_RUN_DIR}" && -d "${TARGET_RUN_DIR}" ]]; then
    echo "Reading hosts from run: $(basename "${TARGET_RUN_DIR}")"
    [[ -f "${TARGET_RUN_DIR}/proxy.host" ]]     && PROXY_HOST="$(cat "${TARGET_RUN_DIR}/proxy.host")"
    [[ -f "${TARGET_RUN_DIR}/bridge.host" ]]    && BRIDGE_HOST="$(cat "${TARGET_RUN_DIR}/bridge.host")"
    [[ -f "${TARGET_RUN_DIR}/sender.host" ]]    && SENDER_HOST="$(cat "${TARGET_RUN_DIR}/sender.host")"
    [[ -f "${TARGET_RUN_DIR}/validator.host" ]] && VALIDATOR_HOST="$(cat "${TARGET_RUN_DIR}/validator.host")"
fi

#=============================================================================
# Status check
#=============================================================================
check_component() {
    local name="$1"
    local host="$2"
    local binary="$3"

    if [[ -z "${host}" ]]; then
        printf "  %-12s %-40s %-10s %s\n" "${name}" "(not configured)" "-" "-"
        return
    fi

    # SSH check + pgrep in one connection
    local result
    result="$(dist_ssh "${host}" "pgrep -af '${binary}' | head -1" 2>/dev/null || true)"

    if [[ -n "${result}" ]]; then
        local pid
        pid="$(echo "${result}" | awk '{print $1}')"
        printf "  %-12s %-40s %-10s %s\n" "${name}" "${host}" "RUNNING" "${pid}"
    else
        # Check SSH reachability separately to distinguish STOPPED vs UNREACHABLE
        if dist_ssh "${host}" "true" >/dev/null 2>&1; then
            printf "  %-12s %-40s %-10s %s\n" "${name}" "${host}" "STOPPED" "-"
        else
            printf "  %-12s %-40s %-10s %s\n" "${name}" "${host}" "UNREACHABLE" "-"
        fi
    fi
}

echo ""
echo "Pipeline Component Status"
echo "════════════════════════════════════════════════════════════════"
printf "  %-12s %-40s %-10s %s\n" "Component" "Host" "Status" "PID"
echo "  ────────────────────────────────────────────────────────────"
check_component "proxy"     "${PROXY_HOST:-}"     "ejfat_zmq_proxy"
check_component "bridge"    "${BRIDGE_HOST:-}"    "zmq_ejfat_bridge"
check_component "sender"    "${SENDER_HOST:-}"    "pipeline_sender"
check_component "validator" "${VALIDATOR_HOST:-}" "pipeline_validator"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Show exit codes from run dir if available
if [[ -n "${TARGET_RUN_DIR}" && -d "${TARGET_RUN_DIR}" ]]; then
    echo "Run results ($(basename "${TARGET_RUN_DIR}")):"
    for f in sender.exit validator.exit; do
        if [[ -f "${TARGET_RUN_DIR}/${f}" ]]; then
            printf "  %-20s %s\n" "${f}:" "$(cat "${TARGET_RUN_DIR}/${f}")"
        fi
    done
    echo "  Logs: ${TARGET_RUN_DIR}/"
    echo ""
fi
