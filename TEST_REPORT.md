# EJFAT ZMQ Proxy - Test Report

## Test Summary

**Last updated**: March 22, 2026

| Test | Status | Date |
|------|--------|------|
| Build (macOS, native) | ✅ PASSED | Mar 16 |
| Build (container, Perlmutter) | ✅ PASSED | Mar 16 |
| ZMQ component (PUSH/PULL) | ✅ PASSED | Mar 16 |
| E2SAR → Proxy → ZMQ (back-to-back) | ✅ PASSED | Mar 18 |
| Full pipeline (ZMQ → bridge → EJFAT → proxy → ZMQ) | ✅ PASSED | Mar 22 |
| Local B2B backpressure suite (5 tests) | ✅ PASSED | Mar 21 |
| Perlmutter backpressure suite (6 tests) | ✅ PASSED | Mar 21 |
| Multi-worker bridge (4 workers, 4 sockets) | ✅ PASSED | Mar 22 |

---

## 1. Build Verification

### macOS (native)

✅ **PASSED** — `ejfat_zmq_proxy` and `zmq_ejfat_bridge` compile successfully.

```
build/bin/ejfat_zmq_proxy    (1.9 MB)
build/bin/zmq_ejfat_bridge
build/bin/reassembler_bench
```

Dependencies: E2SAR v0.3.1, Boost 1.89 (conda), ZMQ 4.3.5 (Homebrew), gRPC 1.78 (conda).

### Container (Perlmutter)

✅ **PASSED** — Containerfile based on `docker.io/ibaldin/e2sar:0.3.1`. See `BUILD_NOTES.md`
for the full dependency map and the linker-ordering fix that was required.

---

## 2. ZMQ Component Test

**Date**: March 16, 2026

Direct Python PUSH → PULL test (no E2SAR):

| Metric | Value |
|--------|-------|
| Messages sent | 2,985 |
| Messages received | 2,985 |
| Delivery | 100% |
| Throughput | ~300–400 msg/s |
| Bandwidth | 0.29 MB/s |
| Message size | 1024 bytes |

✅ Zero packet loss. Clean shutdown via SIGTERM.

---

## 3. E2SAR → Proxy → ZMQ (Back-to-Back)

**Date**: March 18, 2026

`e2sar_perf` (sender, UDP :19522) → `ejfat_zmq_proxy` (no CP) → `test_receiver.py` (ZMQ PULL :5555).

| Metric | Value |
|--------|-------|
| Events sent | 750 |
| Events received | 750 |
| Drops | 0 |
| Errors | 0 |

✅ PASSED — end-to-end delivery with zero loss.

**Bugs fixed** to get this test passing:

1. **`recvEvent()` timeout check inverted** (`src/proxy.cpp:153`): `value()==0` means SUCCESS
   in the E2SAR API; the code had the sense backwards, skipping real events and processing
   timeouts as 0-byte messages.
2. **`openAndStart()` never called** (`src/proxy.cpp:start()`): UDP sockets were never opened,
   so no packets could be received.

---

## 4. Full Pipeline Test

**Date**: March 22, 2026

`pipeline_sender.py` (ZMQ PUSH :5556) → `zmq_ejfat_bridge --no-cp` → UDP :19522 → `ejfat_zmq_proxy` → `pipeline_validator.py` (ZMQ PULL :5555).

| Metric | Value |
|--------|-------|
| Events sent | 1,000 |
| Events received | 1,000 |
| Sequence errors | 0 |
| Payload errors | 0 |
| First-to-last span | 11 ms |
| Burst rate | ~91,000 msg/s |

✅ PASSED — all events delivered in order with correct payloads.

**Note on 282 msg/s measurement artifact**: an earlier measurement appeared to show only 282 msg/s
end-to-end. This was because the validator measured duration from program start, not from first
message arrival. The validator started ~3.4s before data arrived. Actual burst throughput is ~91K
msg/s. See `docs/RECV_BOTTLENECK_ANALYSIS.md` for the full analysis.

---

## 5. Multi-Worker Bridge

**Date**: March 22, 2026

`zmq_ejfat_bridge --workers 4 --sockets 4 --mtu 9000` on localhost with 64KB events.

| Metric | Value |
|--------|-------|
| Throughput | ~22,000 msg/s |
| Bandwidth | ~11.5 Gbps |
| Missing events | 0 |
| Reassembly loss | 0 |

✅ PASSED. (25K+ msg/s exceeds macOS `kern.ipc.maxsockbuf=8MB`; higher rates expected on Perlmutter.)

The bridge uses `addToSendQueue()` (non-blocking) with heap-copied buffers freed via `freeEventBuffer()` callback after E2SAR's thread pool transmits them. All workers share one Segmenter (single `data_id`/`src_id`), eliminating reassembly confusion.

---

## 6. Local B2B Backpressure Suite

**Date**: March 21, 2026

`scripts/local_b2b_test.sh` runs 5 backpressure tests on 127.0.0.1 without a load balancer
(`use_cp: false`, `with_lb_header: true`). Uses `e2sar_perf` as sender, `ejfat_zmq_proxy` as
receiver, `test_receiver.py` as consumer.

| Test | Scenario | Result |
|------|----------|--------|
| 1 | Baseline — no backpressure, large buffers | ✅ |
| 2 | Mild BP — activates and recovers | ✅ |
| 3 | Heavy BP — sustained saturation | ✅ |
| 4 | Small-event stress (64KB) | ✅ |
| 5 | 5-min soak — stability under moderate BP | ✅ |

All assertions passed. B2B mode uses fill-level thresholds for assertions (no LB `control=` signal).

---

## 7. Perlmutter Backpressure Suite (LB Mode)

**Date**: March 21, 2026

`scripts/perlmutter/perlmutter_backpressure_suite.sh` submits 6 separate 3-node Slurm jobs,
each with its own LB reservation. Uses `e2sar_perf` as sender, proxy as receiver, `test_receiver.py`
as consumer.

| Test | Scenario | Result |
|------|----------|--------|
| 1 | Baseline — no backpressure | ✅ |
| 2 | Mild BP — activates and recovers | ✅ |
| 3 | Heavy BP — sustained saturation | ✅ |
| 4 | Small-event stress (64KB) | ✅ |
| 5 | 5-min soak — stability | ✅ |
| 6 | Dual-receiver fairness (fast + slow consumer) | ✅ |

---

## 8. Test Scripts

| Script | Description |
|--------|-------------|
| `scripts/test_receiver.py` | ZMQ PULL consumer with optional delay and stats |
| `scripts/test_sender.py` | ZMQ PUSH producer for component-level testing |
| `scripts/pipeline_sender.py` | Sends sequence-numbered, checksummed messages |
| `scripts/pipeline_validator.py` | Validates sequence, checksum, burst rate |
| `scripts/local_b2b_test.sh` | 5-test B2B backpressure suite (macOS, no Slurm) |
| `scripts/local_pipeline_test.sh` | Pipeline data-integrity test (macOS, no Slurm) |
| `bin/reassembler_bench.cpp` | Standalone E2SAR reassembler throughput benchmark |

---

## 9. Performance Summary

| Benchmark | Throughput | Notes |
|-----------|-----------|-------|
| ZMQ PUSH/PULL (Python) | 300–400 msg/s | Python overhead; baseline only |
| E2SAR reassembler (standalone) | ~85,000 evt/s | macOS loopback, 3KB events |
| Bridge `addToSendQueue` | ~83,000 evt/s | 4 workers, 9000 MTU, 64KB events |
| End-to-end pipeline | ~91,000 evt/s | first-to-last span, burst mode |
| Multi-worker bridge (net) | ~11.5 Gbps | 22K msg/s × 64KB |

---

## 10. Testing Checklist

### Component Tests
- [x] Build succeeds (macOS and container)
- [x] ZMQ PUSH/PULL communication
- [x] Message delivery (100% success rate)
- [x] Configuration parsing (all 39 parameters)
- [x] Backpressure PID controller
- [x] Ring buffer fill and overflow detection

### Integration Tests
- [x] E2SAR receiver → ring buffer → ZMQ sender
- [x] ZMQ → bridge → E2SAR → proxy → ZMQ (pipeline)
- [x] Backpressure feedback loop (LB mode)
- [x] Multi-consumer fairness (Test 6)
- [x] B2B mode (no LB)

### System Tests
- [x] End-to-end with real EJFAT load balancer (Perlmutter)
- [x] 5-minute sustained operation under backpressure
- [x] Multi-worker parallel send (4 workers, 11.5 Gbps)
- [ ] Multi-day sustained operation
- [ ] Failure recovery (LB restart, network interruption)
