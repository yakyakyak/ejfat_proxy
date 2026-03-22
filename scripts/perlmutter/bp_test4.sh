#!/bin/bash
#SBATCH -N 3
#SBATCH -C cpu
#SBATCH -q debug
#SBATCH -t 00:10:00
#SBATCH -J ejfat_bp4
#
# TEST 4: Small-event stress (64KB events, 50ms delay, small buf)
#
# Usage:
#   export EJFAT_URI="ejfats://token@lb.es.net:443/lb/xyz?..."
#   export E2SAR_SCRIPTS_DIR="/path/to/ejfat_proxy/scripts/perlmutter"
#   sbatch -A <account> bp_test4.sh

set -uo pipefail

SCRIPT_DIR="${E2SAR_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=bp_common.sh
source "$SCRIPT_DIR/bp_common.sh"

bp_setup_env
bp_reserve_lb
start_coordinator

echo "========================================="
echo "TEST 4: Small-event stress (64KB, 50ms delay, buf=100)"
echo "========================================="

start_proxy 1 "BUFFER_SIZE=100 ZMQ_HWM=5 ZMQ_SNDBUF=131072 BP_THRESHOLD=0.5 BP_LOG_INTERVAL=5"
start_consumer 50 2 131072
wait_for_proxy_ready 1

srun --nodes=1 --ntasks=1 --nodelist="$NODE_SENDER" \
    bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/minimal_sender.sh' --length 65536 --rate 10" || true

echo "Waiting 15s for drain..."
sleep 15

stop_proxy 1
stop_consumer

echo "Assertions:"
assert_backpressure_triggered test1_proxy.log
assert_fill_peaked 20 test1_proxy.log
assert_no_crash test1_proxy.log

archive_logs test4

kill -TERM "$COORDINATOR_PID" 2>/dev/null || true
wait "$COORDINATOR_PID" 2>/dev/null || true

bp_print_summary "Small-event stress"
