#!/bin/bash
# distributed_env.sh — Central configuration for distributed pipeline tests
#
# Source this file before running any start_*.sh or run_pipeline.sh script.
# Copy to distributed_env.local.sh (gitignored) and customize for your hosts.
#
# Usage:
#   cp distributed_env.sh distributed_env.local.sh
#   edit distributed_env.local.sh
#   source distributed_env.local.sh && ./run_pipeline.sh

#=============================================================================
# Host assignments
#   Format: "user@hostname" or an SSH config alias
#   All 4 hosts must be SSH-accessible from this machine without a password
#   (key-based auth or ssh-agent).
#=============================================================================
PROXY_HOST="${PROXY_HOST:-}"         # e.g., alice@proxy.example.com
BRIDGE_HOST="${BRIDGE_HOST:-}"       # e.g., alice@bridge.example.com
SENDER_HOST="${SENDER_HOST:-}"       # e.g., alice@sender.example.com
VALIDATOR_HOST="${VALIDATOR_HOST:-}" # e.g., alice@validator.example.com

#=============================================================================
# Pipeline mode
#   "b2b"  — Back-to-back (no load balancer). EJFAT_URI is constructed
#             automatically from PROXY_DATA_IP and DATA_PORT. bridge uses --no-cp.
#   "lb"   — Full LB mode. EJFAT_URI must be a valid instance-level URI
#             obtained from a prior LB reservation.
#=============================================================================
PIPELINE_MODE="${PIPELINE_MODE:-b2b}"
EJFAT_URI="${EJFAT_URI:-}"           # Required if PIPELINE_MODE=lb

#=============================================================================
# Network addresses
#   These must be IP addresses (not hostnames) routable between nodes.
#   PROXY_DATA_IP: proxy node's IP where it listens for E2SAR UDP and serves ZMQ.
#   SENDER_IP:     sender node's IP that the bridge will connect to for ZMQ.
#                  If empty, auto-detected via "ssh SENDER_HOST hostname -I".
#=============================================================================
PROXY_DATA_IP="${PROXY_DATA_IP:-}"   # IP of the proxy host (required)
SENDER_IP="${SENDER_IP:-}"           # IP of the sender host (auto-detected if empty)

DATA_PORT="${DATA_PORT:-19522}"             # E2SAR Reassembler UDP listen port on proxy
ZMQ_PORT="${ZMQ_PORT:-5555}"               # Proxy ZMQ PUSH port (validator connects here)
SENDER_ZMQ_PORT="${SENDER_ZMQ_PORT:-5556}" # Sender ZMQ PUSH port (bridge connects here)

#=============================================================================
# Remote binary paths
#   Paths to the compiled binaries on each remote host. These may differ
#   per host if nodes have different filesystem layouts.
#=============================================================================
REMOTE_BIN_DIR="${REMOTE_BIN_DIR:-/opt/ejfat/bin}"
REMOTE_PROXY_BIN="${REMOTE_PROXY_BIN:-${REMOTE_BIN_DIR}/ejfat_zmq_proxy}"
REMOTE_BRIDGE_BIN="${REMOTE_BRIDGE_BIN:-${REMOTE_BIN_DIR}/zmq_ejfat_bridge}"
REMOTE_SENDER_BIN="${REMOTE_SENDER_BIN:-${REMOTE_BIN_DIR}/pipeline_sender}"
REMOTE_VALIDATOR_BIN="${REMOTE_VALIDATOR_BIN:-${REMOTE_BIN_DIR}/pipeline_validator}"

#=============================================================================
# Run parameters
#=============================================================================
SENDER_COUNT="${SENDER_COUNT:-1000}"   # Number of messages to send (0=unlimited)
SENDER_SIZE="${SENDER_SIZE:-4096}"     # Message size in bytes
SENDER_RATE="${SENDER_RATE:-0}"        # Messages per second (0=unlimited)

BRIDGE_MTU="${BRIDGE_MTU:-9000}"       # MTU for E2SAR segmentation (use 1500 on local Ethernet)
BRIDGE_SOCKETS="${BRIDGE_SOCKETS:-4}"  # Number of UDP send sockets (E2SAR thread pool)
BRIDGE_WORKERS="${BRIDGE_WORKERS:-1}"  # Number of ZMQ PULL receiver threads in bridge

VALIDATOR_TIMEOUT="${VALIDATOR_TIMEOUT:-120}"  # Seconds before validator times out

DRAIN_TIME="${DRAIN_TIME:-30}"         # Seconds to wait after sender exits for pipeline to drain

#=============================================================================
# Proxy YAML config parameters
#   These are passed to the proxy via an envsubst-processed YAML template.
#   All variables follow the same naming as local_pipeline_test.sh.
#=============================================================================
SLURM_JOB_ID="${SLURM_JOB_ID:-dist}"  # Used as worker name suffix (no Slurm here)
RECV_THREADS="${RECV_THREADS:-4}"
RCV_BUF_SIZE="${RCV_BUF_SIZE:-10485760}"   # 10 MB
VALIDATE_CERT="${VALIDATE_CERT:-false}"
USE_IPV6="${USE_IPV6:-false}"
ZMQ_HWM="${ZMQ_HWM:-10000}"
ZMQ_IO_THREADS="${ZMQ_IO_THREADS:-2}"
POLL_SLEEP="${POLL_SLEEP:-100}"            # microseconds
BP_PERIOD="${BP_PERIOD:-50}"               # milliseconds
READY_THRESHOLD="${READY_THRESHOLD:-0.95}"
BP_LOG_INTERVAL="${BP_LOG_INTERVAL:-5}"
LINGER_MS="${LINGER_MS:-5000}"
ZMQ_SNDBUF="${ZMQ_SNDBUF:-0}"
PID_SETPOINT="${PID_SETPOINT:-0.5}"
PID_KP="${PID_KP:-1.0}"
PID_KI="${PID_KI:-0.0}"
PID_KD="${PID_KD:-0.0}"
BUFFER_SIZE="${BUFFER_SIZE:-10000}"
RECV_TIMEOUT="${RECV_TIMEOUT:-100}"        # milliseconds
LOG_VERBOSITY="${LOG_VERBOSITY:-1}"
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-1000}"

#=============================================================================
# SSH settings
#=============================================================================
# BatchMode=yes:               Never prompt for a password (fail fast on auth error)
# ConnectTimeout=10:           Fail within 10s if host is unreachable
# StrictHostKeyChecking=...:   Accept new host keys, reject changed ones
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new}"
SSH_KEY="${SSH_KEY:-}"  # Path to identity file; empty = use ssh-agent / default key

# Base directory on remote hosts where run directories are created
REMOTE_RUN_DIR_BASE="${REMOTE_RUN_DIR_BASE:-/tmp/ejfat_runs}"

#=============================================================================
# Startup timeouts
#=============================================================================
PROXY_READY_TIMEOUT="${PROXY_READY_TIMEOUT:-30}"   # seconds
BRIDGE_READY_TIMEOUT="${BRIDGE_READY_TIMEOUT:-15}" # seconds
