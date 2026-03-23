#!/bin/bash
# ssh_common.sh — Shared SSH helper functions for distributed pipeline scripts
#
# Source this file from any start_*.sh or run_pipeline.sh script:
#   source "$(dirname "${BASH_SOURCE[0]}")/ssh_common.sh"
#
# Expects to be co-located with distributed_env.sh in the same directory.

#=============================================================================
# Initialization
#   Must be the first call from any script that uses this library.
#   Sources distributed_env.sh (and .local.sh override if present),
#   validates required variables, and creates the local run directory.
#=============================================================================
dist_init() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"

    # Source env files: local override takes precedence
    if [[ -f "${script_dir}/distributed_env.local.sh" ]]; then
        # shellcheck source=distributed_env.sh
        source "${script_dir}/distributed_env.local.sh"
    elif [[ -f "${script_dir}/distributed_env.sh" ]]; then
        # shellcheck source=distributed_env.sh
        source "${script_dir}/distributed_env.sh"
    else
        echo "ERROR: distributed_env.sh not found in ${script_dir}" >&2
        exit 1
    fi

    # Resolve project root (two levels up from scripts/MacOS/distributed/)
    DIST_PROJECT_ROOT="$(cd "${script_dir}/../../.." && pwd)"

    # Config template path
    DIST_CONFIG_TEMPLATE="${DIST_CONFIG_TEMPLATE:-${DIST_PROJECT_ROOT}/config/distributed.yaml.template}"

    # Create local run directory (timestamped, under project root/runs/)
    if [[ -z "${DIST_RUN_ID:-}" ]]; then
        DIST_RUN_ID="distributed_$(date +%Y%m%d_%H%M%S)"
    fi
    LOCAL_RUN_DIR="${DIST_PROJECT_ROOT}/runs/${DIST_RUN_ID}"
    mkdir -p "${LOCAL_RUN_DIR}"

    # PID tracking (populated by dist_ssh_bg)
    DIST_PROXY_SSH_PID=""
    DIST_BRIDGE_SSH_PID=""
    DIST_SENDER_SSH_PID=""
    DIST_VALIDATOR_SSH_PID=""
}

#=============================================================================
# SSH wrapper
#   dist_ssh HOST COMMAND...
#   Runs COMMAND on HOST via SSH. Inherits current stdin/stdout/stderr.
#   Returns the remote exit code.
#=============================================================================
dist_ssh() {
    local host="$1"; shift
    local ssh_args=()

    [[ -n "${SSH_KEY:-}" ]] && ssh_args+=(-i "${SSH_KEY}")
    # shellcheck disable=SC2206
    ssh_args+=(${SSH_OPTS})
    ssh_args+=("${host}")

    ssh "${ssh_args[@]}" "$@"
}

#=============================================================================
# SSH background launcher with local log streaming
#   dist_ssh_bg HOST COMMAND LOGFILE [PID_VAR]
#
#   Launches COMMAND on HOST in a background SSH session. stdout+stderr are
#   piped to LOGFILE on the local machine. The remote command is wrapped in
#   "stdbuf -oL" to force line-buffered output through the SSH pipe (without
#   this, C++ binaries writing to non-TTY pipes buffer up to 4KB before
#   flushing, which delays readiness detection).
#
#   PID_VAR (optional): name of a shell variable to assign the SSH PID to.
#   Returns: SSH PID via $DIST_LAST_SSH_PID
#=============================================================================
dist_ssh_bg() {
    local host="$1"
    local command="$2"
    local logfile="$3"
    local pid_var="${4:-}"

    : > "${logfile}"  # truncate / create

    local ssh_args=()
    [[ -n "${SSH_KEY:-}" ]] && ssh_args+=(-i "${SSH_KEY}")
    # shellcheck disable=SC2206
    ssh_args+=(${SSH_OPTS})
    ssh_args+=("${host}" "stdbuf -oL ${command}")

    ssh "${ssh_args[@]}" >> "${logfile}" 2>&1 &
    DIST_LAST_SSH_PID=$!

    [[ -n "${pid_var}" ]] && printf -v "${pid_var}" '%s' "${DIST_LAST_SSH_PID}"
}

#=============================================================================
# Readiness poller
#   dist_poll_log LOGFILE PATTERN TIMEOUT_S LABEL
#
#   Polls LOGFILE every second looking for PATTERN (grep -q).
#   Also checks that GUARD_PID (if set) is still alive.
#   Returns 0 on match, 1 on timeout or if guard process died.
#=============================================================================
dist_poll_log() {
    local logfile="$1"
    local pattern="$2"
    local timeout_s="$3"
    local label="$4"
    local guard_pid="${5:-}"  # optional: SSH PID to liveness-check

    local i
    for i in $(seq 1 "${timeout_s}"); do
        if grep -q "${pattern}" "${logfile}" 2>/dev/null; then
            echo "${label} ready (after ${i}s)"
            return 0
        fi
        if [[ -n "${guard_pid}" ]] && ! kill -0 "${guard_pid}" 2>/dev/null; then
            echo "ERROR: ${label} process died during startup. Last log lines:" >&2
            tail -20 "${logfile}" 2>/dev/null || true
            return 1
        fi
        sleep 1
    done
    echo "ERROR: ${label} never became ready (${timeout_s}s timeout). Last log lines:" >&2
    tail -20 "${logfile}" 2>/dev/null || true
    return 1
}

#=============================================================================
# Remote stop
#   dist_stop_remote HOST BINARY_NAME [TIMEOUT_S]
#
#   Sends SIGTERM to all processes matching BINARY_NAME on HOST.
#   Waits up to TIMEOUT_S seconds, then escalates to SIGKILL.
#   Also kills the local SSH PID if provided via LOCAL_SSH_PID.
#=============================================================================
dist_stop_remote() {
    local host="$1"
    local binary="$2"
    local timeout_s="${3:-10}"
    local local_ssh_pid="${4:-}"

    # Kill remote process
    dist_ssh "${host}" "pkill -TERM -f '${binary}' 2>/dev/null || true"

    # Wait for it to die on the remote side
    local i
    for i in $(seq 1 "${timeout_s}"); do
        if ! dist_ssh "${host}" "pgrep -f '${binary}' >/dev/null 2>&1"; then
            break
        fi
        sleep 1
    done

    # Escalate if still running
    dist_ssh "${host}" "pkill -KILL -f '${binary}' 2>/dev/null || true"

    # Kill the local SSH forwarding process
    if [[ -n "${local_ssh_pid}" ]] && kill -0 "${local_ssh_pid}" 2>/dev/null; then
        kill -TERM "${local_ssh_pid}" 2>/dev/null || true
        wait "${local_ssh_pid}" 2>/dev/null || true
    fi
}

#=============================================================================
# Remote PID lookup
#   dist_remote_pid HOST BINARY_NAME
#   Echoes the (first) PID of BINARY_NAME on HOST, or empty string.
#=============================================================================
dist_remote_pid() {
    local host="$1"
    local binary="$2"
    dist_ssh "${host}" "pgrep -f '${binary}' | head -1" 2>/dev/null || true
}

#=============================================================================
# Remote run directory creation
#   dist_make_remote_dir HOST
#   Creates a timestamped subdirectory under REMOTE_RUN_DIR_BASE on HOST.
#   Echoes the full path of the created directory.
#=============================================================================
dist_make_remote_dir() {
    local host="$1"
    local remote_dir="${REMOTE_RUN_DIR_BASE}/${DIST_RUN_ID}"
    dist_ssh "${host}" "mkdir -p '${remote_dir}'" >/dev/null
    echo "${remote_dir}"
}

#=============================================================================
# SCP to remote
#   dist_scp_to LOCAL_FILE HOST REMOTE_PATH
#=============================================================================
dist_scp_to() {
    local local_file="$1"
    local host="$2"
    local remote_path="$3"

    local scp_args=()
    [[ -n "${SSH_KEY:-}" ]] && scp_args+=(-i "${SSH_KEY}")
    # Convert SSH opts to SCP-compatible form (drop unsupported flags)
    scp_args+=(-o "BatchMode=yes" -o "ConnectTimeout=10" -o "StrictHostKeyChecking=accept-new")

    scp "${scp_args[@]}" "${local_file}" "${host}:${remote_path}"
}

#=============================================================================
# Config generation
#   dist_generate_config
#
#   Applies envsubst to config/distributed.yaml.template using all variables
#   from distributed_env.sh plus mode-derived variables.
#   Writes to LOCAL_RUN_DIR/proxy_config.yaml and echoes the path.
#=============================================================================
dist_generate_config() {
    local out="${LOCAL_RUN_DIR}/proxy_config.yaml"

    # Set mode-derived variables
    if [[ "${PIPELINE_MODE}" == "lb" ]]; then
        USE_CP="true"
        WITH_LB_HEADER="false"
    else
        USE_CP="false"
        WITH_LB_HEADER="true"
    fi

    # DATA_IP for the config is the proxy's data-plane IP
    local DATA_IP="${PROXY_DATA_IP}"

    # Export all envsubst variables
    export EJFAT_URI USE_CP WITH_LB_HEADER DATA_IP DATA_PORT SLURM_JOB_ID ZMQ_PORT
    export RECV_THREADS RCV_BUF_SIZE VALIDATE_CERT USE_IPV6
    export ZMQ_HWM ZMQ_IO_THREADS POLL_SLEEP ZMQ_SNDBUF LINGER_MS
    export BP_PERIOD READY_THRESHOLD BP_LOG_INTERVAL
    export PID_SETPOINT PID_KP PID_KI PID_KD
    export BUFFER_SIZE RECV_TIMEOUT LOG_VERBOSITY PROGRESS_INTERVAL

    if ! command -v envsubst >/dev/null 2>&1; then
        echo "ERROR: envsubst not found. Install with: brew install gettext" >&2
        return 1
    fi

    envsubst < "${DIST_CONFIG_TEMPLATE}" > "${out}"
    echo "${out}"
}

#=============================================================================
# B2B URI construction
#   dist_construct_b2b_uri
#   Builds and echoes a dummy EJFAT URI for back-to-back mode.
#   No load balancer is involved; the data= parameter points directly at
#   the proxy's UDP reassembler port.
#=============================================================================
dist_construct_b2b_uri() {
    echo "ejfat://b2b-dist@${PROXY_DATA_IP}:9876/lb/1?data=${PROXY_DATA_IP}:${DATA_PORT}&sync=${PROXY_DATA_IP}:19523"
}

#=============================================================================
# Sender IP resolution
#   dist_resolve_sender_ip
#   If SENDER_IP is empty, fetches the first IP from the sender host and
#   assigns it to SENDER_IP. Exports the result.
#=============================================================================
dist_resolve_sender_ip() {
    if [[ -z "${SENDER_IP:-}" ]]; then
        echo "Resolving sender IP from ${SENDER_HOST}..."
        SENDER_IP="$(dist_ssh "${SENDER_HOST}" "hostname -I | awk '{print \$1}'")"
        if [[ -z "${SENDER_IP}" ]]; then
            echo "ERROR: Could not resolve sender IP from ${SENDER_HOST}" >&2
            return 1
        fi
        echo "  Sender IP: ${SENDER_IP}"
    fi
    export SENDER_IP
}

#=============================================================================
# Pre-flight validation
#   dist_preflight [--skip-hosts HOST1,HOST2,...]
#
#   Verifies:
#   1. Required env variables are set
#   2. SSH connectivity to all 4 hosts
#   3. Remote binary exists and is executable on each host
#   4. Config template exists locally
#   5. envsubst is available locally
#=============================================================================
dist_preflight() {
    local skip_hosts="${1:-}"
    local ok=true

    echo "=== Pre-flight checks ==="

    # Required variables
    for var in PROXY_HOST BRIDGE_HOST SENDER_HOST VALIDATOR_HOST PROXY_DATA_IP; do
        if [[ -z "${!var:-}" ]]; then
            echo "  ERROR: ${var} is not set" >&2
            ok=false
        fi
    done

    if [[ "${PIPELINE_MODE}" == "lb" && -z "${EJFAT_URI:-}" ]]; then
        echo "  ERROR: EJFAT_URI is required for PIPELINE_MODE=lb" >&2
        ok=false
    fi

    [[ -f "${DIST_CONFIG_TEMPLATE}" ]] \
        || { echo "  ERROR: Config template not found: ${DIST_CONFIG_TEMPLATE}" >&2; ok=false; }

    command -v envsubst >/dev/null 2>&1 \
        || { echo "  ERROR: envsubst not found (brew install gettext)" >&2; ok=false; }

    command -v scp >/dev/null 2>&1 \
        || { echo "  ERROR: scp not found" >&2; ok=false; }

    [[ "$ok" == "false" ]] && { echo "Pre-flight FAILED (config errors)"; return 1; }

    # SSH connectivity and binary checks
    local hosts_and_bins=(
        "${PROXY_HOST}:${REMOTE_PROXY_BIN}"
        "${BRIDGE_HOST}:${REMOTE_BRIDGE_BIN}"
        "${SENDER_HOST}:${REMOTE_SENDER_BIN}"
        "${VALIDATOR_HOST}:${REMOTE_VALIDATOR_BIN}"
    )

    for entry in "${hosts_and_bins[@]}"; do
        local host="${entry%%:*}"
        local bin="${entry#*:}"

        # Skip if in skip list
        if [[ ",${skip_hosts}," == *",${host},"* ]]; then
            echo "  SKIP ${host} (skipped)"
            continue
        fi

        printf "  %-40s" "${host}..."
        if ! dist_ssh "${host}" "test -x '${bin}'" 2>/dev/null; then
            echo "FAIL (SSH error or binary not found: ${bin})"
            ok=false
        else
            echo "OK"
        fi
    done

    if [[ "$ok" == "false" ]]; then
        echo "Pre-flight FAILED"
        return 1
    fi
    echo "Pre-flight PASSED"
    echo ""
}

#=============================================================================
# Log collection
#   dist_collect_logs HOST REMOTE_DIR
#   Pulls all *.log files from REMOTE_DIR on HOST to LOCAL_RUN_DIR.
#=============================================================================
dist_collect_logs() {
    local host="$1"
    local remote_dir="$2"
    local component="${3:-$(echo "$host" | tr '@.' '_')}"

    local scp_args=()
    [[ -n "${SSH_KEY:-}" ]] && scp_args+=(-i "${SSH_KEY}")
    scp_args+=(-o "BatchMode=yes" -o "ConnectTimeout=10" -o "StrictHostKeyChecking=accept-new")

    # Silently skip if remote dir is empty or unavailable
    scp "${scp_args[@]}" -r "${host}:${remote_dir}/" "${LOCAL_RUN_DIR}/${component}_remote/" \
        >/dev/null 2>&1 || true
}

#=============================================================================
# Summary printer
#   dist_print_log_tail LOGFILE LABEL [LINES]
#=============================================================================
dist_print_log_tail() {
    local logfile="$1"
    local label="$2"
    local lines="${3:-15}"

    echo ""
    echo "--- ${label} (last ${lines} lines) ---"
    if [[ -f "${logfile}" ]]; then
        tail -"${lines}" "${logfile}"
    else
        echo "  (no log file: ${logfile})"
    fi
}
