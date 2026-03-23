# Distributed Pipeline Scripts

Run the EJFAT → ZMQ pipeline across 4 separate remote hosts, controlled via SSH from your local machine.

## Pipeline Architecture

```
Node 1 (SENDER)          Node 2 (BRIDGE)           Node 3 (PROXY)           Node 4 (VALIDATOR)
┌───────────────┐         ┌──────────────────┐      ┌──────────────────┐     ┌─────────────────┐
│pipeline_sender│         │zmq_ejfat_bridge  │      │ejfat_zmq_proxy   │     │pipeline_validator│
│ZMQ PUSH :5556 │──ZMQ───▶│ZMQ PULL          │      │E2SAR UDP :19522  │     │ZMQ PULL         │
│               │         │E2SAR Segmenter───│─UDP─▶│Reassembler       │     │                 │
│               │         │                  │      │ZMQ PUSH :5555 ───│─ZMQ▶│                 │
└───────────────┘         └──────────────────┘      └──────────────────┘     └─────────────────┘
```

**Two modes:**
- **B2B** (`PIPELINE_MODE=b2b`): No load balancer. Bridge sends UDP directly to proxy. Good for testing.
- **LB** (`PIPELINE_MODE=lb`): Real EJFAT load balancer. Requires a valid `EJFAT_URI` from a prior LB reservation.

## Quick Start

### 1. Configure

```bash
cp distributed_env.sh distributed_env.local.sh
```

Edit `distributed_env.local.sh`:

```bash
# Host assignments
PROXY_HOST="alice@proxy.example.com"
BRIDGE_HOST="alice@bridge.example.com"
SENDER_HOST="alice@sender.example.com"
VALIDATOR_HOST="alice@validator.example.com"

# Proxy's routable IP (where E2SAR UDP and ZMQ traffic lands)
PROXY_DATA_IP="10.0.1.3"

# Mode (b2b or lb)
PIPELINE_MODE="b2b"

# Binary paths on remote hosts
REMOTE_BIN_DIR="/home/alice/ejfat_proxy/build/bin"
```

### 2. Run (all at once)

```bash
cd scripts/MacOS/distributed
source distributed_env.local.sh
./run_pipeline.sh
```

### 3. Run (components individually)

Open 4 terminals (or SSH sessions). Run each component on a different node.

**Terminal 1 — Start proxy first** (must listen before bridge sends):
```bash
source distributed_env.local.sh
./start_proxy.sh
```

**Terminal 2 — Start validator** (must connect before data flows):
```bash
source distributed_env.local.sh
./start_validator.sh
```

**Terminal 3 — Start sender** (must bind before bridge connects):
```bash
source distributed_env.local.sh
./start_sender.sh
```

**Terminal 4 — Start bridge last** (connects to sender, sends to proxy):
```bash
source distributed_env.local.sh
./start_bridge.sh
```

## Files

| File | Purpose |
|------|---------|
| `distributed_env.sh` | Central configuration (hosts, ports, binary paths, run params). Copy to `.local.sh` and edit. |
| `ssh_common.sh` | Shared SSH helper functions. Sourced by all scripts. |
| `start_proxy.sh` | Launch `ejfat_zmq_proxy` on `PROXY_HOST`. Waits for readiness. |
| `start_bridge.sh` | Launch `zmq_ejfat_bridge` on `BRIDGE_HOST`. Waits for readiness. |
| `start_sender.sh` | Launch `pipeline_sender` on `SENDER_HOST`. Foreground by default. |
| `start_validator.sh` | Launch `pipeline_validator` on `VALIDATOR_HOST`. Background. |
| `run_pipeline.sh` | Orchestrator: launches all 4 in correct order, reports PASS/FAIL. |
| `stop_all.sh` | Graceful teardown of all remote components from a run directory. |
| `status.sh` | Check whether each component is running on its host. |

Config template: `config/distributed.yaml.template` (project root)

## Configuration Reference

### Required Variables

| Variable | Description |
|----------|-------------|
| `PROXY_HOST` | SSH address of proxy node (e.g., `user@host`) |
| `BRIDGE_HOST` | SSH address of bridge node |
| `SENDER_HOST` | SSH address of sender node |
| `VALIDATOR_HOST` | SSH address of validator node |
| `PROXY_DATA_IP` | Routable IP of the proxy node for E2SAR UDP + ZMQ traffic |

### Optional Variables (with defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `PIPELINE_MODE` | `b2b` | `b2b` or `lb` |
| `EJFAT_URI` | (auto in b2b) | EJFAT instance URI (required for `lb` mode) |
| `SENDER_IP` | (auto-detect) | Routable IP of sender for bridge to connect to |
| `DATA_PORT` | `19522` | E2SAR UDP port on proxy |
| `ZMQ_PORT` | `5555` | ZMQ PUSH port on proxy |
| `SENDER_ZMQ_PORT` | `5556` | ZMQ PUSH port on sender |
| `REMOTE_BIN_DIR` | `/opt/ejfat/bin` | Directory with binaries on remote hosts |
| `SENDER_COUNT` | `1000` | Number of messages to send |
| `SENDER_SIZE` | `4096` | Message size in bytes |
| `SENDER_RATE` | `0` | Messages/second (0 = unlimited) |
| `BRIDGE_MTU` | `9000` | MTU for E2SAR segmentation |
| `DRAIN_TIME` | `30` | Seconds to wait after sender finishes |
| `PROXY_READY_TIMEOUT` | `30` | Seconds to wait for proxy startup |

All proxy YAML config parameters (`BUFFER_SIZE`, `ZMQ_HWM`, `BP_PERIOD`, etc.) can also be overridden. See `distributed_env.sh` for the full list.

## SSH Requirements

- Key-based authentication (no password prompts) to all 4 hosts
- `SSH_KEY`: path to identity file if not using the default key or ssh-agent
- `SSH_OPTS`: additional SSH flags (default includes BatchMode, ConnectTimeout, StrictHostKeyChecking)

Test connectivity before running:
```bash
source distributed_env.local.sh && ./status.sh
```

## Run Directory

Each run creates a timestamped directory at `runs/distributed_<timestamp>/`:

```
runs/distributed_20260322_103045/
├── proxy_config.yaml     # Generated proxy YAML config
├── proxy.log             # Streamed from proxy host
├── bridge.log            # Streamed from bridge host
├── sender.log            # Streamed from sender host
├── validator.log         # Streamed from validator host
├── proxy_ssh.pid         # Local SSH process PID
├── bridge_ssh.pid
├── sender_ssh.pid
├── validator_ssh.pid
├── proxy_remote.pid      # PID on remote host
├── bridge_remote.pid
├── validator_remote.pid
├── proxy.host            # Hostname for stop_all.sh / status.sh
├── bridge.host
├── sender.host
├── validator.host
├── sender.exit           # Sender exit code
└── validator.exit        # Validator exit code (0=PASS, 1=errors, 2=timeout)
```

## Troubleshooting

**`stdbuf` not found on remote host**
`stdbuf` is part of GNU coreutils. Install with:
```bash
# Debian/Ubuntu
sudo apt install coreutils
# macOS
brew install coreutils && alias stdbuf=gstdbuf
```

**Proxy never becomes ready**
Check `runs/distributed_*/proxy.log`. Common causes:
- `PROXY_DATA_IP` is wrong (proxy can't bind to it)
- Port `DATA_PORT` already in use on proxy host
- Binary not found or wrong architecture

**Bridge can't connect to sender**
Check `SENDER_IP`. If `SENDER_IP` is empty, `status.sh` auto-detects via `hostname -I` — verify this returns the correct routable IP from the bridge's perspective.

**Messages not reaching validator**
- Verify `PROXY_DATA_IP` is the proxy's IP as seen from the bridge (UDP routing)
- Verify `PROXY_DATA_IP` is the proxy's IP as seen from the validator (ZMQ routing)
- These may differ on multi-homed hosts; set `PROXY_DATA_IP` and `SENDER_IP` explicitly

## Coordination API (Future)

A REST + WebSocket API (`api/`) is planned to replace the shell-based coordination:

```
GET  /api/v1/pipeline/status          — Component states (IDLE/STARTING/RUNNING/FAILED)
POST /api/v1/pipeline/launch          — Launch full pipeline (returns run_id)
POST /api/v1/pipeline/stop            — Stop all components
GET  /api/v1/components/{name}/logs   — Recent log lines
ws   /ws/logs/{name}                  — Real-time log stream
ws   /ws/status                       — Real-time state change events
```

The API will be implemented in Python (FastAPI) and designed for connection to a web-based GUI. See the plan document for the full API spec and state machine design.
