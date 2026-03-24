#!/bin/bash
# sender_common.sh — Shared helpers for Perlmutter sender scripts
#
# Source this from minimal_sender.sh and b2b_sender.sh to get:
#   start_memory_monitor LOG_FILE [INTERVAL_S]  — start background RSS monitor
#   stop_memory_monitor  MONITOR_PID LOG_FILE   — stop monitor, write summary

start_memory_monitor() {
    local log_file="$1"
    local interval="${2:-1}"

    {
        echo "# E2SAR Memory Monitor"
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
