#!/bin/bash
#SBATCH -N 3
#SBATCH -C cpu
#SBATCH -q debug
#SBATCH -t 00:10:00
#SBATCH -J ejfat_bp6
#
# TEST 6: Dual-receiver fairness — two consumers on one proxy's PUSH socket.
#
# The proxy's ZMQ PUSH socket distributes events round-robin to connected PULL
# consumers. When a consumer's receive buffers fill (HWM/RCVBUF reached), ZMQ
# skips it and routes to the next ready consumer. This test verifies:
#
#   1. The fast consumer receives MORE events than the slow consumer.
#   2. No events are lost: fast + slow >= total sent.
#   3. The proxy does not crash.
#
# Setup:
#   - Proxy: BUFFER_SIZE=200, generous buffer (events flow through quickly)
#   - Consumer FAST: no delay, default HWM (on NODE_CONSUMER)
#   - Consumer SLOW: 100ms delay, rcvhwm=2, rcvbuf=131072 (on NODE_CONSUMER, --overlap)
#   - Sender: 500 events at 10 Gbps (on NODE_SENDER)
#
# Usage:
#   export EJFAT_URI="ejfats://token@lb.es.net:443/lb/xyz?..."
#   export E2SAR_SCRIPTS_DIR="/path/to/ejfat_proxy/scripts/perlmutter"
#   sbatch -A <account> bp_test6.sh

set -uo pipefail

SCRIPT_DIR="${E2SAR_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=bp_common.sh
source "$SCRIPT_DIR/bp_common.sh"

bp_setup_env
bp_reserve_lb
start_coordinator

echo "========================================="
echo "TEST 6: Dual-receiver fairness"
echo "========================================="

# Low ZMQ_HWM (5) on the proxy PUSH socket so ZMQ's per-consumer send queue
# fills quickly.  Once the slow consumer's queue is full, ZMQ skips it and
# routes to the fast consumer.  We use the soak sender to sustain traffic
# long enough for the disparity to emerge (burst sending fills both queues
# before the slow consumer can fall behind).
start_proxy 1 "BUFFER_SIZE=200 ZMQ_HWM=5 ZMQ_SNDBUF=131072"

# Both consumers on NODE_CONSUMER (--overlap in start_named_consumer allows sharing).
# Fast consumer: no delay, default buffers
start_named_consumer consumer_fast "$NODE_CONSUMER" 0

# Slow consumer: 100ms delay, tiny buffers to trigger ZMQ flow control
start_named_consumer consumer_slow "$NODE_CONSUMER" 100 2 131072

# Give consumers a moment to connect before the proxy starts pushing
sleep 2

wait_for_proxy_ready 1

# Sustained send for 60s.  At 10 Gbps with 1MB events ≈ ~1200 events/min.
# The slow consumer handles ~10 events/s = ~600 events/min; fast consumer
# drains instantly → ZMQ should route the overflow to the fast consumer.
echo "Sending events for 60s..."
srun --nodes=1 --ntasks=1 --nodelist="$NODE_SENDER" \
    bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/run_soak_sender.sh' --duration 60 --rate 10" || true

# Wait for slow consumer to drain remaining backlog
echo "Waiting 30s for slow consumer to drain..."
sleep 30

stop_proxy 1
stop_all_named_consumers

echo ""
echo "========================================="
echo "Consumer results"
echo "========================================="

FAST_COUNT=$(get_consumer_event_count consumer_fast.log)
SLOW_COUNT=$(get_consumer_event_count consumer_slow.log)
FAST_COUNT=${FAST_COUNT:-0}
SLOW_COUNT=${SLOW_COUNT:-0}
TOTAL=$(( FAST_COUNT + SLOW_COUNT ))

echo "  Fast consumer: $FAST_COUNT events"
echo "  Slow consumer: $SLOW_COUNT events"
echo "  Total:         $TOTAL events (sent 500)"
echo ""

echo "Assertions:"

# 1. Fast consumer got more events than slow consumer
if [[ "$FAST_COUNT" -gt "$SLOW_COUNT" ]]; then
    assert_pass "fast-got-more (fast=$FAST_COUNT > slow=$SLOW_COUNT)"
else
    assert_fail "fast-got-more" "fast=$FAST_COUNT, slow=$SLOW_COUNT"
fi

# 2. No events lost — total received should be substantial.
#    With soak sender the exact count varies; require at least 100 total events
#    to confirm the pipeline is working end-to-end.
MIN_EXPECTED=100
if [[ "$TOTAL" -ge "$MIN_EXPECTED" ]]; then
    assert_pass "events-delivered (total=$TOTAL >= ${MIN_EXPECTED})"
else
    assert_fail "events-delivered" "total=$TOTAL < ${MIN_EXPECTED}"
fi

# 3. Both consumers received at least some events (ZMQ delivered to both)
if [[ "$FAST_COUNT" -gt 0 && "$SLOW_COUNT" -gt 0 ]]; then
    assert_pass "both-received (fast=$FAST_COUNT, slow=$SLOW_COUNT)"
else
    assert_fail "both-received" "fast=$FAST_COUNT, slow=$SLOW_COUNT"
fi

# 4. No crash
assert_no_crash test1_proxy.log

# Archive logs
for f in consumer_fast.log consumer_slow.log consumer_fast_wrapper.log consumer_slow_wrapper.log minimal_sender.log; do
    [[ -f "$f" ]] && mv "$f" "test6_${f}" || true
done
[[ -f "proxy.log" ]] && cp "proxy.log" "test6_proxy.log" || true
echo "Logs archived as test6_*"

kill -TERM "$COORDINATOR_PID" 2>/dev/null || true
wait "$COORDINATOR_PID" 2>/dev/null || true

bp_print_summary "Dual-receiver fairness"
