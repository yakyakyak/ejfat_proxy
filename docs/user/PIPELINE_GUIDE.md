# EJFAT ZMQ Pipeline Guide

## Architecture

### Full Pipeline (Linear View)

```
ZMQ Source  ──────ZMQ──────▶  zmq_ejfat_bridge  ──────────────┐
(PUSH, bind :5556)            (PULL, connect :5556)           │ UDP
                                                              │ :19522
                                                          EJFAT LB
                                                        (data plane)
                                                              │ UDP
                                                              ▼
ZMQ Consumer  ◀──────ZMQ──────  ejfat_zmq_proxy  ◀────────────┘
(PULL, connect :5555)           (PUSH, bind :5555)
```

### Expanded Architecture (with Control Plane)

**Transmit Path**

```
┌──────────────┐     ┌────────────────────────┐      ┌──────────────┐
│        ZMQ-1─┼────►│ ZMQ-1──►               │      │   EJFAT LB   │
│ application  │     │    zmq|ejfat bridge    ├─UDP─►│  Data Plane  │
│        ZMQ-2─┼────►│ ZMQ-2──►               │      │              │
└──────────────┘     └────────────────────────┘      └──────────────┘
                          (ZMQ push/pull)
```

**Receive Path**

```
┌──────────────┐      ┌────────────────┐      ┌─────────────────┐
│   EJFAT LB   ├─UDP─►│  ejfat|zmq     ├─ZMQ─►│   consumer A    │
│  Data Plane  │      │  proxy         │      └─────────────────┘
│              │      │                ├─ZMQ─►┌─────────────────┐
└──────────────┘      └────────┬───────┘      │   consumer B    │
                               │              └─────────────────┘
                               │ fill level
                               │ (→ rebalances
                               │   sender rate)
                               ▼
                      ┌────────────────┐
                      │   EJFAT LB     │
                      │  Control Plane │
                      └────────────────┘
```

The pipeline is **byte-transparent**: the exact bytes your ZMQ source sends are the bytes your ZMQ consumer receives, with no framing or metadata added by the pipeline.

---

## Overview

`zmq_ejfat_bridge` pulls messages from your ZMQ source, fragments them into UDP via the E2SAR Segmenter, and sends them through the EJFAT load balancer. `ejfat_zmq_proxy` receives the UDP fragments, reassembles them via the E2SAR Reassembler, and pushes complete events to your ZMQ consumer. The proxy monitors its internal buffer fill level and sends backpressure signals to the load balancer, which throttles the sender when consumers fall behind. For local development and testing, the pipeline also works in back-to-back mode (no real LB) using `--no-cp`.

---

## Components

| Component | Binary | Role | Input | Output |
|-----------|--------|------|-------|--------|
| **ZMQ Source** | user-provided | Produces data | application | ZMQ PUSH, binds (`:5556`) |
| **zmq_ejfat_bridge** | `build/bin/zmq_ejfat_bridge` | ZMQ-to-UDP bridge | ZMQ PULL, connects to source | UDP via E2SAR Segmenter |
| **EJFAT Load Balancer** | infrastructure | Distributes UDP to receivers | UDP from bridge | UDP to proxy |
| **ejfat_zmq_proxy** | `build/bin/ejfat_zmq_proxy` | UDP-to-ZMQ proxy | UDP via E2SAR Reassembler | ZMQ PUSH, binds (`:5555`) |
| **ZMQ Consumer** | user-provided | Consumes data | ZMQ PULL, connects to proxy | application |

---

## Data Flow

Here is the journey of a single message from source to consumer:

1. **Source sends** — Your application calls `send()` on a ZMQ PUSH socket bound to `tcp://*:5556`. ZMQ distributes messages round-robin to all connected PULL sockets (one per bridge worker).

2. **Bridge receives** — A `zmq_ejfat_bridge` worker thread receives the message on its ZMQ PULL socket. It heap-copies the payload buffer (ZMQ message lifetime ends at scope exit) and enqueues it via `Segmenter::addToSendQueue()`, which is thread-safe and non-blocking.

3. **E2SAR segments** — The Segmenter's internal thread pool fragments the event into MTU-sized UDP packets, prepends LB/RE headers, and sends them to the EJFAT load balancer address configured in the URI.

4. **LB routes** — The EJFAT load balancer receives UDP fragments and forwards them to a registered receiver (the proxy). In back-to-back mode (`--no-cp`), this step is skipped and UDP goes directly from bridge to proxy.

5. **Proxy reassembles** — `ejfat_zmq_proxy` runs an E2SAR Reassembler that collects UDP fragments and produces a complete event buffer — byte-identical to the original ZMQ message.

6. **Ring buffer** — The reassembled event is moved (zero-copy pointer transfer) into a lock-free SPSC ring buffer (`EventRingBuffer`).

7. **ZMQ sender** — A dedicated sender thread pops events from the ring buffer and wraps each one in a `zmq::message_t` using zero-copy semantics (the E2SAR buffer pointer is transferred directly, freed by ZMQ after delivery). The event is sent on the PUSH socket.

8. **Consumer receives** — Your consumer's ZMQ PULL socket receives the message. The bytes are identical to what the source originally sent.

**Key properties:**
- **Byte transparency** — No headers, framing, or metadata are added or stripped by the pipeline. One ZMQ message in = one ZMQ message out.
- **No ordering guarantee** — Multi-threaded bridge workers and LB routing mean events can arrive out of order at the consumer. Embed a sequence number in your payload if ordering matters.
- **No metadata forwarded** — The E2SAR event number and data ID are internal to the pipeline and are not included in the ZMQ output message.
- **Never drops at proxy output** — The proxy ZMQ sender blocks (rather than dropping) when consumers are slow. This fills the ring buffer, which triggers backpressure to the LB.

---

## Writing Your Own ZMQ Source

### Socket Pattern

Your source uses **ZMQ PUSH** and **binds**. The bridge uses ZMQ PULL and connects.

```
Your source (PUSH, bind :5556)  ◀── zmq_ejfat_bridge connects (PULL)
```

This means:
- Start your source first, then start the bridge.
- Add a short sleep (≥1 s) after binding and before sending to let the bridge connect.
- Multiple bridge workers can connect to the same PUSH socket; ZMQ distributes messages round-robin.

### Message Format

The pipeline accepts **any binary byte sequence**. There are no minimum or maximum size constraints imposed by the pipeline (practical limits depend on MTU and OS buffers). If you need sequencing, timestamps, or message types at the consumer, embed them in your payload — the pipeline will preserve them exactly.

### Python Example

```python
#!/usr/bin/env python3
import zmq
import time

ctx = zmq.Context()
sock = ctx.socket(zmq.PUSH)
sock.set(zmq.SNDHWM, 10000)      # Max queued messages before blocking
sock.bind("tcp://*:5556")

time.sleep(1)                     # Allow bridge workers to connect

for i in range(1000):
    payload = i.to_bytes(8, "big") + b"\xab" * 4088   # 4096-byte message
    try:
        sock.send(payload, flags=zmq.DONTWAIT)
    except zmq.Again:
        # Send buffer full — bridge is applying backpressure
        time.sleep(0.001)
        i -= 1                    # Retry this message
        continue

sock.close()
ctx.term()
```

### C++ Example

```cpp
#include <zmq.hpp>
#include <cstdint>
#include <vector>
#include <thread>
#include <chrono>

int main() {
    zmq::context_t ctx(1);
    zmq::socket_t sock(ctx, zmq::socket_type::push);
    sock.set(zmq::sockopt::sndhwm, 10000);
    sock.bind("tcp://*:5556");

    // Allow bridge workers to connect
    std::this_thread::sleep_for(std::chrono::seconds(1));

    std::vector<uint8_t> payload(4096, 0xAB);

    for (int i = 0; i < 1000; i++) {
        // Embed sequence number in first 8 bytes (big-endian)
        uint64_t seq = static_cast<uint64_t>(i);
        for (int b = 0; b < 8; b++)
            payload[b] = (seq >> (56 - 8 * b)) & 0xFF;

        zmq::message_t msg(payload.data(), payload.size());
        while (true) {
            auto result = sock.send(msg, zmq::send_flags::dontwait);
            if (result.has_value()) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }

    sock.close();
    ctx.close();
    return 0;
}
```

### Best Practices

| Practice | Why |
|----------|-----|
| Set `SNDHWM` | Controls the send-side queue depth before blocking. Default 1000; raise to 10000 for burst absorption. |
| Use `DONTWAIT` + retry | Avoids blocking indefinitely. On `zmq.Again`, sleep briefly and retry. |
| Bind before bridge starts | The bridge connects at startup. If the source hasn't bound yet, the bridge may fail to connect. |
| Sleep 1 s before sending | ZMQ connects are asynchronous. A short sleep ensures at least one worker is connected before the first message. |
| Rate-limit for sustained streams | Without rate limiting, a fast source will fill the bridge's send queue, triggering backpressure or drops. |
| Handle `SIGINT`/`SIGTERM` | Set a flag in a signal handler, check it in your send loop, and close the socket cleanly before exit. |

---

## Writing Your Own ZMQ Consumer (Sink)

### Socket Pattern

Your consumer uses **ZMQ PULL** and **connects**. The proxy uses ZMQ PUSH and binds.

```
ejfat_zmq_proxy (PUSH, bind :5555)  ──▶ Your consumer connects (PULL)
```

This means:
- The proxy can be started in any order relative to the consumer.
- Multiple consumers can connect to the same proxy. ZMQ PUSH distributes messages round-robin. Each consumer gets a disjoint subset of messages (no broadcast/fan-out).
- If a consumer's receive buffers fill, ZMQ temporarily skips it and sends to other consumers.

### Message Format

Messages are raw event payloads — byte-for-byte identical to what the source sent. The pipeline adds no framing. Parse your payload according to whatever format your source used.

### Python Example

```python
#!/usr/bin/env python3
import zmq
import struct

ctx = zmq.Context()
sock = ctx.socket(zmq.PULL)
sock.set(zmq.RCVHWM, 10000)          # Max queued messages before proxy blocks
sock.connect("tcp://localhost:5555")

received = 0
while True:
    try:
        msg = sock.recv(flags=zmq.NOBLOCK)
    except zmq.Again:
        # No message available right now
        import time; time.sleep(0.001)
        continue

    # Parse your payload here
    if len(msg) >= 8:
        seq = struct.unpack(">Q", msg[:8])[0]
    payload = msg[8:]

    received += 1
    if received % 1000 == 0:
        print(f"Received {received} messages, latest seq={seq}, size={len(msg)}")
```

### C++ Example

```cpp
#include <zmq.hpp>
#include <cstdint>
#include <iostream>

int main() {
    zmq::context_t ctx(1);
    zmq::socket_t sock(ctx, zmq::socket_type::pull);
    sock.set(zmq::sockopt::rcvhwm, 10000);
    sock.connect("tcp://localhost:5555");

    int received = 0;
    while (true) {
        zmq::message_t msg;
        auto result = sock.recv(msg, zmq::recv_flags::dontwait);
        if (!result) {
            std::this_thread::sleep_for(std::chrono::microseconds(100));
            continue;
        }

        const uint8_t* data = static_cast<const uint8_t*>(msg.data());
        size_t size = msg.size();

        // Parse your payload here
        uint64_t seq = 0;
        if (size >= 8)
            for (int b = 0; b < 8; b++)
                seq = (seq << 8) | data[b];

        received++;
        if (received % 1000 == 0)
            std::cout << "Received " << received << " messages, latest seq="
                      << seq << ", size=" << size << "\n";
    }

    sock.close();
    ctx.close();
    return 0;
}
```

### Best Practices

| Practice | Why |
|----------|-----|
| Set `RCVHWM` | Controls how many messages queue in the consumer before the proxy blocks. Lower = tighter backpressure. |
| Use `NOBLOCK` + sleep | Lets you check a shutdown flag on each iteration rather than blocking indefinitely on `recv`. |
| Size `RCVHWM` relative to processing rate | If your consumer is slow, a large RCVHWM delays backpressure propagation; a small RCVHWM triggers it sooner. |
| Do not assume message ordering | Multi-threaded reassembly in the proxy means events can arrive out of order. Sort by embedded sequence if needed. |
| Multiple consumers share load | Connecting N consumers distributes messages round-robin across all of them automatically. |
| Handle `SIGINT`/`SIGTERM` | Signal handler sets a stop flag; check it in your receive loop before closing the socket. |

---

## Message Format

The pipeline imposes **no message format requirements**. Any binary byte sequence of any length is valid. The following table shows the format used by the included test tools — adopt it, adapt it, or ignore it entirely.

| Offset | Length | Field | Notes |
|--------|--------|-------|-------|
| 0 | 8 bytes | `uint64` big-endian sequence number | Optional; used by test tools for loss detection |
| 8 | N bytes | Application payload | Any bytes |

If you don't need sequencing, just send your raw payload with no header. If you need multiple message types or additional metadata, prepend whatever header structure suits your application — the pipeline will pass it through unchanged.

> **No metadata is forwarded.** The E2SAR event number and data ID are internal to the pipeline and are not included in the ZMQ output message. If you need event numbering at the consumer, embed it in your payload at the source.

---

## Running the Pipeline

### Local / Back-to-Back Mode (No LB)

The easiest way to test without EJFAT infrastructure. All components run on localhost.

**Automated (recommended):**
```bash
./scripts/local_pipeline_test.sh --count 1000 --size 4096
```

**Manual (4 terminals):**

```bash
# Terminal 1: Start the proxy
./build/bin/ejfat_zmq_proxy -c config/local_test.yaml

# Terminal 2: Start your consumer (connect AFTER proxy is up)
python3 scripts/pipeline_validator.py \
    --endpoint tcp://localhost:5555 \
    --expected 1000

# Terminal 3: Start the bridge (--no-cp skips LB registration)
EJFAT_URI="ejfat://local@127.0.0.1:9876/lb/1?data=127.0.0.1:19522&sync=127.0.0.1:19523"
./build/bin/zmq_ejfat_bridge \
    --uri      "$EJFAT_URI" \
    --zmq-endpoint tcp://localhost:5556 \
    --mtu      1500 \
    --sockets  1 \
    --no-cp

# Terminal 4: Start your source (last, so bridge is already connected)
python3 scripts/pipeline_sender.py \
    --endpoint tcp://*:5556 \
    --count    1000 \
    --size     4096 \
    --rate     0
```

**Bridge (`zmq_ejfat_bridge`) flags:**

| Flag | Default | Description |
|------|---------|-------------|
| `--uri` | (required) | EJFAT URI containing target data address |
| `--zmq-endpoint` | `tcp://localhost:5556` | ZMQ PULL connects here (your source) |
| `--mtu` | 9000 | UDP fragmentation MTU (use 1500 for localhost) |
| `--sockets` | 16 | E2SAR internal UDP send thread pool size |
| `--workers` | 1 | Parallel ZMQ PULL receiver threads |
| `--rcvhwm` | 10000 | ZMQ receive HWM per worker socket |
| `--data-id` | 1 | E2SAR data ID (must be consistent with proxy config) |
| `--src-id` | 1 | E2SAR source ID in sync headers |
| `--no-cp` | off | Skip LB control plane registration |
| `--stats-interval` | 10 | Print bridge stats every N seconds (0=disable) |

### LB Mode (Production / Perlmutter)

1. Obtain an EJFAT URI from your LB reservation (e.g., via `minimal_reserve.sh`).
2. Start `ejfat_zmq_proxy` with `use_cp: true` in your YAML config.
3. Start `zmq_ejfat_bridge` **without** `--no-cp`, using the same URI.
4. Your ZMQ source and consumer are unchanged.

See [USER_TESTING_GUIDE.md](USER_TESTING_GUIDE.md) for full Perlmutter / Slurm instructions.

---

## Configuration Reference

### Key Proxy Parameters (YAML)

The proxy is configured via a YAML file (default: `config/default.yaml`). The full 39-parameter schema is documented in that file. The most impactful parameters for pipeline users:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `ejfat.use_cp` | `true` | `false` for back-to-back/local mode (no gRPC to LB) |
| `ejfat.with_lb_header` | `false` | `true` when no real LB strips the LB header (B2B mode) |
| `ejfat.data_ip` | `""` (auto) | Explicit listen IP; required on macOS (`127.0.0.1`) |
| `ejfat.data_port` | `10000` | UDP port the Reassembler listens on |
| `ejfat.num_recv_threads` | `1` | E2SAR Reassembler receive threads |
| `zmq.push_endpoint` | `tcp://*:5555` | PUSH socket; consumers connect here |
| `zmq.send_hwm` | `1000` | ZMQ send HWM; lower = earlier backpressure |
| `zmq.io_threads` | `1` | ZMQ I/O thread count |
| `buffer.size` | `2000` | Ring buffer capacity (events); should exceed `send_hwm` |
| `backpressure.ready_threshold` | `0.95` | Buffer fill fraction that sets `ready=0` (throttle sender) |
| `backpressure.pid.setpoint` | `0.5` | Target buffer fill fraction for PID controller |
| `backpressure.pid.kp` | `1.0` | PID proportional gain |

### Tuning Quick Reference

| Goal | What to Adjust |
|------|----------------|
| Trigger backpressure sooner | Lower `zmq.send_hwm` and `buffer.size` |
| Absorb larger bursts | Raise `zmq.send_hwm` and `buffer.size` |
| Higher bridge throughput | Raise bridge `--sockets` and `--workers` |
| Local / loopback testing | Bridge: `--mtu 1500 --sockets 1 --no-cp`; proxy: `local_test.yaml` |
| Multiple consumers | Connect multiple PULL clients to `:5555`; ZMQ round-robins automatically |
| Reduce proxy log noise | Raise `logging.drop_warn_interval` and `logging.progress_interval` |

---

## Reference: Included Example Tools

The following tools ship with the repository and serve as reference implementations for sources and sinks:

| File | Language | Role |
|------|----------|------|
| `scripts/pipeline_sender.py` | Python | ZMQ PUSH source with seq# + fill pattern |
| `scripts/pipeline_validator.py` | Python | ZMQ PULL consumer with seq validation |
| `bin/pipeline_sender.cpp` | C++ | Same as above, higher performance |
| `bin/pipeline_validator.cpp` | C++ | Same as above, includes burst rate metrics |
| `scripts/test_sender.py` | Python | Minimal PUSH source (no seq#, for component testing) |
| `scripts/test_receiver.py` | Python | Minimal PULL consumer with delay injection (for backpressure testing) |
