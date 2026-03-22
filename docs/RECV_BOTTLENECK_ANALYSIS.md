# Receiver Throughput Analysis: 282 events/s was a measurement artifact

## Summary

The full proxy pipeline appeared to deliver only **282 events/s**, while E2SAR alone achieves ~72K events/s on macOS loopback. After extensive investigation, the "bottleneck" turned out to be a **measurement artifact** in the validator's rate calculation.

**Actual end-to-end throughput: ~91,000 msg/s** (1000 events in 11ms).

## Pipeline architecture

```
pipeline_sender  (ZMQ PUSH :5556)
    |
    v
zmq_ejfat_bridge (ZMQ PULL -> E2SAR Segmenter -> UDP fragments)
    |
    v  (UDP loopback :19522)
    |
ejfat_zmq_proxy  (E2SAR Reassembler -> ring buffer -> ZMQ PUSH :5555)
    |
    v
pipeline_validator (ZMQ PULL)
```

## Root cause of the misleading measurement

The validator measured `Duration = last_message_time - program_start_time`. The test script starts the validator **~3.4s before data arrives** (validator starts in Phase 2; bridge+sender start in Phases 3-4). So `Duration ≈ 3.5s` includes 3.4s of idle startup wait.

When measuring from **first message to last message** at the validator:

```
First-to-last span: 0.011s
Burst rate        : 91,175 msg/s
```

The proxy's own timing confirms this:

```
=== getEvent() timing diagnostics ===
  Event span ms : 11
  Event rate    : 90909 evt/s
```

## Component-level timing

| Component | Metric | Value |
|---|---|---|
| Bridge `addToSendQueue()` | All 1000 events sent | 12ms (83K evt/s) |
| E2SAR recv thread | 3000 fragments reassembled | ~11ms |
| Proxy `getEvent()` | Avg dequeue latency | 0µs |
| Ring buffer push | Overhead | negligible |
| ZMQ PUSH → PULL | All 1000 messages delivered | ~11ms |
| **End-to-end** | **First to last event** | **11ms (91K msg/s)** |

## Hypotheses investigated and ruled out

| Hypothesis | Test | Result |
|---|---|---|
| `recvEvent()` CV lost-wakeup race | Switched to `getEvent()` + polling | Same "282/s" (measurement artifact) |
| UDP socket recv buffer overflow | 3MB → 7MB | No change |
| Insufficient recv threads | 1 → 4 threads | No change |
| ZMQ sender blocking | Checked blocked send ratio | 0% blocked |
| Ring buffer backpressure | Checked fill level | Always 0% |
| Bridge send throughput | Instrumented timing | 83K evt/s (not bottleneck) |
| E2SAR recv thread slow | `reassembler_bench` standalone | 85K evt/s (not bottleneck) |
| Proxy thread interference | Disabled sender/monitor | No change (all fast) |

## E2SAR `recvEvent()` lost-wakeup race (real bug, not the bottleneck)

E2SAR's `recvEvent()` has a lost-wakeup race: `notify_all()` is called without holding `recvThreadMtx`, so notifications can fire between `dequeue()` returning empty and `wait_for()` starting. This causes unnecessary 10ms stalls when events arrive one-at-a-time (e.g., bridge's synchronous `sendEvent()`). The race doesn't affect burst workloads where the queue is always non-empty.

**Proper fix** (if needed for latency-sensitive use cases):
1. `enqueue()`: add `{ lock_guard<mutex> lk(recvThreadMtx); }` between push and notify
2. `recvEvent()`: move `dequeue()` inside the locked region

The proxy currently uses `getEvent()` + 50µs polling, which avoids the race entirely.

## Fix applied to validator

Added `First-to-last span` and `Burst rate` metrics to `pipeline_validator.cpp` to measure actual message delivery rate independent of startup timing.

## Subsequent bridge refactor (March 22, 2026)

The bridge was later refactored from single-threaded `sendEvent()` to N-worker `addToSendQueue()` (see commit history). The analysis findings remain valid — the measurement artifact was the bottleneck, not the send path. The new bridge design improves throughput further: 4 workers + 4 sockets achieved ~11.5 Gbps (22K msg/s × 64KB events) on macOS loopback.
