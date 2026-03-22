#!/bin/bash
# b2b_sender.sh — E2SAR sender for back-to-back mode (no load balancer)
#
# Sends e2sar_perf events directly to the proxy's E2SAR UDP port,
# bypassing the EJFAT load balancer. Use this in place of minimal_sender.sh
# when running tests without a load balancer reservation.
#
# Usage:
#   TARGET_IP=<proxy_node_ip> DATA_PORT=<port> \
#   ./b2b_sender.sh [OPTIONS]
#
# Required environment:
#   TARGET_IP    IP address of the proxy node (E2SAR data destination)
#   DATA_PORT    UDP port of the proxy's E2SAR reassembler (default: 10000)
#
# Options:
#   --image IMAGE     Container image (default: ibaldin/e2sar:0.3.1a3)
#   --rate RATE       Sending rate in Gbps (default: 1)
#   --length LENGTH   Event buffer length in bytes (default: 1048576)
#   --num COUNT       Number of events to send (default: 100)
#   --mtu MTU         MTU size in bytes (default: 9000)
#   --ipv6            Use IPv6 (default: false)
#   --no-monitor      Disable memory monitoring (default: enabled)
#   --help            Show this help message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MEMORY_MONITOR_PID=""

# Required environment
TARGET_IP="${TARGET_IP:-}"
DATA_PORT="${DATA_PORT:-10000}"

# Default values
E2SAR_IMAGE="${E2SAR_IMAGE:-ibaldin/e2sar:0.3.1a3}"
RATE="1"
LENGTH="1048576"
NUM="100"
MTU="9000"
USE_IPV6="false"
ENABLE_MONITOR="true"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --image)
            E2SAR_IMAGE="$2"
            shift 2
            ;;
        --rate)
            RATE="$2"
            shift 2
            ;;
        --length)
            LENGTH="$2"
            shift 2
            ;;
        --num)
            NUM="$2"
            shift 2
            ;;
        --mtu)
            MTU="$2"
            shift 2
            ;;
        --ipv6)
            USE_IPV6="true"
            shift
            ;;
        --no-monitor)
            ENABLE_MONITOR="false"
            shift
            ;;
        --help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

if [[ -z "$TARGET_IP" ]]; then
    echo "ERROR: TARGET_IP must be set to the proxy node's IP address"
    exit 1
fi

# Construct the EJFAT URI pointing directly at the proxy (no LB).
# E2SAR requires a valid URI format even without a control plane.
# The sync address is a dummy (not contacted without CP).
EJFAT_URI="ejfat://b2b-test@${TARGET_IP}:9876/lb/1?data=${TARGET_IP}:${DATA_PORT}&sync=${TARGET_IP}:19523"

echo "Starting E2SAR back-to-back sender..."
echo "Target proxy: ${TARGET_IP}:${DATA_PORT}"
echo "Container Image: $E2SAR_IMAGE"

# Auto-detect sender IP by routing to the proxy node
echo "Auto-detecting sender IP..."
if [[ "$USE_IPV6" == "true" ]]; then
    SENDER_IP=$(ip -6 route get "$TARGET_IP" 2>/dev/null | head -1 | sed 's/^.*src//' | awk '{print $1}')
else
    SENDER_IP=$(ip route get "$TARGET_IP" | head -1 | sed 's/^.*src//' | awk '{print $1}')
fi

if [[ -z "$SENDER_IP" ]]; then
    echo "ERROR: Failed to detect sender IP (route to $TARGET_IP)"
    exit 1
fi

echo "Sender IP: $SENDER_IP"
echo "Rate: $RATE Gbps"
echo "Event Length: $LENGTH bytes"
echo "Number of Events: $NUM"
echo "MTU: $MTU bytes"
echo ""

#=============================================================================
# Memory monitoring (same pattern as minimal_sender.sh)
#=============================================================================

start_memory_monitor() {
    local log_file="$1"
    local interval="${2:-1}"

    {
        echo "# E2SAR B2B Memory Monitor"
        echo "# Started: $(date -Iseconds)"
        echo "# Interval: ${interval} second(s)"
        echo "#"
        echo "# Columns: TIMESTAMP, PID, RSS_KB, VSZ_KB, %MEM, %CPU, ELAPSED_TIME, COMMAND"
    } > "$log_file"

    (
        while true; do
            PIDS=$(pgrep -f "e2sar_perf.*--send" 2>/dev/null || true)
            if [ -n "$PIDS" ]; then
                for PID in $PIDS; do
                    PS_INFO=$(ps -p "$PID" -o pid=,rss=,vsz=,%mem=,%cpu=,etime=,args= 2>/dev/null || true)
                    if [ -n "$PS_INFO" ]; then
                        read -r P_PID RSS VSZ MEM CPU ETIME ARGS <<< "$PS_INFO"
                        echo "$(date -Iseconds), $P_PID, $RSS, $VSZ, $MEM, $CPU, $ETIME, $ARGS" >> "$log_file"
                    fi
                done
            fi
            sleep "$interval"
        done
    ) >/dev/null 2>&1 &

    echo $!
}

stop_memory_monitor() {
    local monitor_pid="$1"
    local log_file="$2"

    if [ -n "$monitor_pid" ] && kill -0 "$monitor_pid" 2>/dev/null; then
        kill "$monitor_pid" 2>/dev/null || true
        wait "$monitor_pid" 2>/dev/null || true

        {
            echo "#"
            echo "# Stopped: $(date -Iseconds)"
        } >> "$log_file"

        if [ -f "$log_file" ] && [ -s "$log_file" ]; then
            MAX_RSS=$(grep -v '^#' "$log_file" | awk -F', ' '{print $3}' | sort -n | tail -1)
            MIN_RSS=$(grep -v '^#' "$log_file" | awk -F', ' '{print $3}' | sort -n | head -1)
            if [ -n "$MAX_RSS" ] && [ -n "$MIN_RSS" ]; then
                {
                    echo "#"
                    echo "# Memory Summary:"
                    echo "#   Peak RSS: $((MAX_RSS / 1024)) MB ($MAX_RSS KB)"
                    echo "#   Min RSS:  $((MIN_RSS / 1024)) MB ($MIN_RSS KB)"
                    echo "#   Growth:   $(((MAX_RSS - MIN_RSS) / 1024)) MB"
                } >> "$log_file"
            fi
        fi
    fi
}

#=============================================================================
# Build podman-hpc command — NOTE: no --withcp flag (back-to-back mode)
#=============================================================================

export EJFAT_URI

CMD=(
    podman-hpc
    run
    --rm
    --network host
    --env EJFAT_URI
    -e "MALLOC_ARENA_MAX=32"
    "$E2SAR_IMAGE"
    e2sar_perf
    --send
    --optimize=sendmmsg
    --sockets=16
    --ip="$SENDER_IP"
    --rate="$RATE"
    --length="$LENGTH"
    --num="$NUM"
    --mtu="$MTU"
    --bufsize=134217728
)

echo "Running: ${CMD[*]}"
echo ""

write_end_time() {
    local exit_code=$?
    if [[ "$ENABLE_MONITOR" == "true" ]] && [[ -n "$MEMORY_MONITOR_PID" ]]; then
        stop_memory_monitor "$MEMORY_MONITOR_PID" "b2b_sender_memory.log"
    fi
    echo "" >> b2b_sender.log
    echo "END_TIME (UTC): $(date -u '+%Y-%m-%d %H:%M:%S')" >> b2b_sender.log
    echo "EXIT_CODE: $exit_code" >> b2b_sender.log
    return $exit_code
}

trap 'write_end_time' EXIT INT TERM

{
    echo "START_TIME (UTC): $(date -u '+%Y-%m-%d %H:%M:%S')"
    echo ""
} | tee b2b_sender.log || true

if [[ "$ENABLE_MONITOR" == "true" ]]; then
    echo "Starting memory monitor (logging to b2b_sender_memory.log)..."
    MEMORY_MONITOR_PID=$(start_memory_monitor "b2b_sender_memory.log" 1)
    echo "Memory monitor started (PID: $MEMORY_MONITOR_PID)"
    echo ""
fi

"${CMD[@]}" 2>&1 | tee -a b2b_sender.log || true
CONTAINER_EXIT_CODE=${PIPESTATUS[0]}

exit $CONTAINER_EXIT_CODE
