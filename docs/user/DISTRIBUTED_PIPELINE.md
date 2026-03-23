# Distributed Pipeline Testing Guide

## Overview

The distributed pipeline scripts let you run the four pipeline components across separate remote machines, controlled entirely from your local macOS workstation via SSH. All you need is key-based SSH access to the remote hosts — no shared filesystem, no Slurm, no container runtime.

The pipeline carries data end-to-end from a sender, through the EJFAT/E2SAR transport layer, to a validator:

```
Node 1: Sender           Node 2: Bridge           Node 3: Proxy            Node 4: Validator
┌──────────────────┐     ┌─────────────────────┐  ┌──────────────────────┐  ┌─────────────────┐
│ pipeline_sender  │     │  zmq_ejfat_bridge   │  │  ejfat_zmq_proxy    │  │pipeline_validator│
│ ZMQ PUSH :5556   │─ZMQ►│  ZMQ PULL           │  │  E2SAR UDP :19522   │  │ ZMQ PULL        │
│                  │     │  E2SAR Segmenter ───│─UDP►  Reassembler       │  │                 │
│                  │     │                     │  │  ZMQ PUSH :5555  ───│─ZMQ►               │
└──────────────────┘     └─────────────────────┘  └──────────────────────┘  └─────────────────┘
```

Scripts live in `scripts/MacOS/distributed/`. All logs stream to your local machine in real time.

---

## Prerequisites

### SSH access
All four remote hosts must be SSH-accessible from your local machine **without a password**. Set up key-based authentication or configure your ssh-agent before proceeding. Test with:

```bash
ssh user@proxy.host "echo ok"
ssh user@bridge.host "echo ok"
ssh user@sender.host "echo ok"
ssh user@validator.host "echo ok"
```

### Binaries on remote hosts
Each remote host needs the appropriate compiled binary from this project:

| Host | Binary needed |
|------|--------------|
| Proxy | `ejfat_zmq_proxy` |
| Bridge | `zmq_ejfat_bridge` |
| Sender | `pipeline_sender` |
| Validator | `pipeline_validator` |

Build on each host (or cross-compile and deploy):
```bash
cmake --preset linux   # or macos
cmake --build build -j
```

### `stdbuf` on remote hosts
The scripts wrap remote commands in `stdbuf -oL` for reliable log streaming. This is part of GNU coreutils:
```bash
# Debian/Ubuntu
sudo apt install coreutils

# macOS (needed on macOS remote hosts)
brew install coreutils   # provides gstdbuf; create alias or symlink stdbuf
```

---

## Quick Start

### 1. Create your local configuration

```bash
cd scripts/MacOS/distributed
cp distributed_env.sh distributed_env.local.sh
```

Edit `distributed_env.local.sh`. At minimum, set:

```bash
# SSH addresses
PROXY_HOST="alice@proxy.example.com"
BRIDGE_HOST="alice@bridge.example.com"
SENDER_HOST="alice@sender.example.com"
VALIDATOR_HOST="alice@validator.example.com"

# IP of the proxy node — used by both bridge (to target UDP) and validator (to connect ZMQ)
# Must be a routable IP address, not a hostname
PROXY_DATA_IP="10.0.1.3"

# Path to binaries on remote hosts (all 4 use the same directory by default)
REMOTE_BIN_DIR="/home/alice/ejfat_proxy/build/bin"
```

### 2. Verify connectivity

```bash
source distributed_env.local.sh
./status.sh
```

Expected output:
```
Pipeline Component Status
════════════════════════════════════════════════════════════════
  Component    Host                                     Status     PID
  ────────────────────────────────────────────────────────────
  proxy        alice@proxy.example.com                  STOPPED    -
  bridge       alice@bridge.example.com                 STOPPED    -
  sender       alice@sender.example.com                 STOPPED    -
  validator    alice@validator.example.com              STOPPED    -
════════════════════════════════════════════════════════════════
```

`UNREACHABLE` means SSH failed. Check your SSH config and key.

### 3. Run the full pipeline

```bash
source distributed_env.local.sh
./run_pipeline.sh
```

The orchestrator launches components in the correct order, streams all logs locally, and prints a PASS/FAIL result when the validator finishes.

---

## Modes

### Back-to-Back Mode (default, no load balancer)

No EJFAT load balancer infrastructure required. The bridge sends UDP packets directly to the proxy. This is the recommended mode for testing and development.

```bash
PIPELINE_MODE=b2b ./run_pipeline.sh
```

The EJFAT URI is constructed automatically from `PROXY_DATA_IP` and `DATA_PORT`:
```
ejfat://b2b-dist@<PROXY_DATA_IP>:9876/lb/1?data=<PROXY_DATA_IP>:<DATA_PORT>&sync=...
```

### LB Mode (with real EJFAT load balancer)

Requires a valid instance-level URI from a prior LB reservation.

```bash
export PIPELINE_MODE=lb
export EJFAT_URI="ejfats://token@lb.es.net:443/lb/xyz?data=10.0.0.1&sync=10.0.0.1:19522"
./run_pipeline.sh
```

In LB mode the proxy registers with the load balancer on startup and sends backpressure state every 50 ms. The bridge does not use `--no-cp` and registers the sender IP with the LB.

---

## Running Components Individually

Each `start_*.sh` script is fully self-contained and can be run on its own terminal — useful for debugging a single component or building a custom orchestration.

**Required startup order** (each must be ready before the next connects to it):

```
1. Proxy      (listens for UDP from bridge, serves ZMQ to validator)
2. Validator  (connects to proxy ZMQ — must connect before data flows)
3. Sender     (binds ZMQ PUSH — must bind before bridge connects)
4. Bridge     (connects to sender ZMQ, starts sending UDP to proxy)
```

**Terminal 1 — Proxy:**
```bash
source distributed_env.local.sh
./start_proxy.sh
```
Blocks until "All components started" is detected in the proxy log (up to `PROXY_READY_TIMEOUT=30` seconds).

**Terminal 2 — Validator:**
```bash
source distributed_env.local.sh
./start_validator.sh
```
Returns immediately. The validator runs in the background on the remote host; its exit code determines PASS/FAIL.

**Terminal 3 — Sender:**
```bash
source distributed_env.local.sh
./start_sender.sh              # blocks until all messages sent
./start_sender.sh --bg         # or: background mode (for scripting)
```

**Terminal 4 — Bridge:**
```bash
source distributed_env.local.sh
./start_bridge.sh
```
Blocks until "ZMQ EJFAT Bridge started" is detected (up to 15 seconds).

### Checking the result

```bash
./status.sh                    # while running: shows RUNNING/STOPPED per component
cat runs/distributed_*/validator.exit   # 0=PASS, 1=errors, 2=timeout
```

---

## Logs

All component logs stream in real time to a local run directory:

```
runs/distributed_20260322_103045/
├── proxy.log          # ejfat_zmq_proxy stdout/stderr
├── bridge.log         # zmq_ejfat_bridge stdout/stderr
├── sender.log         # pipeline_sender stdout/stderr
├── validator.log      # pipeline_validator stdout/stderr
├── proxy_config.yaml  # Generated YAML config uploaded to proxy
├── sender.exit        # Sender exit code
└── validator.exit     # Validator exit code (0=PASS, 1=errors, 2=timeout)
```

Follow a log in real time:
```bash
tail -f runs/distributed_*/proxy.log
tail -f runs/distributed_*/validator.log
```

---

## Stopping a Run

The orchestrator (`run_pipeline.sh`) automatically cleans up all remote components when it exits — whether normally, via Ctrl+C, or due to an error.

To stop a run manually (e.g., if the orchestrator was killed):
```bash
./stop_all.sh                     # stops the most recent run
./stop_all.sh runs/distributed_XYZ  # stops a specific run
```

---

## Configuration Reference

### Required variables

| Variable | Description |
|----------|-------------|
| `PROXY_HOST` | SSH address of proxy node (`user@host`) |
| `BRIDGE_HOST` | SSH address of bridge node |
| `SENDER_HOST` | SSH address of sender node |
| `VALIDATOR_HOST` | SSH address of validator node |
| `PROXY_DATA_IP` | Routable IP of proxy node for E2SAR UDP and ZMQ traffic |

### Commonly adjusted variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PIPELINE_MODE` | `b2b` | `b2b` or `lb` |
| `EJFAT_URI` | (auto in b2b) | EJFAT instance URI for `lb` mode |
| `SENDER_IP` | (auto-detect) | Routable IP of sender; auto-detected via `hostname -I` if empty |
| `SENDER_COUNT` | `1000` | Messages to send |
| `SENDER_SIZE` | `4096` | Message size in bytes |
| `BRIDGE_MTU` | `9000` | MTU for E2SAR UDP fragmentation (use 1500 on standard Ethernet) |
| `DATA_PORT` | `19522` | E2SAR reassembler UDP listen port on proxy |
| `ZMQ_PORT` | `5555` | Proxy ZMQ PUSH port (validator connects here) |
| `SENDER_ZMQ_PORT` | `5556` | Sender ZMQ PUSH port (bridge connects here) |
| `REMOTE_BIN_DIR` | `/opt/ejfat/bin` | Binary directory on all remote hosts |
| `DRAIN_TIME` | `30` | Seconds to wait after sender exits for pipeline to drain |

### Proxy tuning (passed through to YAML config)

| Variable | Default | Description |
|----------|---------|-------------|
| `BUFFER_SIZE` | `10000` | Ring buffer capacity (events) |
| `ZMQ_HWM` | `10000` | ZMQ send high-water mark |
| `RECV_THREADS` | `4` | E2SAR reassembler receive threads |
| `READY_THRESHOLD` | `0.95` | Buffer fill fraction that triggers backpressure |

All 25+ proxy config parameters from `distributed_env.sh` can be overridden.

---

## Troubleshooting

### Proxy never becomes ready

Check `runs/distributed_*/proxy.log`. Common causes:

- **`PROXY_DATA_IP` is wrong** — the proxy can't bind to an IP it doesn't own. Use `ssh $PROXY_HOST hostname -I` to verify the correct IP.
- **Port already in use** — another process is using `DATA_PORT` (19522) or `ZMQ_PORT` (5555). Check with `ssh $PROXY_HOST "ss -ulnp | grep 19522"`.
- **Binary not found** — verify `REMOTE_PROXY_BIN` points to an executable file on the proxy host.

### Bridge can't connect to sender

Check `runs/distributed_*/bridge.log`. The bridge connects to `tcp://${SENDER_IP}:${SENDER_ZMQ_PORT}`. If `SENDER_IP` was auto-detected incorrectly (e.g., picked up a loopback or VPN address), set it explicitly:
```bash
SENDER_IP="10.0.1.1" ./run_pipeline.sh
```

### Messages not reaching validator

- **Bridge → Proxy UDP path**: The URI's `data=` parameter must point to `PROXY_DATA_IP:DATA_PORT` as reachable *from the bridge host*. Check firewalls and routing.
- **Proxy → Validator ZMQ path**: The validator connects to `tcp://${PROXY_DATA_IP}:${ZMQ_PORT}`. Verify port `ZMQ_PORT` is not blocked between the validator and proxy hosts.
- **Multi-homed proxy**: If the proxy host has multiple network interfaces, `PROXY_DATA_IP` must be the IP on the interface reachable from both the bridge (UDP) and the validator (ZMQ). These may differ on some networks; in that case, consider running proxy and validator on the same network segment.

### `stdbuf: command not found`

Install GNU coreutils on the remote host (see Prerequisites). On macOS remote hosts, `brew install coreutils` provides `gstdbuf`; create a symlink: `sudo ln -s $(brew --prefix coreutils)/bin/gstdbuf /usr/local/bin/stdbuf`.

### SSH connection refused / timeout

- Ensure the remote host allows SSH from your IP
- Verify `SSH_OPTS` does not override `BatchMode` if you need password auth (use `SSH_KEY` instead)
- Test manually: `ssh -v -o ConnectTimeout=10 $PROXY_HOST "true"`

---

## Example: Running on Four Perlmutter Compute Nodes

When you have an interactive Slurm allocation of 4 nodes, use `srun --pty bash` on each node to open a shell, then run the individual `start_*.sh` scripts from each:

```bash
# On your local machine: set hosts to the Perlmutter node hostnames
export PROXY_HOST="nid001234"
export BRIDGE_HOST="nid001235"
export SENDER_HOST="nid001236"
export VALIDATOR_HOST="nid001237"
export PROXY_DATA_IP="128.55.x.x"    # proxy node's HSN (high-speed network) IP
export REMOTE_BIN_DIR="/path/to/ejfat_proxy/build/bin"
export PIPELINE_MODE="b2b"

source distributed_env.local.sh
./run_pipeline.sh
```

For full Perlmutter/Slurm batch job orchestration with load balancer support, see the Perlmutter scripts in `scripts/perlmutter/`.

---

## Related Documentation

- [LOCAL_TESTING.md](LOCAL_TESTING.md) — Running all components on one machine (localhost)
- [PIPELINE_GUIDE.md](PIPELINE_GUIDE.md) — Architecture and how to write your own ZMQ source/sink
- [USER_TESTING_GUIDE.md](USER_TESTING_GUIDE.md) — Perlmutter and Slurm-based testing
- [CONFIG_UPDATE.md](CONFIG_UPDATE.md) — Full 39-parameter proxy config reference
