#!/bin/bash
#SBATCH -N 3
#SBATCH -C cpu
#SBATCH -q debug
#SBATCH -t 00:15:00
#SBATCH -J ejfat_bp5
#
# TEST 5: 5-minute soak (20ms delay, buf=200, looping sender)
#
# Usage:
#   export EJFAT_URI="ejfats://token@lb.es.net:443/lb/xyz?..."
#   export E2SAR_SCRIPTS_DIR="/path/to/ejfat_proxy/scripts/perlmutter"
#   sbatch -A <account> bp_test5.sh

set -uo pipefail

SCRIPT_DIR="${E2SAR_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=bp_common.sh
source "$SCRIPT_DIR/bp_common.sh"

bp_setup_env
bp_reserve_lb
start_coordinator

echo "========================================="
echo "TEST 5: 5-minute soak (20ms delay, buf=200)"
echo "========================================="

start_proxy 1 "BUFFER_SIZE=200 ZMQ_HWM=10 BP_THRESHOLD=0.3 BP_LOG_INTERVAL=5"
start_consumer 20 5 131072
wait_for_proxy_ready 1

srun --nodes=1 --ntasks=1 --nodelist="$NODE_SENDER" \
    bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/run_soak_sender.sh' --duration 300 --rate 10" || true

echo "Waiting 15s for drain..."
sleep 15

# Check coordinator still alive (= proxy was alive throughout)
PROXY_ALIVE=false
kill -0 "$COORDINATOR_PID" 2>/dev/null && PROXY_ALIVE=true

stop_proxy 1
stop_consumer

echo "Assertions:"
assert_backpressure_triggered test1_proxy.log
assert_backpressure_recovered test1_proxy.log
assert_no_crash test1_proxy.log

if [[ "$PROXY_ALIVE" == "true" ]]; then
    assert_pass "coordinator-alive-at-end"
else
    assert_fail "coordinator-alive-at-end" "coordinator not running at drain time"
fi

archive_logs test5

kill -TERM "$COORDINATOR_PID" 2>/dev/null || true
wait "$COORDINATOR_PID" 2>/dev/null || true

bp_print_summary "5-minute soak"
