#!/bin/bash
#SBATCH -N 3
#SBATCH -C cpu
#SBATCH -q debug
#SBATCH -t 00:10:00
#SBATCH -J ejfat_bp3
#
# TEST 3: Heavy backpressure — sustained saturation (100ms delay, small buf)
#
# Usage:
#   export EJFAT_URI="ejfats://token@lb.es.net:443/lb/xyz?..."
#   export E2SAR_SCRIPTS_DIR="/path/to/ejfat_proxy/scripts/perlmutter"
#   sbatch -A <account> bp_test3.sh

set -uo pipefail

SCRIPT_DIR="${E2SAR_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=bp_common.sh
source "$SCRIPT_DIR/bp_common.sh"

bp_setup_env
bp_reserve_lb
start_coordinator

echo "========================================="
echo "TEST 3: Heavy backpressure (100ms delay, buf=100)"
echo "========================================="

start_proxy 1 "BUFFER_SIZE=100 ZMQ_HWM=5 ZMQ_SNDBUF=131072 BP_THRESHOLD=0.5 BP_LOG_INTERVAL=5"
start_consumer 100 2 131072
wait_for_proxy_ready 1

srun --nodes=1 --ntasks=1 --nodelist="$NODE_SENDER" \
    bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/minimal_sender.sh' --num 200 --rate 10" || true

echo "Waiting 30s for drain..."
sleep 30

stop_proxy 1
stop_consumer

echo "Assertions:"
assert_backpressure_triggered test1_proxy.log
assert_sustained_bp 3 test1_proxy.log
assert_fill_peaked 80 test1_proxy.log
assert_control_peaked 0.4 test1_proxy.log
assert_no_crash test1_proxy.log

archive_logs test3

kill -TERM "$COORDINATOR_PID" 2>/dev/null || true
wait "$COORDINATOR_PID" 2>/dev/null || true

bp_print_summary "Heavy backpressure"
