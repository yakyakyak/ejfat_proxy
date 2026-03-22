#!/bin/bash
#SBATCH -N 3
#SBATCH -C cpu
#SBATCH -q debug
#SBATCH -t 00:10:00
#SBATCH -J ejfat_bp1
#
# TEST 1: Baseline — no backpressure (fast consumer, large buffer)
#
# Usage:
#   export EJFAT_URI="ejfats://token@lb.es.net:443/lb/xyz?..."
#   export E2SAR_SCRIPTS_DIR="/path/to/ejfat_proxy/scripts/perlmutter"
#   sbatch -A <account> bp_test1.sh

set -uo pipefail

SCRIPT_DIR="${E2SAR_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=bp_common.sh
source "$SCRIPT_DIR/bp_common.sh"

bp_setup_env
bp_reserve_lb
start_coordinator

echo "========================================="
echo "TEST 1: Baseline (no backpressure)"
echo "========================================="

start_proxy 1 "BUFFER_SIZE=20000 ZMQ_HWM=10000"
start_consumer 0
wait_for_proxy_ready 1

srun --nodes=1 --ntasks=1 --nodelist="$NODE_SENDER" \
    bash -c "cd '$JOB_DIR' && '$SCRIPT_DIR/minimal_sender.sh' --rate 10" || true

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

kill -TERM "$COORDINATOR_PID" 2>/dev/null || true
wait "$COORDINATOR_PID" 2>/dev/null || true

bp_print_summary "Baseline (no backpressure)"
