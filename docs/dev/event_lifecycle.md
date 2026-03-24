# Event Lifecycle: Every Hop from Socket Buffer to Consumer

This document traces every buffer, copy, and ownership transfer an event undergoes
from the moment its first UDP datagram arrives in the kernel socket buffer until the
final consumer application reads the data. It is intended as a reference for performance
analysis and future optimization work.

---

## Data Flow Overview

```
  ┌─────────────────────────────────────────────────────────┐
  │ NIC / NETWORK                                           │
  │   UDP datagrams (one or more segments per event)        │
  └─────────────────────────────────────────────────────────┘
                          │
                          │  HOP 0: NIC DMA (not a CPU copy)
                          │
                          ▼
  ┌─────────────────────────────────────────────────────────┐
  │ KERNEL                                                  │
  │   ┌───────────────────────────────────────────────────┐ │
  │   │ UDP SO_RCVBUF  (per-socket receive buffer)        │ │
  │   └───────────────────────────────────────────────────┘ │
  └─────────────────────────────────────────────────────────┘
                          │
                          │  HOP 1: recvfrom()  ★ COPY 1
                          │
                          ▼
  ┌─────────────────────────────────────────────────────────┐
  │ E2SAR recv thread  (×N, one per UDP socket)             │
  │                                                         │
  │         malloc(9000) → recvBuffer                       │
  │                │                                        │
  │                │  reinterpret_cast REHdr*               │
  │                │  (zero-copy header parse)              │
  │                │                                        │
  │                │  HOP 2: memcpy()  ★ COPY 2             │
  │                │  (payload → event buf at bufferOffset) │
  │                │                                        │
  │                ▼                                        │
  │         new uint8_t[bufferLength]  ← event buffer       │
  │         free(recvBuffer)                                │
  │                │                                        │
  │                │  HOP 3: enqueue()  (pointer, ~48 B)    │
  │                │                                        │
  └────────────────│────────────────────────────────────────┘
                   │
                   ▼  boost::lockfree::queue<EventQueueItem*>  (cap 1000)
  ┌────────────────│────────────────────────────────────────┐
  │ Proxy receiver thread                                   │
  │                │                                        │
  │                │  HOP 4: recvEvent() / dequeue()        │
  │                │         (raw pointer handoff)          │
  │                │                                        │
  │                ▼                                        │
  │         uint8_t*  event_data                            │
  │                │                                        │
  │                │  HOP 5: Event constructor              │
  │                │         (pointer adoption)             │
  │                │                                        │
  │                ▼                                        │
  │         Event { data, bytes, event_num, data_id }       │
  │                │                                        │
  │                │  HOP 6: buffer_->push(std::move(event))│
  │                │                                        │
  └────────────────│────────────────────────────────────────┘
                   │
                   ▼  boost::lockfree::spsc_queue<Event>  (EventRingBuffer)
  ┌────────────────│────────────────────────────────────────┐
  │ ZMQ sender thread                                       │
  │                │                                        │
  │                │  HOP 7: buffer_->pop(event)            │
  │                │         (move assignment)              │
  │                │                                        │
  │                ▼                                        │
  │         Event { data, bytes, event_num, data_id }       │
  │                │                                        │
  │                │  HOP 8: event.release()                │
  │                │         + zmq::message_t(buf, bytes,   │
  │                │           free_fn, nullptr)            │
  │                │         (zero-copy: zmq_msg_init_data) │
  │                │                                        │
  │                ▼                                        │
  │         zmq::message_t  (same pointer, custom delete[]) │
  │                │                                        │
  │                │  socket_->send(msg, ...)               │
  │                │                                        │
  └────────────────│────────────────────────────────────────┘
                   │
                   │  HOP 9: ZMQ I/O thread (same process)
                   │    ZMTP encode         ★ COPY 3
                   │    write() to kernel   ★ COPY 4
                   │    ZMQ calls delete[] on the E2SAR buffer
                   │
                   │    ─ ─ ─ ─ ─ TCP transport ─ ─ ─ ─ ─
                   │
                   │  HOP 10: ZMQ I/O thread (consumer process)
                   │    read() from kernel  ★ COPY 5
                   │
                   ▼
  ┌─────────────────────────────────────────────────────────┐
  │ Consumer process                                        │
  │                                                         │
  │   zmq_msg_recv() → msg.data()  (direct ptr, no copy)    │
  │                                                         │
  │   bridge only: memcpy() → new uint8_t[]  ★ COPY 6       │
  │   (E2SAR addToSendQueue needs buf to outlive ZMQ msg)   │
  │                                                         │
  └─────────────────────────────────────────────────────────┘
```

---

## Hop-by-Hop Reference

### Hop 0 — NIC → Kernel Socket Receive Buffer
- **Mechanism**: NIC DMA + interrupt / NAPI polling
- **Destination**: Kernel `SO_RCVBUF` (default 3 MB per socket; configurable via E2SAR's `rcvSocketBufSize`)
- **Copy?**: DMA (hardware → kernel memory). Not a CPU copy.
- **Granularity**: Per UDP datagram (one segment of one event)
- **Note**: E2SAR opens one UDP socket per receive thread, so buffer space multiplies with thread count.

### Hop 1 — Kernel Socket Buffer → `recvBuffer`  ★ COPY 1
- **Source file**: `e2sarDPReassembler.cpp:316-322`
- **Mechanism**: `recvfrom()` syscall
- **Source**: Kernel socket receive buffer
- **Destination**: `malloc(9000)` — freshly allocated per datagram
- **Copy?**: Yes — full data copy (kernel→userspace; unavoidable at this boundary)
- **Size**: Up to `RECV_BUFFER_SIZE` = 9000 bytes per datagram
- **Thread**: One of N E2SAR recv threads, driven by a `select()` loop
- **Freed**: `free(recvBuffer)` at line 395, immediately after Hop 2

### Hop 2 — `recvBuffer` → Event Reassembly Buffer  ★ COPY 2
- **Source file**: `e2sarDPReassembler.cpp:391-392`
- **Mechanism**: `memcpy()` of the segment payload into the correct offset in the event buffer
- **Source**: `recvBuffer + sizeof(LBHdrU) + sizeof(REHdr)` (payload after headers)
- **Destination**: `item->event + rehdr->get_bufferOffset()` — a `new uint8_t[bufferLength]` allocated once per event in `EventQueueItem::initFromHeader()` (`e2sarDPReassembler.hpp:95`)
- **Copy?**: Yes — scatter-gather copy into the reassembly buffer at the offset specified by the RE header
- **Size**: Payload bytes per segment (~8964 B max with both LB+RE headers in 9000 B datagram)
- **Repeats**: Once per segment; all segments of a multi-segment event target the same buffer
- **Header parsing**: Zero-copy — `REHdr*` is `reinterpret_cast` directly into `recvBuffer` (no copy)
- **Why not eliminated**: Segments can arrive out of order. The `bufferOffset` field in `REHdr` tells each segment where it belongs in the full event. A scatter-gather receive (e.g., `recvmsg` + `io_uring`) could avoid the intermediate `recvBuffer`, but E2SAR uses POSIX `recvfrom`.

### Hop 3 — `eventsInProgress` Map → `eventQueue`
- **Source file**: `e2sarDPReassembler.hpp:132-148` (`enqueue()`)
- **Mechanism**: `new EventQueueItem(*item.get())` (shallow copy constructor) → `boost::lockfree::queue::push()`
- **Source**: `shared_ptr<EventQueueItem>` in the per-thread `eventsInProgress` map
- **Destination**: Raw `EventQueueItem*` on `boost::lockfree::queue<EventQueueItem*>` (capacity 1000)
- **Copy?**: No data copy — copy constructor copies the `event` pointer (8 bytes) plus ~40 bytes of metadata scalars; the event buffer is not duplicated
- **Ownership**: The `shared_ptr` is `.reset()` at line 424. `~EventQueueItem()` is a no-op (line 73), so the event buffer survives. Ownership is now with the raw pointer on the queue.
- **Failure mode**: If the queue is full (depth ≥ 1000), the event is dropped, the buffer is `delete[]`'d, and `enqueueLoss` is incremented.

### Hop 4 — `eventQueue` → Proxy Receiver Thread (`recvEvent()`)
- **Source file**: `e2sarDPReassembler.cpp:643-676` (`recvEvent`) and lines 150-161 (`dequeue`)
- **Mechanism**: `boost::lockfree::queue::pop()` → assigns `*event = eventItem->event`
- **Source**: `EventQueueItem*` on the lock-free queue
- **Destination**: `uint8_t** event` output parameter (stack variable in proxy receiver thread, `proxy.cpp:240`)
- **Copy?**: No data copy — raw pointer handoff. The `EventQueueItem` wrapper is `delete`'d; no-op destructor leaves the event buffer alive.
- **Blocking**: `recvEvent()` waits on `recvThreadCond` (condition variable) with a timeout; `recvEventTimeout_ms` is configurable.

### Hop 5 — Raw Pointer → `Event` Struct
- **Source file**: `proxy.cpp:263`
- **Mechanism**: `Event event(event_data, event_bytes, event_num, data_id);` then `event_data = nullptr;`
- **Source**: Raw `uint8_t*` from `recvEvent()`
- **Destination**: `Event` struct on receiver thread stack (`event_ring_buffer.hpp:22-23`)
- **Copy?**: No data copy — pointer adoption. The `Event` destructor (`delete[] data`) now owns the buffer.

### Hop 6 — `Event` → `EventRingBuffer` (SPSC push)
- **Source file**: `proxy.cpp:267`, `event_ring_buffer.cpp:19-24`
- **Mechanism**: `buffer_->push(std::move(event))` → `boost::lockfree::spsc_queue::push()` → `Event` move constructor
- **Source**: `Event` on receiver thread stack
- **Destination**: Pre-allocated `Event` slot inside the `spsc_queue` ring (heap, fixed at construction)
- **Copy?**: No data copy — move constructor (`event_ring_buffer.hpp:30-32`) transfers the pointer and nulls the source
- **Thread boundary**: **Producer side** of the SPSC contract

### Hop 7 — `EventRingBuffer` → ZMQ Sender Thread (SPSC pop)
- **Source file**: `zmq_sender.cpp:73`, `event_ring_buffer.cpp:27-32`
- **Mechanism**: `buffer_->pop(event)` → `spsc_queue::pop()` → `Event` move assignment
- **Source**: `Event` slot in the SPSC ring
- **Destination**: `Event event` on ZMQ sender thread stack
- **Copy?**: No data copy — move assignment (`event_ring_buffer.hpp:34-42`) transfers pointer, nulls the ring slot
- **Thread boundary**: **Consumer side** of the SPSC contract

### Hop 8 — `Event` → `zmq::message_t` (zero-copy)
- **Source file**: `zmq_sender.cpp:83-87`
- **Mechanism**: `event.release()` extracts `{buf, bytes}` and nulls the `Event`; `zmq::message_t msg(buf, bytes, free_fn, nullptr)` calls `zmq_msg_init_data()` internally
- **Source**: The same `new uint8_t[]` allocated back in Hop 2
- **Destination**: `zmq::message_t` wrapping the exact same pointer — no data duplicated
- **Copy?**: No data copy — ZMQ takes pointer ownership with a custom `delete[]` deallocator
- **Key design**: The single heap allocation from E2SAR flows all the way here, through 6 ownership transfers, without being copied.

### Hop 9 — `zmq_msg_send()` → Kernel TCP Send Buffer  ★ COPY 3 + ★ COPY 4
- **Source file**: `zmq_sender.cpp:92-99`
- **Mechanism**: `socket_->send(msg, ...)` → ZMQ I/O thread → `write()`/`send()` syscall

  | Sub-step | Copy? | Description |
  |----------|-------|-------------|
  | 9a — API → ZMQ internal pipe | No | Reference-counted pointer transfer for messages >30 bytes |
  | 9b — ZMQ I/O thread: ZMTP framing | **COPY 3** | ZMQ encodes message length + payload into its output buffer |
  | 9c — ZMQ I/O thread: kernel write | **COPY 4** | `write()`/`send()` syscall moves data into kernel TCP send buffer |

- After the kernel has accepted the data, ZMQ calls the custom free function: `delete[] static_cast<uint8_t*>(ptr)`. This is the end of the E2SAR-allocated buffer's life.
- **Configurable**: `sndhwm` (HWM, default 1000), `sndbuf` (maps to `SO_SNDBUF`, default 0 = OS), `linger_ms`

### Hop 10 — Consumer Receives via ZMQ PULL Socket
- **Mechanism**: ZMQ I/O thread does `read()`/`recv()` syscall (COPY 5), places message into internal pipe, `zmq_msg_recv()` picks it up via pointer move
- **Consumer access**: `msg.data()` returns a direct pointer into ZMQ's internal receive buffer — no copy
- **Special case — bridge worker** (`zmq_ejfat_bridge.cpp:113-114`):
  ```cpp
  uint8_t* buf = new uint8_t[msg.size()];
  std::memcpy(buf, msg.data(), msg.size());  // ★ COPY 6
  ```
  This copy is required because E2SAR's `addToSendQueue` takes ownership of the buffer asynchronously, and the ZMQ message would be freed at scope exit before E2SAR finishes using it.

---

## Summary Table

| Hop | Where | Copy? | Mechanism | Data size |
|-----|-------|-------|-----------|-----------|
| 0 | NIC → kernel recv buf | DMA | Hardware DMA | per datagram |
| 1 | kernel → `recvBuffer` | **COPY 1** | `recvfrom()` syscall | ≤9000 B/segment |
| 2 | `recvBuffer` → event buf | **COPY 2** | `memcpy()` at `bufferOffset` | payload/segment |
| 3 | `eventsInProgress` → `eventQueue` | pointer | shallow copy ctor (~48 B) | 0 B payload |
| 4 | `eventQueue` → receiver thread | pointer | `dequeue()` raw ptr | 0 B payload |
| 5 | raw ptr → `Event` struct | pointer | constructor | 0 B payload |
| 6 | `Event` → SPSC ring buffer | move | move ctor | 0 B payload |
| 7 | SPSC ring buffer → sender thread | move | move assign | 0 B payload |
| 8 | `Event` → `zmq::message_t` | zero-copy | `zmq_msg_init_data` | 0 B payload |
| 9 | ZMQ send → kernel TCP send buf | **COPY 3+4** | ZMTP encode + `write()` | full event ×2 |
| 10 | TCP recv → consumer | **COPY 5** | `read()` syscall | full event |
| 10b | bridge consumer only | **COPY 6** | explicit `memcpy` | full event |

**Full-payload copies in the nominal path** (sender → single consumer): 5 (hops 1, 2, 9b, 9c, 10).

**Hops 3–8 are zero-copy for the event payload.** The `new uint8_t[]` allocated in E2SAR's recv thread (hop 2) flows through 6 ownership transfers without being copied, until ZMQ's custom deallocator `delete[]`s it after hop 9.

---

## Copy-Point Anatomy

Each box covers one full-data copy: the staging buffer that feeds it, the flow control
mechanism at that stage, how long data waits there, what causes overflow and discard, and
how to compute the buffer size.

```
  ┌─────────────────────────────────────────────────────────┐
  │ ★ COPY 1  recvfrom()   UDP SO_RCVBUF → recvBuffer       │
  ├─────────────────────────────────────────────────────────┤
  │ a. Flow control                                         │
  │    None — UDP is fire-and-forget; no backpressure.      │
  │    E2SAR drains via select() (10 ms timeout) across     │
  │    N sockets, one per recv port, one port per thread.   │
  ├─────────────────────────────────────────────────────────┤
  │ b. Data lifetime  (datagram waiting in SO_RCVBUF)       │
  │    Min:      ~0 µs   select() already blocked; instant  │
  │    Typical:  <1 ms   select() returns promptly          │
  │    Max:      unbounded  recv thread stalled (mutex or   │
  │                         CPU); kernel drops on overflow  │
  ├─────────────────────────────────────────────────────────┤
  │ c. Overflow / discard                                   │
  │    Kernel silently drops datagrams when SO_RCVBUF full. │
  │    E2SAR has no SO_RXQ_OVFL set and does not call       │
  │    getsockopt to verify the actual buffer size granted. │
  │    Indirect signal: lost fragments → GC timeout         │
  │    → reassemblyLoss stat incremented.                   │
  ├─────────────────────────────────────────────────────────┤
  │ d. Buffer sizing                                        │
  │    Config: ejfat.rcv_socket_buf_size                    │
  │    Default: 3,145,728 B (3 MB) per socket               │
  │    Silently capped by net.core.rmem_max (Linux) or      │
  │    kern.ipc.maxsockbuf (macOS) with no warning.         │
  │    Rule: SO_RCVBUF ≥ arrival_rate × select_latency      │
  └─────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────┐
  │ ★ COPY 2  memcpy()   recvBuffer → event assembly buf    │
  ├─────────────────────────────────────────────────────────┤
  │ a. Flow control                                         │
  │    eventsInProgress map (unbounded) absorbs fragments   │
  │    in flight. Completed events go to eventQueue         │
  │    (boost::lockfree, cap 1000, hardcoded QSIZE).        │
  │    GC thread evicts stale partials every eventTimeout_ms│
  ├─────────────────────────────────────────────────────────┤
  │ b. Data lifetime  (event buffer alive from 1st segment) │
  │    Min:      ~µs    single fragment; enqueued instantly │
  │    Typical:  <1 ms  LAN, 1 MB event at 10 Gbps          │
  │    Max (partial):   eventTimeout_ms = 500 ms (GC kills) │
  │    Max (complete):  unbounded  (stuck in eventQueue     │
  │                     if recvEvent() is not called)       │
  ├─────────────────────────────────────────────────────────┤
  │ c. Overflow / discard                                   │
  │    eventQueue full (≥1000): enqueue() drops event,      │
  │    delete[]s the buffer, increments enqueueLoss.        │
  │    eventsInProgress: no cap; grows until memory         │
  │    exhaustion or GC evicts (reassemblyLoss).            │
  ├─────────────────────────────────────────────────────────┤
  │ d. Buffer sizing                                        │
  │    eventQueue: 1000 (hardcoded QSIZE, not configurable) │
  │    Event buf: exactly rehdr->get_bufferLength() bytes   │
  │    eventTimeout_ms: configurable, default 500 ms        │
  │    eventsInProgress peak ≈ arrival_rate × timeout_ms    │
  └─────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────┐
  │ ★ COPY 3  ZMTP encode  event buffer → ZMQ output buf    │
  ├─────────────────────────────────────────────────────────┤
  │ a. Flow control                                         │
  │    EventRingBuffer (SPSC, cap 2000): push() drops if    │
  │    full. ZMQ sndhwm (default 1000): send(dontwait)      │
  │    returns EAGAIN if pipe full → retry with blocking    │
  │    send() — never drops. BackpressureMonitor reads      │
  │    ring fill → PID → sendState() → LB throttle.         │
  ├─────────────────────────────────────────────────────────┤
  │ b. Data lifetime  (event buf: ring pop → ZMQ free)      │
  │    Min:      ~µs    ZMQ pipe not full; immediate send   │
  │    Typical:  <1 ms  balanced producer/consumer rates    │
  │    Max:      unbounded  consumer stalled → ZMQ blocks   │
  │              → ring fills → upstream drops triggered    │
  │              linger_ms=0: unsent msgs dropped on close  │
  ├─────────────────────────────────────────────────────────┤
  │ c. Overflow / discard                                   │
  │    EventRingBuffer full → push() returns false →        │
  │    Event destructor delete[]s buffer → events_dropped_  │
  │    (logged every drop_warn_interval, default 1000).     │
  │    Cascade: slow consumer → ZMQ blocks sender thread    │
  │    → ring fills → drops → BP monitor → LB throttle.     │
  ├─────────────────────────────────────────────────────────┤
  │ d. Buffer sizing                                        │
  │    EventRingBuffer: buffer.size (YAML), default 2000    │
  │    ZMQ sndhwm:  zmq.send_hwm (YAML), default 1000 msgs  │
  │    ZMQ sndbuf:  zmq.sndbuf (YAML),   default 0 (OS)     │
  │    Footprint: (ring_cap + sndhwm) × avg_event_size      │
  └─────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────┐
  │ ★ COPY 4  write()   ZMQ output buf → TCP SO_SNDBUF      │
  │ ★ COPY 5  read()    TCP SO_RCVBUF  → consumer ZMQ buf   │
  ├─────────────────────────────────────────────────────────┤
  │ a. Flow control                                         │
  │    TCP sliding window: kernel advertises zero window    │
  │    when SO_RCVBUF full → sender write() blocks.         │
  │    Consumer ZMQ rcvhwm (default 10,000): if pipe full,  │
  │    ZMQ stops reading TCP → rcvbuf fills → zero window   │
  │    → sender I/O thread stalls → sndhwm fills → proxy    │
  │    send() blocks → ring fills → BP monitor → LB.        │
  ├─────────────────────────────────────────────────────────┤
  │ b. Data lifetime  (data in TCP kernel buffers)          │
  │    Min:      ~µs    loopback; kernel copies internally  │
  │    Typical:  <1 ms  LAN (1 Gbps, sub-ms RTT)            │
  │    Max:      ~2 min  TCP RTO before connection dead;    │
  │              ZMQ reconnects; in-flight data is lost.    │
  ├─────────────────────────────────────────────────────────┤
  │ c. Overflow / discard                                   │
  │    TCP is reliable — no silent drops within the layer.  │
  │    ZMQ PUSH/PULL: HWM causes blocking, not drops.       │
  │    Data loss only on: connection drop, process crash,   │
  │    or socket close with linger_ms=0 (default).          │
  ├─────────────────────────────────────────────────────────┤
  │ d. Buffer sizing                                        │
  │    SO_SNDBUF: zmq.sndbuf (YAML), default 0 (OS ~1 MB)   │
  │    SO_RCVBUF: consumer OS default (~128 KB – 1 MB)      │
  │    Consumer rcvhwm: 10,000 msgs (validator/bridge)      │
  │    BDP rule: SO_SNDBUF ≥ bandwidth × RTT                │
  │    10 Gbps × 0.1 ms = 125 KB;  × 50 ms = 62.5 MB        │
  └─────────────────────────────────────────────────────────┘
```

---

## The One Allocation

The key architectural property of this system: **one heap allocation per event**, allocated
in E2SAR's recv thread and freed by ZMQ's deallocator after TCP transmission.

```
  new uint8_t[bufferLength]          ← HOP 2: allocated in EventQueueItem::initFromHeader
          │
          │  memcpy() per segment into event buffer  ★ COPY 2
          │  (repeated for each UDP segment; all land in the same buffer)
          │
          ▼
  fully assembled event buffer
          │
          │  HOP 3–8: six pointer-only ownership transfers
          │    EventQueueItem (shallow copy) → eventQueue (raw ptr)
          │    → recvEvent() (ptr handoff) → Event struct (adoption)
          │    → EventRingBuffer push (move) → pop (move)
          │    → zmq::message_t (zmq_msg_init_data, zero-copy)
          │
          ▼
  zmq::message_t  wrapping the same pointer
          │
          │  HOP 9: TCP send
          │    ZMQ encodes and writes to kernel  ★ COPY 3 + ★ COPY 4
          │    After kernel accepts: ZMQ calls delete[] on this pointer
          │
          ▼
  (buffer freed)                     ← freed by ZMQ custom deallocator
```

The `Event` struct (`event_ring_buffer.hpp`) enforces single-ownership with C++ move semantics:
- Non-copyable (`= delete`) — no accidental data duplication
- Move-only — pointer transfers without copies
- `release()` — safe handoff to ZMQ with no double-free risk

---

## Future Annotations

<!-- TODO: add measured latency per hop under load -->
<!-- TODO: add throughput ceiling analysis (which copy is the bottleneck?) -->
<!-- TODO: note impact of SO_RCVBUF sizing on hop 0→1 drop rate -->
<!-- TODO: io_uring / recvmmsg potential for eliminating COPY 1 and the malloc(9000) per packet -->
<!-- TODO: RDMA / DPDK bypass potential for eliminating all kernel copies -->
