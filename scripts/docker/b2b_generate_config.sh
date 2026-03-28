#!/bin/bash
# b2b_generate_config.sh — Generate config for back-to-back mode (no load balancer)
#
# Unlike generate_config.sh, this does NOT require an INSTANCE_URI file.
# It auto-detects DATA_IP from the local hostname and constructs a dummy
# EJFAT URI pointing directly at the proxy node (sender → proxy, no LB).
#
# Usage:
#   ./b2b_generate_config.sh [OUTPUT_FILE]
#
# Environment:
#   DATA_IP      Override auto-detected listen IP (optional)
#   DATA_PORT    UDP port for E2SAR reassembler (default: 10000)
#   + all the same optional overrides as generate_config.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_FILE="${1:-proxy_config.yaml}"

TEMPLATE="${PROJECT_ROOT}/config/distributed.yaml.template"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "ERROR: Template not found: $TEMPLATE"
    exit 1
fi

echo "Generating back-to-back config from template: $TEMPLATE (use_cp=false, with_lb_header=true)"

# Auto-detect DATA_IP from hostname (can be overridden by environment)
if [[ -z "${DATA_IP:-}" ]]; then
    DATA_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
    if [[ -z "$DATA_IP" ]]; then
        echo "ERROR: Failed to auto-detect DATA_IP from hostname"
        exit 1
    fi
fi

export DATA_IP
export DATA_PORT="${DATA_PORT:-10000}"
export SLURM_JOB_ID="${SLURM_JOB_ID:-$$}"

# Construct a dummy EJFAT URI pointing directly at this node.
# E2SAR requires a properly formatted URI even with use_cp=false.
# The sync address is a dummy (not used without CP).
export EJFAT_URI="ejfat://b2b-test@${DATA_IP}:9876/lb/1?data=${DATA_IP}:${DATA_PORT}&sync=${DATA_IP}:19523"

# Set defaults for optional variables (same as generate_config.sh)
export RECV_THREADS="${RECV_THREADS:-4}"
export RCV_BUF_SIZE="${RCV_BUF_SIZE:-10485760}"
export VALIDATE_CERT="${VALIDATE_CERT:-false}"
export USE_CP="false"
export WITH_LB_HEADER="true"
export ZMQ_PORT="${ZMQ_PORT:-5555}"
export ZMQ_HWM="${ZMQ_HWM:-10000}"
export ZMQ_IO_THREADS="${ZMQ_IO_THREADS:-2}"
export POLL_SLEEP="${POLL_SLEEP:-50}"
export ZMQ_SNDBUF="${ZMQ_SNDBUF:-2097152}"
export BP_PERIOD="${BP_PERIOD:-50}"
export READY_THRESHOLD="${READY_THRESHOLD:-0.95}"
export LINGER_MS="${LINGER_MS:-0}"
export BP_LOG_INTERVAL="${BP_LOG_INTERVAL:-100}"
export PID_SETPOINT="${PID_SETPOINT:-0.5}"
export PID_KP="${PID_KP:-1.0}"
export PID_KI="${PID_KI:-0.0}"
export PID_KD="${PID_KD:-0.0}"
export BUFFER_SIZE="${BUFFER_SIZE:-20000}"
export RECV_TIMEOUT="${RECV_TIMEOUT:-100}"
export PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-10000}"

# Generate config using envsubst
envsubst < "$TEMPLATE" > "$OUTPUT_FILE"

echo "Config generated: $OUTPUT_FILE"
echo ""
echo "Key settings:"
echo "  data_ip: $DATA_IP"
echo "  data_port: $DATA_PORT"
echo "  EJFAT_URI (dummy): $EJFAT_URI"
echo "  ZMQ endpoint: tcp://*:$ZMQ_PORT"
echo "  use_cp: false"
echo "  with_lb_header: true"
