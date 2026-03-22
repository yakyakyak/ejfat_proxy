#!/bin/bash
# bp_common.sh — shared functions for individual backpressure test scripts.
# Source this file after setting SCRIPT_DIR; then call bp_setup_env.

bp_setup_env() {
    echo "========================================="
    echo "EJFAT Backpressure Test - Job $SLURM_JOB_ID"
    echo "========================================="
    echo "Start time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo ""

    if [[ -z "${EJFAT_URI:-}" ]]; then
        echo "ERROR: EJFAT_URI is required"
        exit 1
    fi

    if [[ -z "${E2SAR_SCRIPTS_DIR:-}" ]]; then
        echo "ERROR: E2SAR_SCRIPTS_DIR must be set to scripts/perlmutter directory"
        exit 1
    fi

    SCRIPT_DIR="$E2SAR_SCRIPTS_DIR"
    RUNS_DIR="${SLURM_SUBMIT_DIR}/runs"
    JOB_DIR="${RUNS_DIR}/slurm_job_${SLURM_JOB_ID}"
    mkdir -p "$JOB_DIR"
    cd "$JOB_DIR"

    echo "Job dir: $JOB_DIR"

    NODE_ARRAY=($(scontrol show hostname "$SLURM_JOB_NODELIST"))
    if [[ ${#NODE_ARRAY[@]} -lt 3 ]]; then
        echo "ERROR: Need 3 nodes, got ${#NODE_ARRAY[@]}"
        exit 1
    fi

    NODE_PROXY="${NODE_ARRAY[0]}"
    NODE_CONSUMER="${NODE_ARRAY[1]}"
    NODE_SENDER="${NODE_ARRAY[2]}"

    echo "Nodes: proxy=$NODE_PROXY consumer=$NODE_CONSUMER sender=$NODE_SENDER"
    echo ""

    ZMQ_PORT="${ZMQ_PORT:-5555}"
    export ZMQ_PORT
    export PROXY_NODE="$NODE_PROXY"

    COORDINATOR_PID=""
    CONSUMER_PID=""
    CURRENT_TEST=0
    PASS_COUNT=0
    FAIL_COUNT=0

    CLEANUP_DONE=false

    trap _bp_cleanup EXIT INT TERM
}

_bp_cleanup() {
    [[ "$CLEANUP_DONE" == "true" ]] && return
    CLEANUP_DONE=true

    echo ""
    echo "--- Cleanup ---"
    if [[ "$CURRENT_TEST" -gt 0 ]]; then
        touch "$JOB_DIR/proxy_stop_${CURRENT_TEST}" 2>/dev/null || true
    fi
    if [[ -n "$CONSUMER_PID" ]]; then
        kill -TERM "$CONSUMER_PID" 2>/dev/null || true
        sleep 2
        kill -9 "$CONSUMER_PID" 2>/dev/null || true
    fi
    for _pid in "${CONSUMER_PIDS[@]:-}"; do
        [[ -n "$_pid" ]] && kill -TERM "$_pid" 2>/dev/null || true
    done
    sleep 2
    for _pid in "${CONSUMER_PIDS[@]:-}"; do
        [[ -n "$_pid" ]] && kill -9 "$_pid" 2>/dev/null || true
    done
    if [[ -n "$COORDINATOR_PID" ]]; then
        kill -TERM "$COORDINATOR_PID" 2>/dev/null || true
        sleep 5
        kill -9 "$COORDINATOR_PID" 2>/dev/null || true
    fi

    if [[ -f "$JOB_DIR/INSTANCE_URI" ]]; then
        cd "$JOB_DIR"
        "$SCRIPT_DIR/minimal_free.sh" 2>/dev/null || echo "WARNING: Failed to free LB"
    fi
}

bp_reserve_lb() {
    echo "========================================="
    echo "Phase 0: Reserve Load Balancer"
    echo "========================================="

    export EJFAT_URI

    if ! "$SCRIPT_DIR/minimal_reserve.sh"; then
        echo "ERROR: Failed to reserve load balancer"
        exit 1
    fi

    if [[ ! -f "INSTANCE_URI" ]]; then
        echo "ERROR: INSTANCE_URI not found after reservation"
        exit 1
    fi

    echo "Reservation ready"
    echo ""
}

start_coordinator() {
    echo "Starting proxy coordinator on $NODE_PROXY..."
    srun --nodes=1 --ntasks=1 --nodelist="$NODE_PROXY" \
        bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/proxy_coordinator.sh' '$JOB_DIR' '$SCRIPT_DIR' 1" \
        > coordinator.log 2>&1 &
    COORDINATOR_PID=$!
    echo "Coordinator PID: $COORDINATOR_PID"
    sleep 2
    if ! kill -0 "$COORDINATOR_PID" 2>/dev/null; then
        echo "ERROR: Coordinator failed to start"
        cat coordinator.log || true
        return 1
    fi
}

start_proxy() {
    # Usage: start_proxy TEST_NUM "BUFFER_SIZE=N [ZMQ_HWM=M ...]"
    local test_num="$1"
    local config="$2"
    CURRENT_TEST="$test_num"
    echo "Signaling coordinator: start test $test_num ($config)..."
    rm -f "proxy_go_${test_num}" "proxy_ready_${test_num}" "proxy_done_${test_num}" \
          "proxy_stop_${test_num}" proxy.log proxy_wrapper.log
    echo "$config" > "proxy_go_${test_num}"
}

wait_for_proxy_ready() {
    local test_num="$1"
    echo "Waiting for proxy_ready_${test_num}..."
    local i
    for i in $(seq 1 60); do
        [[ -f "proxy_ready_${test_num}" ]] && break
        if ! kill -0 "$COORDINATOR_PID" 2>/dev/null; then
            echo "ERROR: Coordinator died"
            return 1
        fi
        sleep 1
    done
    if [[ ! -f "proxy_ready_${test_num}" ]]; then
        echo "ERROR: Proxy never became ready for test $test_num"
        return 1
    fi
    echo "Proxy ready for test $test_num"
}

stop_proxy() {
    local test_num="$1"
    echo "Signaling coordinator: stop test $test_num..."
    touch "proxy_stop_${test_num}"
    local i
    for i in $(seq 1 30); do
        [[ -f "proxy_done_${test_num}" ]] && break
        sleep 1
    done
    [[ -f "proxy_done_${test_num}" ]] && echo "Proxy stopped for test $test_num" \
        || echo "WARNING: proxy_done_${test_num} not received"
}

start_consumer() {
    # Usage: start_consumer DELAY_MS [RCVHWM [RCVBUF_BYTES]]
    local delay="$1"
    local rcvhwm="${2:-1000}"
    local rcvbuf="${3:-0}"
    local extra_args=""
    if [[ "$rcvhwm" -lt 1000 ]]; then
        extra_args="$extra_args --rcvhwm '$rcvhwm'"
    fi
    if [[ "$rcvbuf" -gt 0 ]]; then
        extra_args="$extra_args --rcvbuf '$rcvbuf'"
    fi
    echo "Starting consumer (delay=${delay}ms, rcvhwm=${rcvhwm}, rcvbuf=${rcvbuf}) on $NODE_CONSUMER..."
    srun --nodes=1 --ntasks=1 --nodelist="$NODE_CONSUMER" \
        bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/run_consumer.sh' --delay '$delay' $extra_args" \
        > consumer_wrapper.log 2>&1 &
    CONSUMER_PID=$!
    echo "Consumer PID: $CONSUMER_PID"
}

stop_consumer() {
    if [[ -n "$CONSUMER_PID" ]]; then
        kill -TERM "$CONSUMER_PID" 2>/dev/null || true
        sleep 3
        kill -9 "$CONSUMER_PID" 2>/dev/null || true
        wait "$CONSUMER_PID" 2>/dev/null || true
        CONSUMER_PID=""
    fi
}

# Named consumer support for multi-consumer tests.
# Uses an associative array to track PIDs by name.
declare -A CONSUMER_PIDS

start_named_consumer() {
    # Usage: start_named_consumer NAME NODE DELAY_MS [RCVHWM [RCVBUF_BYTES]]
    local name="$1"
    local node="$2"
    local delay="$3"
    local rcvhwm="${4:-1000}"
    local rcvbuf="${5:-0}"
    local extra_args=""
    if [[ "$rcvhwm" -lt 1000 ]]; then
        extra_args="$extra_args --rcvhwm '$rcvhwm'"
    fi
    if [[ "$rcvbuf" -gt 0 ]]; then
        extra_args="$extra_args --rcvbuf '$rcvbuf'"
    fi
    echo "Starting consumer '$name' (delay=${delay}ms, rcvhwm=${rcvhwm}, rcvbuf=${rcvbuf}) on $node..."
    srun --overlap --nodes=1 --ntasks=1 --nodelist="$node" \
        bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/run_consumer.sh' --delay '$delay' --log-name '$name' $extra_args" \
        > "${name}_wrapper.log" 2>&1 &
    CONSUMER_PIDS["$name"]=$!
    echo "Consumer '$name' PID: ${CONSUMER_PIDS[$name]}"
}

stop_named_consumer() {
    local name="$1"
    local pid="${CONSUMER_PIDS[$name]:-}"
    if [[ -n "$pid" ]]; then
        kill -TERM "$pid" 2>/dev/null || true
        sleep 3
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        unset "CONSUMER_PIDS[$name]"
    fi
}

stop_all_named_consumers() {
    for name in "${!CONSUMER_PIDS[@]}"; do
        stop_named_consumer "$name"
    done
}

get_consumer_event_count() {
    # Parse the final "Messages: N,NNN" line from a consumer log file.
    local logfile="$1"
    grep "Messages:" "$logfile" 2>/dev/null | tail -1 \
        | grep -oP 'Messages: \K[0-9,]+' | tr -d ','
}

archive_logs() {
    local prefix="$1"
    for f in consumer.log minimal_sender.log consumer_wrapper.log; do
        [[ -f "$f" ]] && mv "$f" "${prefix}_${f}" || true
    done
    [[ -f "${prefix}_proxy.log" ]] || \
        { [[ -f "proxy.log" ]] && cp "proxy.log" "${prefix}_proxy.log"; } || true
    echo "Logs archived as ${prefix}_*"
}

#=============================================================================
# Assertion helpers
#=============================================================================

assert_pass() {
    local name="$1"
    echo "  PASS: $name"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
}

assert_fail() {
    local name="$1"
    local detail="${2:-}"
    echo "  FAIL: $name${detail:+ ($detail)}"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
}

assert_no_backpressure() {
    local logfile="${1:-proxy.log}"
    if grep -q "ready=0" "$logfile" 2>/dev/null; then
        assert_fail "no-backpressure" "ready=0 was found"
    else
        assert_pass "no-backpressure"
    fi
}

assert_backpressure_triggered() {
    local logfile="${1:-proxy.log}"
    if grep -q "ready=0" "$logfile" 2>/dev/null; then
        assert_pass "backpressure-triggered"
    else
        assert_fail "backpressure-triggered" "ready=0 never seen"
    fi
}

assert_backpressure_recovered() {
    local logfile="${1:-proxy.log}"
    local first_bp_line
    first_bp_line=$(grep -n "ready=0" "$logfile" 2>/dev/null | head -1 | cut -d: -f1)
    if [[ -z "$first_bp_line" ]]; then
        assert_fail "backpressure-recovered" "no ready=0 found"
        return
    fi
    if tail -n "+$((first_bp_line + 1))" "$logfile" 2>/dev/null | grep -q "ready=1"; then
        assert_pass "backpressure-recovered"
    else
        assert_fail "backpressure-recovered" "ready=1 never seen after ready=0"
    fi
}

assert_fill_peaked() {
    local threshold="$1"
    local logfile="${2:-proxy.log}"
    local max_fill
    max_fill=$(grep -oP 'fill=\K[0-9.]+' "$logfile" 2>/dev/null \
        | awk 'BEGIN{m=0} {if($1+0>m)m=$1+0} END{print m}')
    if [[ -z "$max_fill" ]]; then
        assert_fail "fill-peaked-${threshold}" "no fill% data in log"
        return
    fi
    if awk "BEGIN{exit ($max_fill >= $threshold) ? 0 : 1}"; then
        assert_pass "fill-peaked-${threshold} (max=${max_fill}%)"
    else
        assert_fail "fill-peaked-${threshold}" "max fill=${max_fill}% < ${threshold}%"
    fi
}

assert_fill_stayed_low() {
    local threshold="$1"
    local logfile="${2:-proxy.log}"
    local max_fill
    max_fill=$(grep -oP 'fill=\K[0-9.]+' "$logfile" 2>/dev/null \
        | awk 'BEGIN{m=0} {if($1+0>m)m=$1+0} END{print m}')
    if [[ -z "$max_fill" ]]; then
        assert_fail "fill-stayed-low-${threshold}" "no fill% data in log"
        return
    fi
    if awk "BEGIN{exit ($max_fill <= $threshold) ? 0 : 1}"; then
        assert_pass "fill-stayed-low-${threshold} (max=${max_fill}%)"
    else
        assert_fail "fill-stayed-low-${threshold}" "max fill=${max_fill}% > ${threshold}%"
    fi
}

assert_events_received() {
    local min="$1"
    local max="${2:-999999999}"
    local logfile="${3:-consumer.log}"
    local count
    count=$(grep "Messages:" "$logfile" 2>/dev/null | tail -1 \
        | grep -oP 'Messages: \K[0-9,]+' | tr -d ',')
    if [[ -z "$count" ]]; then
        assert_fail "events-received-${min}" "no Messages: line in consumer.log"
        return
    fi
    if [[ "$count" -ge "$min" && "$count" -le "$max" ]]; then
        assert_pass "events-received (count=$count, expected>=${min})"
    else
        assert_fail "events-received" "count=$count not in [$min,$max]"
    fi
}

assert_no_crash() {
    local logfile="${1:-proxy.log}"
    if grep -qiE "segfault|segmentation fault|abort|core dumped" "$logfile" 2>/dev/null; then
        assert_fail "no-crash" "crash signal found in log"
    else
        assert_pass "no-crash"
    fi
}

assert_sustained_bp() {
    local min_count="${1:-3}"
    local logfile="${2:-proxy.log}"
    local max_run
    max_run=$(grep -oP 'ready=\K[01]' "$logfile" 2>/dev/null \
        | awk -v req=0 'BEGIN{cur=0;max=0} \
            {if($1==req){cur++;if(cur>max)max=cur}else{cur=0}} \
            END{print max}')
    if [[ -z "$max_run" ]]; then
        assert_fail "sustained-bp-${min_count}" "no ready= data in log"
        return
    fi
    if [[ "$max_run" -ge "$min_count" ]]; then
        assert_pass "sustained-bp-${min_count} (max_run=${max_run})"
    else
        assert_fail "sustained-bp-${min_count}" "max consecutive ready=0 run=${max_run} < ${min_count}"
    fi
}

assert_control_peaked() {
    local threshold="$1"
    local logfile="${2:-proxy.log}"
    local max_ctrl
    max_ctrl=$(grep -oP 'control=\K[0-9.]+' "$logfile" 2>/dev/null \
        | awk 'BEGIN{m=0} {if($1+0>m)m=$1+0} END{print m}')
    if [[ -z "$max_ctrl" ]]; then
        assert_fail "control-peaked-${threshold}" "no control= data in log"
        return
    fi
    if awk "BEGIN{exit ($max_ctrl > $threshold) ? 0 : 1}"; then
        assert_pass "control-peaked-${threshold} (max=${max_ctrl})"
    else
        assert_fail "control-peaked-${threshold}" "max control=${max_ctrl} <= ${threshold}"
    fi
}

bp_print_summary() {
    local test_name="$1"
    echo ""
    echo "========================================="
    echo "Results: $test_name"
    echo "========================================="
    echo "Assertions: pass=$PASS_COUNT fail=$FAIL_COUNT"
    echo "End time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "Logs saved to: $JOB_DIR"
    echo ""
    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        echo "TEST: FAILED"
        exit 1
    else
        echo "TEST: PASSED"
        exit 0
    fi
}
