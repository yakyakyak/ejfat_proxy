#!/bin/bash
# proxy_coordinator.sh - Runs proxy containers sequentially within a SINGLE srun step
#
# On Cray/Perlmutter, each srun step gets its own mount namespace. When a step ends,
# the namespace teardown corrupts podman's overlay storage state (fuse-overlayfs
# mounts become stale). This coordinator keeps one srun step alive for the entire
# suite and restarts proxy containers within it, avoiding inter-step namespace issues.
#
# Protocol (file-based IPC via $JOB_DIR):
#   Suite writes: proxy_go_N    (content: BUFFER_SIZE value) → coordinator starts proxy N
#   Suite writes: proxy_stop_N  (any content)               → coordinator stops proxy N
#   Coordinator writes: proxy_ready_N                       → proxy is running and registered
#   Coordinator writes: proxy_done_N                        → proxy fully stopped
#
# Usage:
#   srun ... bash -c "proxy_coordinator.sh JOB_DIR SCRIPT_DIR NUM_TESTS"

set -uo pipefail

JOB_DIR="$1"
SCRIPT_DIR="$2"
NUM_TESTS="${3:-5}"

echo "Coordinator: started on $(hostname), managing $NUM_TESTS tests"
echo "Coordinator: job dir = $JOB_DIR"

for test_num in $(seq 1 "$NUM_TESTS"); do
    echo "Coordinator: waiting for proxy_go_${test_num}..."

    # Wait for go signal
    while [[ ! -f "$JOB_DIR/proxy_go_${test_num}" ]]; do
        sleep 0.5
    done

    # proxy_go_N contains shell var assignments: BUFFER_SIZE=50 ZMQ_HWM=5 ...
    eval "$(cat "$JOB_DIR/proxy_go_${test_num}")"
    echo "Coordinator: starting test $test_num (BUFFER_SIZE=${BUFFER_SIZE:-?} ZMQ_HWM=${ZMQ_HWM:-default})"

    # Remove any old ready/done flags from previous test
    rm -f "$JOB_DIR/proxy_ready_${test_num}" "$JOB_DIR/proxy_done_${test_num}"

    # Run proxy in background within THIS srun step
    (
        cd "$JOB_DIR"
        export BUFFER_SIZE ZMQ_HWM
        "$SCRIPT_DIR/run_proxy.sh"
    ) > "$JOB_DIR/proxy_wrapper.log" 2>&1 &

    PROXY_PID=$!
    echo "Coordinator: proxy PID=$PROXY_PID"

    # Wait for proxy to register with LB (check proxy.log for registration line)
    WAIT_MAX=30
    for i in $(seq 1 $WAIT_MAX); do
        if grep -q "Worker registered" "$JOB_DIR/proxy.log" 2>/dev/null; then
            echo "Coordinator: proxy registered at i=$i"
            break
        fi
        if ! kill -0 "$PROXY_PID" 2>/dev/null; then
            echo "Coordinator: proxy died during startup for test $test_num"
            break
        fi
        sleep 1
    done

    # Signal that proxy is ready (or died)
    echo "$PROXY_PID" > "$JOB_DIR/proxy_ready_${test_num}"

    # Wait for stop signal from suite
    echo "Coordinator: waiting for proxy_stop_${test_num}..."
    while [[ ! -f "$JOB_DIR/proxy_stop_${test_num}" ]]; do
        if ! kill -0 "$PROXY_PID" 2>/dev/null; then
            echo "Coordinator: proxy died on its own for test $test_num"
            break
        fi
        sleep 1
    done

    # Stop proxy gracefully
    echo "Coordinator: stopping proxy for test $test_num..."
    kill -TERM "$PROXY_PID" 2>/dev/null || true
    # Wait up to 20s for clean exit
    for i in $(seq 1 20); do
        kill -0 "$PROXY_PID" 2>/dev/null || break
        sleep 1
    done
    kill -9 "$PROXY_PID" 2>/dev/null || true
    wait "$PROXY_PID" 2>/dev/null || true

    echo "Coordinator: proxy stopped for test $test_num"
    # Signal done
    echo "done" > "$JOB_DIR/proxy_done_${test_num}"

    # Archive proxy logs for this test
    local_prefix="test${test_num}"
    [[ -f "$JOB_DIR/proxy.log" ]] && cp "$JOB_DIR/proxy.log" "$JOB_DIR/${local_prefix}_proxy.log"
    [[ -f "$JOB_DIR/proxy_wrapper.log" ]] && cp "$JOB_DIR/proxy_wrapper.log" "$JOB_DIR/${local_prefix}_proxy_wrapper.log"
done

echo "Coordinator: all $NUM_TESTS tests complete"
