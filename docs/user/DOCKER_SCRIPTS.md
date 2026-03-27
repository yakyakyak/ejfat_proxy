# Docker / Podman-HPC Scripts

Scripts in `scripts/docker/` run all components on the **local node** with no SLURM required. They auto-detect `podman-hpc` or `docker` at startup.

## Prerequisites

### Build the container image

```bash
cd /path/to/ejfat_proxy
podman-hpc build -t ejfat-zmq-proxy:latest .
podman-hpc migrate ejfat-zmq-proxy:latest
```

Or with Docker:

```bash
docker build -t ejfat-zmq-proxy:latest .
```

### Install pyzmq (for `run_consumer.sh`)

```bash
pip install --user pyzmq
```

---

## Scenario 1: Back-to-back pipeline test (no LB)

All components run on one node. No `INSTANCE_URI` needed.

**Terminal 1 — Proxy (b2b mode):**
```bash
cd /tmp/run1
B2B_MODE=true /path/to/ejfat_proxy/scripts/docker/run_proxy.sh
```
Wait for `All components started` in `proxy.log`.

**Terminal 2 — Pipeline sender:**
```bash
cd /tmp/run1
DELAY_BEFORE_SEND=3 /path/to/ejfat_proxy/scripts/docker/run_pipeline_sender.sh \
    --count 1000 --size 4096
```

**Terminal 3 — Validator:**
```bash
cd /tmp/run1
PROXY_NODE=localhost /path/to/ejfat_proxy/scripts/docker/run_pipeline_validator.sh \
    --expected 1000 --timeout 30
```

Exit code 0 = PASS.

---

## Scenario 2: Live LB pipeline test

Requires `INSTANCE_URI` file with a valid `EJFAT_URI` (from `minimal_reserve.sh` or provided manually).

**Terminal 1 — Proxy:**
```bash
cd /tmp/run2
cp /path/to/INSTANCE_URI .
/path/to/ejfat_proxy/scripts/docker/run_proxy.sh
```
Wait for `Worker registered` in `proxy.log`.

**Terminal 2 — Bridge (on sender node or same node):**
```bash
cd /tmp/run2
cp /path/to/INSTANCE_URI .
SENDER_NODE=localhost /path/to/ejfat_proxy/scripts/docker/run_zmq_ejfat_bridge.sh
```

**Terminal 3 — Sender:**
```bash
cd /tmp/run2
/path/to/ejfat_proxy/scripts/docker/run_pipeline_sender.sh --count 1000 --size 4096
```

**Terminal 4 — Consumer or validator:**
```bash
cd /tmp/run2
# Consumer (continuous):
PROXY_NODE=localhost /path/to/ejfat_proxy/scripts/docker/run_consumer.sh

# Or validator (pass/fail):
PROXY_NODE=localhost /path/to/ejfat_proxy/scripts/docker/run_pipeline_validator.sh \
    --expected 1000 --timeout 60
```

---

## Script reference

### `run_proxy.sh`

Starts `ejfat_zmq_proxy` in a container. Logs to `proxy.log` in the working directory.

```bash
# LB mode (default) — requires INSTANCE_URI in cwd
/path/to/ejfat_proxy/scripts/docker/run_proxy.sh

# Back-to-back mode — no LB required
B2B_MODE=true /path/to/ejfat_proxy/scripts/docker/run_proxy.sh
```

Key env vars:
| Variable | Default | Description |
|---|---|---|
| `B2B_MODE` | `false` | Use back-to-back config (no LB) |
| `PROXY_IMAGE` | `ejfat-zmq-proxy:latest` | Container image |
| `ZMQ_PORT` | `5555` | Output ZMQ PUSH port |
| `BUFFER_SIZE` | `200000` (b2b: `20000`) | Ring buffer size |

---

### `run_zmq_ejfat_bridge.sh`

Connects to a ZMQ sender and forwards events to EJFAT via E2SAR Segmenter.
Requires `INSTANCE_URI` in the working directory.

```bash
SENDER_NODE=<hostname> /path/to/ejfat_proxy/scripts/docker/run_zmq_ejfat_bridge.sh

# Two senders:
SENDER_NODE=host1 SENDER_NODE2=host2 \
    /path/to/ejfat_proxy/scripts/docker/run_zmq_ejfat_bridge.sh
```

Key env vars:
| Variable | Default | Description |
|---|---|---|
| `SENDER_NODE` | (required) | Hostname of ZMQ sender |
| `SENDER_ZMQ_PORT` | `5556` | Port on sender node |
| `SENDER_NODE2` | — | Optional second sender |
| `SENDER_ZMQ_PORT2` | `5557` | Port for second sender |
| `BRIDGE_DATA_ID` | `1` | E2SAR data ID |
| `BRIDGE_SRC_ID` | `2` | E2SAR source ID |
| `BRIDGE_LOG` | `bridge.log` | Log file |

---

### `run_pipeline_sender.sh`

Sends a fixed number of events over ZMQ PUSH.

```bash
/path/to/ejfat_proxy/scripts/docker/run_pipeline_sender.sh \
    --count 5000 --size 8192 --rate 1000
```

Key env vars:
| Variable | Default | Description |
|---|---|---|
| `SENDER_ZMQ_PORT` | `5556` | ZMQ PUSH bind port |
| `DELAY_BEFORE_SEND` | `5` | Seconds to wait before sending |
| `SENDER_LOG` | `sender.log` | Log file |

---

### `run_pipeline_validator.sh`

Receives events from the proxy and validates sequence numbers and checksums. Exits 0 on success.

```bash
PROXY_NODE=<hostname> /path/to/ejfat_proxy/scripts/docker/run_pipeline_validator.sh \
    --expected 5000 --timeout 60
```

Key env vars:
| Variable | Default | Description |
|---|---|---|
| `PROXY_NODE` | (required) | Hostname or IP of the proxy |
| `ZMQ_PORT` | `5555` | Proxy ZMQ output port |

---

### `run_consumer.sh`

Runs `scripts/test_receiver.py` locally (no container). Prints per-second stats.

```bash
PROXY_NODE=<hostname> /path/to/ejfat_proxy/scripts/docker/run_consumer.sh

# Backpressure testing — slow consumer:
PROXY_NODE=<hostname> /path/to/ejfat_proxy/scripts/docker/run_consumer.sh \
    --delay 10 --log-name slow_consumer
```

Key env vars:
| Variable | Default | Description |
|---|---|---|
| `PROXY_NODE` | (required) | Hostname or IP of the proxy |
| `ZMQ_PORT` | `5555` | Proxy ZMQ output port |

---

## Notes

- All scripts must be run from a **writable working directory** — config and log files are written there.
- The working directory is bind-mounted read-only into containers as `/job`. The `INSTANCE_URI` file must be in the same directory you run from.
- `container_runtime.sh` is sourced automatically; do not call it directly.
- To override the image: `PROXY_IMAGE=my-registry/ejfat-zmq-proxy:v2 ./run_proxy.sh`
