#!/bin/bash
# Generate Perlmutter-specific config from template
#
# Usage:
#   ./generate_config.sh [OUTPUT_FILE]
#
# Requires:
#   - INSTANCE_URI file (created by minimal_reserve.sh)
#   - Template: config/distributed.yaml.template (relative to SLURM_SUBMIT_DIR)
#
# Outputs:
#   - Generated YAML config (default: perlmutter_config.yaml)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="${1:-perlmutter_config.yaml}"

# Find template (assume in config/ relative to submit directory)
TEMPLATE="${SLURM_SUBMIT_DIR:-$(pwd)}/config/distributed.yaml.template"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "ERROR: Template not found: $TEMPLATE"
    exit 1
fi

# Check for INSTANCE_URI file
INSTANCE_URI_FILE="INSTANCE_URI"
if [[ ! -f "$INSTANCE_URI_FILE" ]]; then
    echo "ERROR: $INSTANCE_URI_FILE not found"
    echo "Run minimal_reserve.sh first to create a reservation"
    exit 1
fi

echo "Generating config from template: $TEMPLATE"

# Extract EJFAT_URI from INSTANCE_URI file
EJFAT_URI=$(grep -E '^export EJFAT_URI=' "$INSTANCE_URI_FILE" | head -1 | sed "s/^export EJFAT_URI=//; s/^['\"]//; s/['\"]$//")

if [[ -z "$EJFAT_URI" ]]; then
    echo "ERROR: EJFAT_URI not found in $INSTANCE_URI_FILE"
    exit 1
fi

# Auto-detect data_ip using same logic as minimal_receiver.sh
echo "Auto-detecting data_ip..."

# Extract LB hostname from EJFAT_URI
# Format: ejfat://token@hostname:port/lb/1?sync=...
LB_HOST=$(echo "$EJFAT_URI" | sed 's|.*@\([^:]*\):.*|\1|')
echo "  LB Host: $LB_HOST"

# Resolve LB hostname to IP
if [[ "${USE_IPV6:-false}" == "true" ]]; then
    LB_IP=$(getent ahostsv6 "$LB_HOST" | head -1 | awk '{print $1}')
else
    LB_IP=$(getent ahostsv4 "$LB_HOST" | head -1 | awk '{print $1}')
fi

if [[ -z "$LB_IP" ]]; then
    echo "ERROR: Failed to resolve LB host: $LB_HOST"
    exit 1
fi
echo "  LB IP: $LB_IP"

# Find source IP for route to LB
DATA_IP=$(ip route get "$LB_IP" | head -1 | sed 's/^.*src//' | awk '{print $1}')

if [[ -z "$DATA_IP" ]]; then
    echo "ERROR: Failed to detect data_ip"
    exit 1
fi

echo "  Data IP: $DATA_IP"

# Export variables for envsubst
export EJFAT_URI
export DATA_IP
export SLURM_JOB_ID="${SLURM_JOB_ID:-0}"

# Set defaults for optional variables (can be overridden by environment)
export DATA_PORT="${DATA_PORT:-10000}"
export RECV_THREADS="${RECV_THREADS:-4}"
export RCV_BUF_SIZE="${RCV_BUF_SIZE:-10485760}"
export VALIDATE_CERT="${VALIDATE_CERT:-true}"
export USE_CP="${USE_CP:-true}"
export WITH_LB_HEADER="${WITH_LB_HEADER:-false}"
export LINGER_MS="${LINGER_MS:-0}"
# READY_THRESHOLD maps BP_THRESHOLD so the template variable name is consistent
export READY_THRESHOLD="${READY_THRESHOLD:-${BP_THRESHOLD:-0.95}}"
export ZMQ_PORT="${ZMQ_PORT:-5555}"
export ZMQ_HWM="${ZMQ_HWM:-200000}"
export ZMQ_IO_THREADS="${ZMQ_IO_THREADS:-2}"
export POLL_SLEEP="${POLL_SLEEP:-50}"
export ZMQ_SNDBUF="${ZMQ_SNDBUF:-2097152}"
export BP_PERIOD="${BP_PERIOD:-50}"
export BP_THRESHOLD="${BP_THRESHOLD:-0.95}"
export BP_LOG_INTERVAL="${BP_LOG_INTERVAL:-100}"
export PID_SETPOINT="${PID_SETPOINT:-0.5}"
export PID_KP="${PID_KP:-1.0}"
export PID_KI="${PID_KI:-0.0}"
export PID_KD="${PID_KD:-0.0}"
export BUFFER_SIZE="${BUFFER_SIZE:-200000}"
export RECV_TIMEOUT="${RECV_TIMEOUT:-100}"
export LOG_VERBOSITY="${LOG_VERBOSITY:-2}"
export PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-10000}"

# Generate config using envsubst
envsubst < "$TEMPLATE" > "$OUTPUT_FILE"

echo "Config generated: $OUTPUT_FILE"
echo ""
echo "Key settings:"
echo "  EJFAT_URI: $(echo "$EJFAT_URI" | sed -E 's|(://)(.{4})[^@]*(.{4})@|\1\2---\3@|')"
echo "  data_ip: $DATA_IP"
echo "  data_port: $DATA_PORT"
echo "  ZMQ endpoint: tcp://*:$ZMQ_PORT"
echo "  Worker: zmq-proxy-$SLURM_JOB_ID"
