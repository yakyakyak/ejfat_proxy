#!/bin/bash
# local_common.sh — Shared helpers for macOS local test scripts
#
# Source this after PROJECT_ROOT, PROXY_BIN, RUN_DIR, and TEMPLATE are set,
# and after all config template variables (DATA_IP, ZMQ_PORT, etc.) are set.
#
# Provides:
#   generate_proxy_config OUTPUT_PATH  — run envsubst on TEMPLATE
#   start_local_proxy CONFIG           — launch proxy in background, set PROXY_PID
#   wait_proxy_ready                   — poll proxy log for "All components started"
#   stop_local_proxy                   — SIGTERM -> wait -> SIGKILL proxy + sleep 2

generate_proxy_config() {
    local out="$1"
    export EJFAT_URI DATA_IP DATA_PORT SLURM_JOB_ID ZMQ_PORT
    export RECV_THREADS RCV_BUF_SIZE VALIDATE_CERT USE_CP WITH_LB_HEADER
    export ZMQ_HWM ZMQ_IO_THREADS POLL_SLEEP ZMQ_SNDBUF
    export BP_PERIOD READY_THRESHOLD BP_LOG_INTERVAL LINGER_MS
    export PID_SETPOINT PID_KP PID_KI PID_KD
    export BUFFER_SIZE RECV_TIMEOUT LOG_VERBOSITY PROGRESS_INTERVAL
    envsubst < "$TEMPLATE" > "$out"
    echo "$out"
}

start_local_proxy() {
    local config="$1"
    local log="$RUN_DIR/proxy.log"
    : > "$log"
    "$PROXY_BIN" -c "$config" >> "$log" 2>&1 &
    PROXY_PID=$!
    echo "Proxy started (PID=$PROXY_PID), logging to $log"
}

wait_proxy_ready() {
    local log="$RUN_DIR/proxy.log"
    local i
    for i in $(seq 1 30); do
        if grep -q "All components started" "$log" 2>/dev/null; then
            echo "Proxy ready (after ${i}s)"
            return 0
        fi
        if ! kill -0 "$PROXY_PID" 2>/dev/null; then
            echo "ERROR: Proxy died during startup. Last lines:"
            tail -20 "$log" || true
            return 1
        fi
        sleep 1
    done
    echo "ERROR: Proxy never became ready (30s timeout). Last lines:"
    tail -20 "$log" || true
    return 1
}

stop_local_proxy() {
    if [[ -n "$PROXY_PID" ]]; then
        kill -TERM "$PROXY_PID" 2>/dev/null || true
        local i
        for i in $(seq 1 10); do
            kill -0 "$PROXY_PID" 2>/dev/null || break
            sleep 1
        done
        kill -9 "$PROXY_PID" 2>/dev/null || true
        wait "$PROXY_PID" 2>/dev/null || true
        PROXY_PID=""
        echo "Proxy stopped"
    fi
    sleep 2  # brief pause for port release before next test
}
