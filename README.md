# EJFAT ZMQ Proxy

A high-performance proxy that bridges E2SAR (EJFAT) receivers with ZeroMQ consumers, providing end-to-end flow control through backpressure feedback to the EJFAT load balancer.

## Architecture

### LB Mode (production)

```
e2sar_perf ──UDP──▶ EJFAT LB ──UDP──▶ ejfat_zmq_proxy ──ZMQ──▶ consumer(s)
                        ▲                      │
                        └────── sendState ──────┘  (backpressure)
```

### Pipeline Mode (ZMQ source → EJFAT → ZMQ sink)

```
pipeline_sender ──ZMQ──▶ zmq_ejfat_bridge ──UDP──▶ [LB] ──UDP──▶ ejfat_zmq_proxy ──ZMQ──▶ pipeline_validator
```

The bridge (N parallel ZMQ PULL workers) enqueues events into a single shared E2SAR Segmenter via `addToSendQueue()`. The LB is optional — use `--no-cp` on the bridge and `use_cp: false` in the proxy config for back-to-back local testing.

## Components

- **`ejfat_zmq_proxy`**: Main proxy. Runs E2SAR Reassembler → lock-free ring buffer → ZMQ PUSH.
- **`zmq_ejfat_bridge`**: Reverse bridge. ZMQ PULL → E2SAR Segmenter → UDP (for pipeline tests).
- **EventRingBuffer**: Lock-free SPSC queue between E2SAR receiver and ZMQ sender threads.
- **ZmqSender**: ZMQ PUSH socket with configurable high-water mark.
- **BackpressureMonitor**: PID-controlled feedback to the EJFAT load balancer.

## Dependencies

- **E2SAR** (e2sar) — EJFAT data plane and control plane libraries (v0.3.1)
- **Boost** (≥1.74) — thread, chrono, lockfree, program_options
- **ZeroMQ** (≥4.3) — libzmq and cppzmq
- **yaml-cpp** — YAML configuration parsing
- **CMake** (≥3.15) — build system

## Building

```bash
mkdir build && cd build
PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:/opt/anaconda3/envs/e2sar-dev/lib/pkgconfig" \
cmake .. \
  -DE2SAR_ROOT=/path/to/e2sar \
  -DE2SAR_LIB_PATH=/path/to/e2sar/build/src/libe2sar.a
make -j8
```

`-DE2SAR_ROOT` and `-DE2SAR_LIB_PATH` are required to point at the correct E2SAR build. See `BUILD_NOTES.md` for container builds on Perlmutter.

Binaries are written to `build/bin/`.

## Configuration

Create a YAML configuration file (see `config/default.yaml` for the full 39-parameter schema):

```yaml
ejfat:
  uri: "ejfats://token@lb.example.net:443/lb/session?data=192.168.1.100&sync=192.168.1.100:19522"
  use_cp: true
  worker_name: "zmq-proxy-1"
  data_port: 10000

zmq:
  push_endpoint: "tcp://*:5555"
  send_hwm: 1000

backpressure:
  period_ms: 100
  pid:
    setpoint: 0.5
    kp: 1.0
    ki: 0.0
    kd: 0.0

buffer:
  size: 2000
  recv_timeout_ms: 100
```

## Running

### ejfat_zmq_proxy

```bash
# With config file
./build/bin/ejfat_zmq_proxy -c config/myconfig.yaml

# With command-line overrides
./build/bin/ejfat_zmq_proxy -c config/default.yaml --stats-interval 5

# Show help
./build/bin/ejfat_zmq_proxy --help
```

### zmq_ejfat_bridge

```bash
# Single worker (default)
./build/bin/zmq_ejfat_bridge --uri "ejfats://..." --zmq-endpoint tcp://sender:5556

# 4 parallel workers, no control plane (local/B2B testing)
./build/bin/zmq_ejfat_bridge \
  --uri "ejfat://dummy@127.0.0.1:9876/lb/1?data=127.0.0.1:19522&sync=127.0.0.1:19523" \
  --zmq-endpoint tcp://localhost:5556 \
  --workers 4 \
  --mtu 9000 \
  --sockets 8 \
  --no-cp

# Show help
./build/bin/zmq_ejfat_bridge --help
```

Key bridge options:

| Option | Default | Description |
|--------|---------|-------------|
| `--workers N` | 1 | Parallel ZMQ PULL receiver threads (each owns its own socket) |
| `--sockets N` | 16 | E2SAR internal UDP send thread pool size |
| `--mtu N` | 9000 | MTU in bytes |
| `--rcvhwm N` | 10000 | ZMQ receive HWM (per worker socket) |
| `--no-cp` | off | Disable LB control plane (B2B / local testing) |
| `--multiport` | off | Use consecutive destination ports for B2B multi-thread testing |

## Local Quick Tests (no EJFAT infrastructure)

```bash
# 5-test backpressure suite (B2B, no LB)
./scripts/local_b2b_test.sh

# Pipeline data-integrity test
./scripts/local_pipeline_test.sh

# Options
./scripts/local_b2b_test.sh --tests 1,3 --quick
./scripts/local_pipeline_test.sh --count 2000 --size 8192
./scripts/local_pipeline_test.sh BRIDGE_WORKERS=4 BRIDGE_MTU=9000 ./scripts/local_pipeline_test.sh
```

Both scripts run entirely on localhost (127.0.0.1) and require only the built binaries and Python 3 with pyzmq.

## Testing on Perlmutter

See [docs/TESTING.md](docs/TESTING.md) for the full test guide. Quick start:

```bash
export EJFAT_URI="ejfats://token@ejfat-lb.es.net:18008/lb/..."
export E2SAR_SCRIPTS_DIR="$PWD/scripts/perlmutter"

# Normal end-to-end test (3 nodes)
./scripts/perlmutter/submit.sh --account m5219 --test-type normal

# Backpressure test suite (6 tests, LB mode)
./scripts/perlmutter/submit.sh --account m5219 --test-type backpressure-suite

# Backpressure test suite (5 tests, B2B / no LB)
./scripts/perlmutter/b2b_backpressure_suite.sh --account m5219

# Pipeline data-integrity test (4 nodes)
./scripts/perlmutter/submit.sh --account m5219 --test-type pipeline
```

## User Guide

See [docs/USER_GUIDE.md](docs/USER_GUIDE.md) for a step-by-step guide to running senders, the proxy, bridge, and ZMQ consumers manually on Perlmutter.

## Key Configuration Parameters

### ZMQ High-Water Mark (`zmq.send_hwm`)

Controls when ZMQ starts blocking sends. Lower values trigger backpressure earlier but may reduce throughput. Typical values: 100–10000.

### Buffer Size (`buffer.size`)

Internal ring buffer capacity. Should be larger than `send_hwm` to absorb bursts. Typical values: 1000–20000.

### PID Setpoint (`backpressure.pid.setpoint`)

Target buffer fill level (0.0–1.0). Default 0.5 (50%) provides headroom for bursts while maintaining low latency.

### Ready Threshold (`backpressure.ready_threshold`)

Buffer fill fraction at which the proxy signals `ready=0` (stop sending). Default 0.95.

### PID Gains

- `kp`: Proportional gain — immediate response to fill level deviation
- `ki`: Integral gain — corrects steady-state error (usually 0)
- `kd`: Derivative gain — dampens oscillations (usually 0)

Start with `kp=1.0, ki=0.0, kd=0.0` and tune based on observed behavior.

## Monitoring

The proxy prints statistics at configurable intervals:

```
=== Proxy Statistics ===
Events received:  145230
Events dropped:   0
Buffer fill:      48.2%
Buffer size:      964 / 2000
ZMQ sends:        145230
ZMQ blocked:      23 (0.0%)
Last fill%:       48.2%
Last control:     0.484
========================
```

- **Events dropped**: Should be 0 — indicates buffer overflow
- **Buffer fill**: Current queue utilization
- **ZMQ blocked**: Percentage of sends hitting the high-water mark
- **Last control**: PID control signal (0.0–1.0) sent to LB

The bridge prints aggregate stats at shutdown:

```
=== Bridge Statistics ===
Workers                   : 4
Events received from ZMQ  : 1000
Events enqueued to E2SAR  : 1000
Events dropped (q full)   : 0
Segmenter fragments sent  : 3000
Segmenter send errors     : 0
=========================
```

## Troubleshooting

### Events being dropped (proxy)

- Increase `buffer.size`
- Reduce data rate at source
- Check consumer performance

### High ZMQ blocked percentage

- Consumer is slower than producer
- Check consumer for bottlenecks
- Verify backpressure is reaching load balancer

### Control signal stuck at 0 or 1

- Tune PID gains
- Check if buffer size is appropriate
- Verify `send_hwm` is set correctly

### Bridge events dropped (send queue full)

- Increase `--sockets` (more E2SAR UDP send threads)
- Reduce `--workers` relative to `--sockets`
- Check network MTU — larger MTU means fewer fragments per event

## License

See LICENSE file for details.
