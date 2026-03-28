# EJFAT ZMQ Proxy - Local Testing Guide

## Overview

All tests below run entirely on localhost (127.0.0.1) without a real EJFAT load balancer or control plane. Useful for:

- Development and debugging
- Validating E2SAR reassembly and ZMQ pipeline
- Backpressure logic testing
- Data-integrity / regression testing

## Configuration

Local testing uses `config/local_test.yaml` or generates a config on the fly via `config/distributed.yaml.template`.

Key settings for local mode:

```yaml
ejfat:
  uri: "ejfat://local-test@127.0.0.1:9876/lb/1?data=127.0.0.1:19522&sync=127.0.0.1:19523"
  use_cp: false           # Disable gRPC control plane
  with_lb_header: true    # Expect LB headers (added by segmenter, not stripped by real LB)
  data_ip: "127.0.0.1"   # macOS requires explicit IP
  data_port: 19522

zmq:
  push_endpoint: "tcp://*:5555"
  send_hwm: 100

buffer:
  size: 500
```

### Key settings explained

- **`use_cp: false`** — disables all gRPC communication; no LB registration, no sendState calls
- **`with_lb_header: true`** — tells the E2SAR Reassembler to expect and process LB headers that were added by the Segmenter (normally stripped by the real LB)
- **`data_ip: "127.0.0.1"`** — required on macOS; auto-detection is not supported

---

## Test Options

### Option 1: Manual component-by-component

Start each component in its own terminal.

**Terminal 1 — Proxy:**
```bash
./build/bin/ejfat_zmq_proxy -c config/local_test.yaml --stats-interval 2
```

Expected output:
```
All components started
Receiver thread started
Monitor #1: fill=0%
```

**Terminal 2 — ZMQ consumer:**
```bash
python3 -u scripts/test_receiver.py --endpoint tcp://localhost:5555
```

**Terminal 3 — Sender (`e2sar_perf`):**
```bash
/path/to/e2sar/build/bin/e2sar_perf \
  --send \
  --ip 127.0.0.1 \
  --port 19522 \
  --rate -1 \
  --num 100 \
  --withcp false
```

---

### Option 2: Local B2B Backpressure Suite

Runs 5 backpressure tests automatically. Uses `e2sar_perf` as sender and `test_receiver.py` as consumer.

```bash
cd /path/to/ejfat_proxy
./scripts/local_b2b_test.sh

# Run specific tests only
./scripts/local_b2b_test.sh --tests 1,3

# Quick mode (shorter timeouts)
./scripts/local_b2b_test.sh --quick

# Longer soak for Test 5
./scripts/local_b2b_test.sh --soak-duration 120
```

| Test | Scenario | What it validates |
|------|----------|-------------------|
| 1 | Baseline — large buffers, fast consumer | No backpressure triggered; fill stays low |
| 2 | Mild BP — small buffers + slow consumer | BP activates and recovers |
| 3 | Heavy BP — very slow consumer | Sustained saturation, fill peaks >80% |
| 4 | Small-event stress (64KB) | Correct handling of small events under pressure |
| 5 | Soak — moderate BP for 60s | Stability, no memory leak or deadlock |

B2B mode assertions check buffer fill-level thresholds (no LB `control=` signal, since CP is disabled).

---

### Option 3: Local Pipeline Test (data-integrity)

Full end-to-end pipeline: `pipeline_sender.py` → `zmq_ejfat_bridge --no-cp` → UDP → `ejfat_zmq_proxy` → `pipeline_validator.py`. Validates sequence numbers and checksums.

```bash
./scripts/local_pipeline_test.sh

# Custom parameters
./scripts/local_pipeline_test.sh --count 2000 --size 8192

# With multi-worker bridge (BRIDGE_WORKERS env var)
BRIDGE_WORKERS=4 BRIDGE_MTU=9000 ./scripts/local_pipeline_test.sh

# Env vars available
BRIDGE_WORKERS=1       # ZMQ PULL worker threads in bridge (default: 1)
BRIDGE_SOCKETS=1       # E2SAR UDP send sockets (default: 1)
BRIDGE_MTU=1500        # MTU (default: 1500)
RECV_THREADS=1         # E2SAR receiver threads in proxy (default: 1)
RCV_BUF_SIZE=3145728   # UDP socket receive buffer in bytes (default: 3 MB)
```

Pipeline topology:
```
pipeline_sender.py (ZMQ PUSH :5556)
    |
    v
zmq_ejfat_bridge --no-cp (ZMQ PULL -> E2SAR Segmenter -> UDP :19522)
    |
    v
ejfat_zmq_proxy (E2SAR Reassembler -> ring buffer -> ZMQ PUSH :5555)
    |
    v
pipeline_validator.py (ZMQ PULL)
```

Pass/fail is determined by the validator exit code (0=PASS, 1=errors, 2=timeout).

---

## zmq_ejfat_bridge — Local Usage

The bridge has a `--no-cp` flag for local and B2B testing. Configuration can be
provided via CLI flags or via a YAML config file (`--config/-c`, using the `bridge:`
key as documented in `config/default_bridge.yaml`). CLI flags override YAML values.

```bash
./build/bin/zmq_ejfat_bridge \
  --uri "ejfat://local@127.0.0.1:9876/lb/1?data=127.0.0.1:19522&sync=127.0.0.1:19523" \
  --zmq-endpoint tcp://localhost:5556 \
  --mtu 1500 \
  --sockets 1 \
  --workers 1 \
  --no-cp
```

Or via config file:

```bash
./build/bin/zmq_ejfat_bridge --config config/default_bridge.yaml --no-cp
```

- **`--no-cp`**: disables gRPC LB registration and sync packets
- **`--config/-c`**: load all options from a YAML file (CLI flags override)
- **`--workers N`**: N parallel ZMQ PULL threads, each with its own socket (default: 1)
- **`--sockets N`**: E2SAR internal UDP send thread pool size (default: 16; use 1 for local)

---

## What Works in Local Mode

✅ **E2SAR reassembly** — receives UDP, reassembles events, writes to ring buffer
✅ **Ring buffer** — lock-free SPSC queue, fill-level monitoring, overflow detection
✅ **ZMQ output** — PUSH socket to consumers, HWM backpressure
✅ **Backpressure monitoring** — PID computation and fill-level logging (no sendState to LB)
✅ **zmq_ejfat_bridge** — ZMQ→EJFAT segmentation, single or multi-worker
✅ **Pipeline validator** — sequence + checksum verification, burst rate metrics

## What Doesn't Work in Local Mode

❌ **Control plane** — no gRPC, no worker registration, no sendState, no dynamic slot assignment
❌ **Load distribution** — no LB coordination; data goes directly to the proxy's IP:port

---

## Monitoring

### Proxy stats

```
=== Proxy Statistics ===
Events received:  1000
Events dropped:   0
Buffer fill:      0.0%
Buffer size:      0 / 500
ZMQ sends:        1000
ZMQ blocked:      0 (0.0%)
Last fill%:       0.0%
Last control:     0.000
========================
```

### Backpressure monitor (CP disabled)

```
Monitor #1:  fill=0%
Monitor #51: fill=9.4%
```

No sendState calls are made.

### Bridge stats (at shutdown)

```
=== Bridge Statistics ===
Workers                   : 1
Events received from ZMQ  : 1000
Events enqueued to E2SAR  : 1000
Events dropped (q full)   : 0
Segmenter fragments sent  : 3000
Segmenter send errors     : 0
=========================
```

---

## Troubleshooting

### No events received

- Verify `data_ip: "127.0.0.1"` in proxy config (required on macOS)
- Confirm E2SAR sender is targeting 127.0.0.1:19522
- Ensure proxy `use_cp: false` and `with_lb_header: true` match the sender's settings

### "Capability to determine outgoing address not supported"

- Fixed by setting explicit `data_ip: "127.0.0.1"` in the YAML config

### ZMQ blocked / buffer fill climbing

- Normal if no ZMQ consumer is connected
- Start `test_receiver.py` to consume events

### Bridge events dropped

- Increase `--sockets` (more E2SAR UDP threads)
- Or reduce send rate / event count

---

## Local vs Production Comparison

| Feature | Local (`use_cp: false`) | Production (`use_cp: true`) |
|---------|------------------------|----------------------------|
| Control plane | Disabled | Enabled via gRPC |
| Load balancer | None | Required |
| Worker registration | Skipped | Required |
| sendState | Disabled | Every 100ms |
| LB headers | Passed through (`with_lb_header: true`) | Stripped by LB |
| Data source | Direct UDP to local IP:port | LB distributes packets |
| Multi-worker proxy | Not applicable | Yes (via LB weight) |

After validating locally:
1. Update URI with real EJFAT credentials
2. Enable CP (`use_cp: true`)
3. Set `with_lb_header: false`
4. Set `worker_name` for identification
5. Test with real load balancer (see `../test/TESTING.md`)
