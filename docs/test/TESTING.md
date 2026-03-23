# EJFAT ZMQ Proxy Test Guide

This document describes every test in the suite and how to run it. Local tests (macOS, no Slurm) are covered first; Perlmutter-specific tests follow.

## Local Tests (no EJFAT infrastructure required)

Run these on any machine with the built binaries and Python 3 + pyzmq.

### Local B2B Backpressure Suite

Five backpressure tests on 127.0.0.1 without a load balancer (`use_cp: false`):

```bash
./scripts/local_b2b_test.sh [--tests 1,2,3,4,5] [--quick] [--soak-duration N]
```

| Test | Scenario |
|------|----------|
| 1 | Baseline — no backpressure |
| 2 | Mild BP — activates and recovers |
| 3 | Heavy BP — sustained saturation |
| 4 | Small-event stress (64KB) |
| 5 | Soak — 60s under moderate BP |

See `../user/LOCAL_TESTING.md` for full details.

### Local Pipeline Test (data integrity)

```bash
./scripts/local_pipeline_test.sh [--count N] [--size N] [--rate N]

# With multi-worker bridge
BRIDGE_WORKERS=4 BRIDGE_MTU=9000 ./scripts/local_pipeline_test.sh
```

Runs: `pipeline_sender.py` → `zmq_ejfat_bridge --no-cp` → proxy → `pipeline_validator.py`.
Pass/fail is the validator exit code (0=pass, 1=errors, 2=timeout).

---

## Perlmutter Prerequisites

```bash
# 1. Build and migrate the proxy container
podman-hpc build -t ejfat-zmq-proxy:latest .
podman-hpc migrate ejfat-zmq-proxy:latest

# 2. Set environment variables
export EJFAT_URI="ejfats://token@ejfat-lb.es.net:18008/lb/..."
export E2SAR_SCRIPTS_DIR="$PWD/scripts/perlmutter"
```

---

## Quick Start

Use `submit.sh` to submit any test:

```bash
# Normal end-to-end test
./scripts/perlmutter/submit.sh --account m5219 --test-type normal

# Single backpressure test
./scripts/perlmutter/submit.sh --account m5219 --test-type bp3

# All 6 backpressure tests (separate jobs)
./scripts/perlmutter/submit.sh --account m5219 --test-type backpressure-suite

# Pipeline data-integrity test
./scripts/perlmutter/submit.sh --account m5219 --test-type pipeline
```

Or submit directly with `sbatch`:

```bash
sbatch -A m5219 scripts/perlmutter/bp_test3.sh
```

## Test Types

### Normal Test (`--test-type normal`)

**Script**: `perlmutter_proxy_test.sh` | **Nodes**: 3 | **Time**: 30 min

Basic end-to-end test: sender pushes events through the EJFAT LB, the proxy
reassembles and forwards them to a ZMQ consumer.

| Component | Node | Role |
|-----------|------|------|
| Proxy | 0 | Receives from LB, pushes to ZMQ |
| Consumer | 1 | ZMQ PULL receiver (fast, no delay) |
| Sender | 2 | e2sar_perf sends events through LB |

**Sender options** (passed through):
- `--rate RATE` — Gbps (default: 1)
- `--num COUNT` — event count (default: 100)
- `--length LENGTH` — event size in bytes (default: 1048576)
- `--mtu MTU` — MTU (default: 9000)

**Success**: Consumer receives events, proxy log shows no drops.

### Backpressure Test (`--test-type backpressure`)

**Script**: `perlmutter_backpressure_test.sh` | **Nodes**: 3 | **Time**: 30 min

Same as normal test but the consumer adds an artificial delay (default 10ms per
message). This causes ZMQ send buffers to fill, the proxy ring buffer to fill,
and backpressure signals to be sent to the LB.

```bash
./scripts/perlmutter/submit.sh --account m5219 --test-type backpressure --consumer-delay 50
```

### Pipeline Test (`--test-type pipeline`)

**Script**: `perlmutter_pipeline_test.sh` | **Nodes**: 4 | **Time**: 30 min

Full end-to-end data integrity test with sequence number and checksum validation:

```
N1: pipeline_sender.py  --ZMQ-->  N2: zmq_ejfat_bridge  --EJFAT-->  N3: proxy  --ZMQ-->  N4: pipeline_validator.py
```

| Component | Node | Role |
|-----------|------|------|
| Sender | 0 | Sends sequence-numbered messages via ZMQ PUSH |
| Bridge | 1 | ZMQ PULL → E2SAR Segmenter → EJFAT LB |
| Proxy | 2 | LB → E2SAR Reassembler → ZMQ PUSH |
| Validator | 3 | ZMQ PULL, validates sequence and payload |

**Options** (passed through):
- `--count N` — messages to send (default: 1000)
- `--size N` — message size in bytes (default: 4096)
- `--rate N` — messages per second (default: 100)

**Bridge env vars** (control `zmq_ejfat_bridge`):
- `BRIDGE_WORKERS` — parallel ZMQ PULL worker threads (default: 1)
- `BRIDGE_SOCKETS` — E2SAR UDP send thread pool size (default: 1)
- `BRIDGE_MTU` — MTU in bytes (default: 1500 local / 9000 Perlmutter)

**Success**: Validator exits with code 0 (all messages received, in order, intact).

---

## Backpressure Test Suite

Six targeted tests, each submitted as a separate 3-node Slurm job with its own
LB reservation. Every test has explicit pass/fail assertions.

### Submitting

```bash
# All 6 tests (run in parallel by default)
./scripts/perlmutter/submit.sh --account m5219 --test-type backpressure-suite

# All 6 tests sequentially (each waits for the previous to finish)
./scripts/perlmutter/perlmutter_backpressure_suite.sh --account m5219 --sequential

# Specific tests only
./scripts/perlmutter/perlmutter_backpressure_suite.sh --account m5219 --tests 1,3,6

# Individual test
./scripts/perlmutter/submit.sh --account m5219 --test-type bp3
```

### Test 1: Baseline (no backpressure)

**Script**: `bp_test1.sh` | **Time**: 10 min

Verifies normal operation with a fast consumer and large buffers. No
backpressure should be triggered.

| Setting | Value |
|---------|-------|
| BUFFER_SIZE | 20000 |
| ZMQ_HWM | 10000 |
| Consumer delay | 0 |
| Sender | 100 events at 10 Gbps |

**Assertions**:
- No `ready=0` in proxy log (no backpressure)
- Buffer fill stayed below 10%
- 90-100 events received
- No crash

### Test 2: Mild Backpressure (activates and recovers)

**Script**: `bp_test2.sh` | **Time**: 10 min

Small buffer + slow consumer triggers backpressure, then recovers after the
sender stops.

| Setting | Value |
|---------|-------|
| BUFFER_SIZE | 100 |
| ZMQ_HWM | 5 |
| Consumer delay | 10ms, rcvhwm=2, rcvbuf=128KB |
| Sender | 30s soak at 10 Gbps |

**Assertions**:
- Backpressure triggered (`ready=0`)
- Backpressure recovered (`ready=1` after `ready=0`)
- Buffer fill peaked above 20%
- At least 70 events received
- No crash

### Test 3: Heavy Backpressure (sustained saturation)

**Script**: `bp_test3.sh` | **Time**: 10 min

Very slow consumer causes sustained backpressure for the entire send period.

| Setting | Value |
|---------|-------|
| BUFFER_SIZE | 100 |
| ZMQ_HWM | 5 |
| Consumer delay | 100ms, rcvhwm=2, rcvbuf=128KB |
| Sender | 200 events at 10 Gbps |

**Assertions**:
- Backpressure triggered
- Sustained for at least 3 consecutive reporting periods
- Buffer fill peaked above 80%
- Control signal peaked above 0.4
- No crash

### Test 4: Small-Event Stress (64KB events)

**Script**: `bp_test4.sh` | **Time**: 10 min

Tests backpressure with smaller 64KB events (vs the default 1MB). Verifies the
proxy handles different event sizes correctly under pressure.

| Setting | Value |
|---------|-------|
| BUFFER_SIZE | 100 |
| ZMQ_HWM | 5 |
| Consumer delay | 50ms, rcvhwm=2, rcvbuf=128KB |
| Sender | 100 events at 10 Gbps, 64KB each |

**Assertions**:
- Backpressure triggered
- Buffer fill peaked above 20%
- No crash

### Test 5: 5-Minute Soak (stability)

**Script**: `bp_test5.sh` | **Time**: 15 min

Long-duration test under moderate backpressure. Verifies the proxy doesn't
leak memory, crash, or deadlock over sustained operation.

| Setting | Value |
|---------|-------|
| BUFFER_SIZE | 200 |
| ZMQ_HWM | 10 |
| BP_THRESHOLD | 0.3 |
| Consumer delay | 20ms, rcvhwm=5, rcvbuf=128KB |
| Sender | 300s soak at 10 Gbps |

**Assertions**:
- Backpressure triggered
- Backpressure recovered
- Proxy coordinator alive at end of test
- No crash

### Test 6: Dual-Receiver Fairness

**Script**: `bp_test6.sh` | **Time**: 10 min

Two ZMQ PULL consumers connect to the proxy's single PUSH socket. ZMQ's
fair-queuing distributes events round-robin, but skips a consumer whose
receive buffers are full. This test verifies the fast consumer gets more
events than the slow one, and no events are lost.

| Setting | Value |
|---------|-------|
| BUFFER_SIZE | 200 |
| ZMQ_HWM | 5 |
| Consumer FAST | No delay, default buffers |
| Consumer SLOW | 100ms delay, rcvhwm=2, rcvbuf=128KB |
| Sender | 60s soak at 10 Gbps |

**Assertions**:
- Fast consumer received more events than slow consumer
- Total events received >= 100 (pipeline working)
- Both consumers received at least 1 event
- No crash

---

## Monitoring

```bash
# Job queue
squeue -u $USER

# Tail logs during a run
tail -f runs/slurm_job_<JOBID>/proxy.log
tail -f runs/slurm_job_<JOBID>/consumer.log
```

## Output

All logs are saved to `runs/slurm_job_<JOBID>/`:

| File | Contents |
|------|----------|
| `proxy.log` | Proxy stats: events received, fill level, backpressure state |
| `consumer.log` | Consumer stats: message count, throughput |
| `minimal_sender.log` | Sender output: events sent, rate achieved |
| `perlmutter_config.yaml` | Generated proxy configuration |
| `proxy_wrapper.log` | run_proxy.sh startup output |
| `consumer_wrapper.log` | run_consumer.sh startup output |
| `INSTANCE_URI` | LB reservation details |

BP suite tests archive per-test logs as `test1_proxy.log`, `test2_consumer.log`, etc.

Pipeline tests additionally produce `sender.log`, `bridge.log`, and `validator.log`.

## Cleanup

Tests automatically free LB reservations and stop all processes via an EXIT
trap. If a job is cancelled unexpectedly:

```bash
cd runs/slurm_job_<JOBID>
../../scripts/perlmutter/minimal_free.sh
```

## Adding a New Test

1. Create `scripts/perlmutter/bp_testN.sh` (use an existing one as template).
2. Source `bp_common.sh` and call `bp_setup_env`, `bp_reserve_lb`, `start_coordinator`.
3. Use `start_proxy 1 "CONFIG_VARS..."` — always test number 1 (coordinator gets `NUM_TESTS=1`).
4. Run assertions, call `bp_print_summary`.
5. Add the test number to `submit.sh` and `perlmutter_backpressure_suite.sh`.
