#!/bin/bash
#SBATCH -N 3
#SBATCH -C cpu
#SBATCH -q debug
#SBATCH -t 00:30:00
#SBATCH -J ejfat_bp_suite
#
# EJFAT ZMQ Proxy Backpressure Test Suite
#
# Runs 5 targeted backpressure scenarios sequentially in a single SLURM job,
# sharing one LB reservation. Each test has pass/fail assertions.
#
# Tests:
#   1. Baseline       — no backpressure (fast consumer)
#   2. Mild BP        — 10ms delay, small buffer → activates and recovers
#   3. Heavy BP       — 100ms delay, small buffer → sustained saturation
#   4. Small-event    — 50ms delay, small buffer, 64KB events
#   5. 10-min soak    — 20ms delay, moderate buffer, looping sender
#
# Usage:
#   export EJFAT_URI="ejfats://token@lb.es.net:443/lb/xyz?..."
#   export E2SAR_SCRIPTS_DIR="/path/to/ejfat_proxy/scripts/perlmutter"
#   sbatch -A <account> perlmutter_backpressure_suite.sh

set -uo pipefail

#=============================================================================
# Environment setup
#=============================================================================

echo "========================================="
echo "EJFAT Backpressure Suite - Job $SLURM_JOB_ID"
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

# Parse nodes
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

#=============================================================================
# Global state
#=============================================================================

COORDINATOR_PID=""
CONSUMER_PID=""
CURRENT_TEST=0
SUITE_PASS=0
SUITE_FAIL=0
declare -a TEST_RESULTS=()

#=============================================================================
# Cleanup
#=============================================================================

CLEANUP_DONE=false

cleanup() {
    [[ "$CLEANUP_DONE" == "true" ]] && return
    CLEANUP_DONE=true

    echo ""
    echo "--- Cleanup ---"
    # Stop current test if running
    if [[ "$CURRENT_TEST" -gt 0 ]]; then
        touch "$JOB_DIR/proxy_stop_${CURRENT_TEST}" 2>/dev/null || true
    fi
    if [[ -n "$CONSUMER_PID" ]]; then
        kill -TERM "$CONSUMER_PID" 2>/dev/null || true
        sleep 2
        kill -9 "$CONSUMER_PID" 2>/dev/null || true
    fi
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

trap cleanup EXIT INT TERM

#=============================================================================
# Helpers
#=============================================================================

start_coordinator() {
    echo "Starting proxy coordinator (single srun step) on $NODE_PROXY..."
    srun --nodes=1 --ntasks=1 --nodelist="$NODE_PROXY" \
        bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/proxy_coordinator.sh' '$JOB_DIR' '$SCRIPT_DIR' 5" \
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
    echo "Waiting for coordinator to signal proxy_ready_${test_num}..."
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
    local delay="$1"
    echo "Starting consumer (delay=${delay}ms) on $NODE_CONSUMER..."
    srun --nodes=1 --ntasks=1 --nodelist="$NODE_CONSUMER" \
        bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/run_consumer.sh' --delay '$delay'" \
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

archive_logs() {
    local prefix="$1"
    # proxy logs are already archived by coordinator; copy consumer/sender logs
    for f in consumer.log minimal_sender.log consumer_wrapper.log; do
        [[ -f "$f" ]] && mv "$f" "${prefix}_${f}" || true
    done
    # proxy logs copied by coordinator
    [[ -f "${prefix}_proxy.log" ]] || \
        { [[ -f "proxy.log" ]] && cp "proxy.log" "${prefix}_proxy.log"; } || true
    echo "Logs archived as ${prefix}_*"
}

#=============================================================================
# Assertion helpers
#=============================================================================

PASS_COUNT=0
FAIL_COUNT=0

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
    # ready=1 must appear after a ready=0 line
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
    # Check that ready=0 appears at least N times consecutively
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

record_test_result() {
    local name="$1"
    local prev_fail="$2"
    local cur_fail=$FAIL_COUNT
    local new_fails=$(( cur_fail - prev_fail ))
    if [[ "$new_fails" -eq 0 ]]; then
        TEST_RESULTS+=("PASS  $name")
        SUITE_PASS=$(( SUITE_PASS + 1 ))
    else
        TEST_RESULTS+=("FAIL  $name ($new_fails assertion(s) failed)")
        SUITE_FAIL=$(( SUITE_FAIL + 1 ))
    fi
}

#=============================================================================
# Phase 0: Reserve Load Balancer
#=============================================================================

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

#=============================================================================
# Start proxy coordinator (ONE srun step for all proxy tests)
#=============================================================================

echo "Starting proxy coordinator..."
start_coordinator

#=============================================================================
# TEST 1: Baseline — no backpressure (fast consumer, large buffer)
#=============================================================================

echo "========================================="
echo "TEST 1: Baseline (no backpressure)"
echo "========================================="

FAIL_BEFORE=$FAIL_COUNT
start_proxy 1 "BUFFER_SIZE=20000 ZMQ_HWM=10000"
start_consumer 0
wait_for_proxy_ready 1

srun --nodes=1 --ntasks=1 --nodelist="$NODE_SENDER" \
    bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/minimal_sender.sh'" || true

echo "Waiting 10s for drain..."
sleep 10

stop_proxy 1
stop_consumer

echo "Assertions:"
assert_no_backpressure test1_proxy.log
assert_fill_stayed_low 10 test1_proxy.log
assert_events_received 90 100
assert_no_crash test1_proxy.log

archive_logs test1
record_test_result "Baseline (no backpressure)" $FAIL_BEFORE
echo ""

#=============================================================================
# TEST 2: Mild backpressure — activates and recovers
#=============================================================================

echo "========================================="
echo "TEST 2: Mild backpressure (10ms delay, buf=50)"
echo "========================================="

FAIL_BEFORE=$FAIL_COUNT
start_proxy 2 "BUFFER_SIZE=50 ZMQ_HWM=5"
start_consumer 10
wait_for_proxy_ready 2

srun --nodes=1 --ntasks=1 --nodelist="$NODE_SENDER" \
    bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/minimal_sender.sh'" || true

echo "Waiting 15s for drain..."
sleep 15

stop_proxy 2
stop_consumer

echo "Assertions:"
assert_backpressure_triggered test2_proxy.log
assert_backpressure_recovered test2_proxy.log
assert_fill_peaked 20 test2_proxy.log
assert_events_received 70
assert_no_crash test2_proxy.log

archive_logs test2
record_test_result "Mild backpressure" $FAIL_BEFORE
echo ""

#=============================================================================
# TEST 3: Heavy backpressure — sustained saturation
#=============================================================================

echo "========================================="
echo "TEST 3: Heavy backpressure (100ms delay, buf=50)"
echo "========================================="

FAIL_BEFORE=$FAIL_COUNT
start_proxy 3 "BUFFER_SIZE=50 ZMQ_HWM=5"
start_consumer 100
wait_for_proxy_ready 3

srun --nodes=1 --ntasks=1 --nodelist="$NODE_SENDER" \
    bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/minimal_sender.sh'" || true

echo "Waiting 20s for drain..."
sleep 20

stop_proxy 3
stop_consumer

echo "Assertions:"
assert_backpressure_triggered test3_proxy.log
assert_sustained_bp 3 test3_proxy.log
assert_fill_peaked 80 test3_proxy.log
assert_control_peaked 0.5 test3_proxy.log
assert_no_crash test3_proxy.log

archive_logs test3
record_test_result "Heavy backpressure" $FAIL_BEFORE
echo ""

#=============================================================================
# TEST 4: Small-event stress (64KB events, 50ms delay, buf=50)
#=============================================================================

echo "========================================="
echo "TEST 4: Small-event stress (64KB, 50ms delay, buf=50)"
echo "========================================="

FAIL_BEFORE=$FAIL_COUNT
start_proxy 4 "BUFFER_SIZE=50 ZMQ_HWM=5"
start_consumer 50
wait_for_proxy_ready 4

srun --nodes=1 --ntasks=1 --nodelist="$NODE_SENDER" \
    bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/minimal_sender.sh' --length 65536" || true

echo "Waiting 15s for drain..."
sleep 15

stop_proxy 4
stop_consumer

echo "Assertions:"
assert_backpressure_triggered test4_proxy.log
assert_fill_peaked 20 test4_proxy.log
assert_no_crash test4_proxy.log

archive_logs test4
record_test_result "Small-event stress" $FAIL_BEFORE
echo ""

#=============================================================================
# TEST 5: 5-minute soak (20ms delay, buf=200, looping sender)
#=============================================================================

echo "========================================="
echo "TEST 5: 5-minute soak (20ms delay, buf=200)"
echo "========================================="

FAIL_BEFORE=$FAIL_COUNT
start_proxy 5 "BUFFER_SIZE=200 ZMQ_HWM=10"
start_consumer 20
wait_for_proxy_ready 5

srun --nodes=1 --ntasks=1 --nodelist="$NODE_SENDER" \
    bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/run_soak_sender.sh' --duration 300" || true

echo "Waiting 15s for drain..."
sleep 15

# Check coordinator still alive (= proxy was alive throughout)
PROXY_ALIVE=false
kill -0 "$COORDINATOR_PID" 2>/dev/null && PROXY_ALIVE=true

stop_proxy 5
stop_consumer

echo "Assertions:"
assert_backpressure_triggered test5_proxy.log
assert_backpressure_recovered test5_proxy.log
assert_no_crash test5_proxy.log

if [[ "$PROXY_ALIVE" == "true" ]]; then
    assert_pass "coordinator-alive-at-end"
else
    assert_fail "coordinator-alive-at-end" "coordinator not running at drain time"
fi

archive_logs test5
record_test_result "5-minute soak" $FAIL_BEFORE
echo ""

# Stop coordinator
if [[ -n "$COORDINATOR_PID" ]]; then
    kill -TERM "$COORDINATOR_PID" 2>/dev/null || true
    wait "$COORDINATOR_PID" 2>/dev/null || true
fi

#=============================================================================
# Suite summary
#=============================================================================

echo "========================================="
echo "Backpressure Suite Results"
echo "========================================="
echo ""
for result in "${TEST_RESULTS[@]}"; do
    echo "  $result"
done
echo ""
echo "Tests passed: $SUITE_PASS"
echo "Tests failed: $SUITE_FAIL"
echo ""
echo "Total assertions: pass=$((FAIL_COUNT == 0 ? PASS_COUNT : PASS_COUNT)) fail=$FAIL_COUNT"
echo ""
echo "End time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Logs saved to: $JOB_DIR"
echo ""

if [[ "$SUITE_FAIL" -gt 0 ]]; then
    echo "SUITE: FAILED"
    exit 1
else
    echo "SUITE: PASSED"
    exit 0
fi
