#!/bin/bash
#SBATCH -N 3
#SBATCH -C cpu
#SBATCH -q debug
#SBATCH -t 00:25:00
#SBATCH -J ejfat_b2b
#
# Back-to-back backpressure test suite — all 5 BP tests, no load balancer.
#
# Runs the same 5 backpressure scenarios as bp_test1-5.sh but with the
# sender pointing directly at the proxy's E2SAR port instead of through an
# EJFAT load balancer. No EJFAT_URI or LB reservation required.
#
# Node layout:
#   NODE[0] = proxy node  (runs ejfat_zmq_proxy via podman-hpc)
#   NODE[1] = consumer    (runs test_receiver.py ZMQ PULL)
#   NODE[2] = sender      (runs e2sar_perf via podman-hpc)
#
# Usage:
#   export E2SAR_SCRIPTS_DIR="/path/to/ejfat_proxy/scripts/perlmutter"
#   sbatch -A <account> b2b_backpressure_suite.sh
#
# Optional:
#   DATA_PORT=10000    E2SAR reassembler UDP port (default: 10000)
#   ZMQ_PORT=5555      ZMQ PUSH/PULL port (default: 5555)

set -uo pipefail

SCRIPT_DIR="${E2SAR_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=bp_common.sh
source "$SCRIPT_DIR/bp_common.sh"

# Back-to-back mode: no LB reservation, modified assertions
export B2B_MODE=true

# Readiness signal that always appears in proxy log (use_cp=false skips
# "Worker registered", but proxy.cpp always prints "All components started")
export PROXY_READY_PATTERN="All components started"

bp_setup_env

echo "========================================="
echo "B2B Backpressure Suite — 5 tests, no LB"
echo "========================================="
echo ""

# Resolve proxy node's IP address for the sender.
# The sender sends UDP directly to this IP (no LB in the path).
echo "Resolving proxy node IP..."
TARGET_IP=$(srun --nodes=1 --ntasks=1 --nodelist="$NODE_PROXY" hostname -i | awk '{print $1}')
if [[ -z "$TARGET_IP" ]]; then
    echo "ERROR: Failed to resolve proxy node IP"
    exit 1
fi
echo "Proxy node IP (TARGET_IP): $TARGET_IP"
export TARGET_IP
export DATA_PORT="${DATA_PORT:-10000}"
echo "E2SAR data port (DATA_PORT): $DATA_PORT"
echo ""

# Start one coordinator for all 5 tests (avoids Podman namespace issues
# caused by multiple srun steps each getting their own mount namespace).
start_coordinator 5

#=============================================================================
# TEST 1: Baseline — no backpressure
#  Large buffer + fast consumer → should never trigger backpressure.
#=============================================================================
echo "========================================="
echo "TEST 1: Baseline (no backpressure)"
echo "========================================="

export BP_THRESHOLD="0.95"  # for b2b assertions
start_proxy 1 "BUFFER_SIZE=20000 ZMQ_HWM=10000 READY_THRESHOLD=0.95 BP_LOG_INTERVAL=5"
start_consumer 0
wait_for_proxy_ready 1

srun --nodes=1 --ntasks=1 --nodelist="$NODE_SENDER" \
    bash -c "cd '$JOB_DIR' && TARGET_IP='$TARGET_IP' DATA_PORT='$DATA_PORT' \
    '$SCRIPT_DIR/b2b_sender.sh' --rate 10" || true

echo "Waiting 10s for drain..."
sleep 10

stop_proxy 1
stop_consumer

echo "Assertions:"
assert_no_backpressure test1_proxy.log
assert_fill_stayed_low 10 test1_proxy.log
assert_events_received 90 100
assert_no_crash test1_proxy.log

[[ -f b2b_sender.log ]] && mv b2b_sender.log test1_b2b_sender.log || true
archive_logs test1

#=============================================================================
# TEST 2: Mild backpressure — activates and recovers
#  Small buffer + 10ms consumer delay → fill should cross threshold then drain.
#=============================================================================
echo "========================================="
echo "TEST 2: Mild backpressure (10ms delay, buf=100)"
echo "========================================="

export BP_THRESHOLD="0.5"  # for b2b assertions
start_proxy 2 "BUFFER_SIZE=100 ZMQ_HWM=5 ZMQ_SNDBUF=131072 READY_THRESHOLD=0.95 BP_LOG_INTERVAL=5"
start_consumer 10 2 131072
wait_for_proxy_ready 2

# Soak 30s: fill rate ~25 events/s → ring buffer fills to 100% in ~4s
srun --nodes=1 --ntasks=1 --nodelist="$NODE_SENDER" \
    bash -c "cd '$JOB_DIR' && TARGET_IP='$TARGET_IP' DATA_PORT='$DATA_PORT' \
    '$SCRIPT_DIR/run_soak_sender.sh' --sender-script b2b_sender.sh --duration 30 --rate 10" || true

echo "Waiting 20s for drain..."
sleep 20

stop_proxy 2
stop_consumer

echo "Assertions:"
assert_backpressure_triggered test2_proxy.log
assert_backpressure_recovered test2_proxy.log
assert_fill_peaked 20 test2_proxy.log
assert_events_received 70
assert_no_crash test2_proxy.log

[[ -f b2b_sender.log ]] && mv b2b_sender.log test2_b2b_sender.log || true
archive_logs test2

#=============================================================================
# TEST 3: Heavy backpressure — sustained saturation
#  Very slow consumer (100ms) → ring fills, stays full, PID controller ramps.
#=============================================================================
echo "========================================="
echo "TEST 3: Heavy backpressure (100ms delay, buf=100)"
echo "========================================="

export BP_THRESHOLD="0.5"  # for b2b assertions
start_proxy 3 "BUFFER_SIZE=100 ZMQ_HWM=5 ZMQ_SNDBUF=131072 READY_THRESHOLD=0.95 BP_LOG_INTERVAL=5"
start_consumer 100 2 131072
wait_for_proxy_ready 3

srun --nodes=1 --ntasks=1 --nodelist="$NODE_SENDER" \
    bash -c "cd '$JOB_DIR' && TARGET_IP='$TARGET_IP' DATA_PORT='$DATA_PORT' \
    '$SCRIPT_DIR/b2b_sender.sh' --num 200 --rate 10" || true

echo "Waiting 30s for drain..."
sleep 30

stop_proxy 3
stop_consumer

echo "Assertions:"
assert_backpressure_triggered test3_proxy.log
assert_sustained_bp 3 test3_proxy.log
assert_fill_peaked 80 test3_proxy.log
assert_control_peaked 0.4 test3_proxy.log  # SKIP in b2b mode (logged by assert itself)
assert_no_crash test3_proxy.log

[[ -f b2b_sender.log ]] && mv b2b_sender.log test3_b2b_sender.log || true
archive_logs test3

#=============================================================================
# TEST 4: Small-event stress (64KB events, 50ms delay)
#  Higher event rate due to small events → backpressure still triggers.
#=============================================================================
echo "========================================="
echo "TEST 4: Small-event stress (64KB, 50ms delay, buf=100)"
echo "========================================="

export BP_THRESHOLD="0.5"  # for b2b assertions
start_proxy 4 "BUFFER_SIZE=100 ZMQ_HWM=5 ZMQ_SNDBUF=131072 READY_THRESHOLD=0.95 BP_LOG_INTERVAL=5"
start_consumer 50 2 131072
wait_for_proxy_ready 4

srun --nodes=1 --ntasks=1 --nodelist="$NODE_SENDER" \
    bash -c "cd '$JOB_DIR' && TARGET_IP='$TARGET_IP' DATA_PORT='$DATA_PORT' \
    '$SCRIPT_DIR/b2b_sender.sh' --length 65536 --rate 10" || true

echo "Waiting 15s for drain..."
sleep 15

stop_proxy 4
stop_consumer

echo "Assertions:"
assert_backpressure_triggered test4_proxy.log
assert_fill_peaked 20 test4_proxy.log
assert_no_crash test4_proxy.log

[[ -f b2b_sender.log ]] && mv b2b_sender.log test4_b2b_sender.log || true
archive_logs test4

#=============================================================================
# TEST 5: 5-minute soak (20ms delay, buf=200, looping sender)
#  Long-duration stability: proxy must survive 5 minutes without crashing.
#=============================================================================
echo "========================================="
echo "TEST 5: 5-minute soak (20ms delay, buf=200)"
echo "========================================="

export BP_THRESHOLD="0.3"  # for b2b assertions
start_proxy 5 "BUFFER_SIZE=200 ZMQ_HWM=10 READY_THRESHOLD=0.95 BP_LOG_INTERVAL=5"
start_consumer 20 5 131072
wait_for_proxy_ready 5

srun --nodes=1 --ntasks=1 --nodelist="$NODE_SENDER" \
    bash -c "cd '$JOB_DIR' && TARGET_IP='$TARGET_IP' DATA_PORT='$DATA_PORT' \
    '$SCRIPT_DIR/run_soak_sender.sh' --sender-script b2b_sender.sh --duration 300 --rate 10" || true

echo "Waiting 15s for drain..."
sleep 15

# Check coordinator still alive (= proxy was alive throughout the soak)
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

[[ -f b2b_sender.log ]] && mv b2b_sender.log test5_b2b_sender.log || true
archive_logs test5

#=============================================================================
# Finalize
#=============================================================================

kill -TERM "$COORDINATOR_PID" 2>/dev/null || true
wait "$COORDINATOR_PID" 2>/dev/null || true

bp_print_summary "B2B Backpressure Suite (5 tests)"
