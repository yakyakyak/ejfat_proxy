#!/bin/bash
# stop_all.sh — Stop all distributed pipeline components
#
# Reads PID files from the most recent (or specified) run directory and
# sends SIGTERM to all remote processes in reverse order:
#   bridge → sender → validator → proxy
#
# Usage (from scripts/MacOS/distributed/):
#   ./stop_all.sh                        # stop latest run
#   ./stop_all.sh runs/distributed_XYZ   # stop a specific run
#
# Can also be used to abort a hung run_pipeline.sh session without restarting
# the orchestrator.

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

#=============================================================================
# Initialize (creates LOCAL_RUN_DIR, but we override it below)
#=============================================================================
dist_init

# Override: use specified run dir or find the latest one
if [[ -n "${1:-}" ]]; then
    # Absolute or project-relative path
    if [[ "${1}" == /* ]]; then
        TARGET_RUN_DIR="$1"
    else
        TARGET_RUN_DIR="${DIST_PROJECT_ROOT}/${1}"
    fi
else
    # Find the latest distributed run directory
    TARGET_RUN_DIR="$(ls -dt "${DIST_PROJECT_ROOT}/runs/distributed_"* 2>/dev/null | head -1)"
    if [[ -z "${TARGET_RUN_DIR}" ]]; then
        echo "No distributed run directories found in ${DIST_PROJECT_ROOT}/runs/"
        exit 0
    fi
fi

if [[ ! -d "${TARGET_RUN_DIR}" ]]; then
    echo "ERROR: Run directory not found: ${TARGET_RUN_DIR}" >&2
    exit 1
fi

echo "Stopping components in run: $(basename "${TARGET_RUN_DIR}")"
echo "  Run dir: ${TARGET_RUN_DIR}"
echo ""

#=============================================================================
# Stop each component (reverse pipeline order: bridge → sender → validator → proxy)
#=============================================================================
stop_component() {
    local name="$1"
    local binary="$2"

    local host_file="${TARGET_RUN_DIR}/${name}.host"
    local ssh_pid_file="${TARGET_RUN_DIR}/${name}_ssh.pid"

    if [[ ! -f "${host_file}" ]]; then
        echo "  ${name}: no host file (not launched or already stopped)"
        return
    fi

    local host
    host="$(cat "${host_file}")"
    local local_pid=""
    [[ -f "${ssh_pid_file}" ]] && local_pid="$(cat "${ssh_pid_file}")"

    printf "  %-12s on %-40s ... " "${name}" "${host}"
    dist_stop_remote "${host}" "${binary}" 10 "${local_pid}" 2>/dev/null
    echo "stopped"
}

stop_component "bridge"    "zmq_ejfat_bridge"
stop_component "sender"    "pipeline_sender"
stop_component "validator" "pipeline_validator"
stop_component "proxy"     "ejfat_zmq_proxy"

echo ""
echo "All components signaled. Waiting 3s for ports to release..."
sleep 3
echo "Done."
