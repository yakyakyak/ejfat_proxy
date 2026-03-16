# EJFAT ZMQ Proxy - Local Testing Guide

## Overview

This guide explains how to run the EJFAT ZMQ Proxy locally without requiring a real EJFAT load balancer or control plane connection. This is useful for:
- Development and debugging
- Testing E2SAR integration
- Validating ZMQ pipeline
- Local experimentation

## Configuration

Use the provided `config/local_test.yaml` configuration:

```yaml
ejfat:
  # URI must be properly formatted but doesn't connect to real LB
  uri: "ejfat://local-test@127.0.0.1:9876/lb/1?data=127.0.0.1:19522&sync=127.0.0.1:19523"

  # CRITICAL: Disable control plane
  use_cp: false

  # Tell reassembler to expect LB headers (no real LB to strip them)
  with_lb_header: true

  # Local UDP port to receive data
  data_port: 19522

zmq:
  push_endpoint: "tcp://*:5555"
  send_hwm: 100

buffer:
  size: 500
```

## Key Settings for Local Testing

### 1. Control Plane: DISABLED
```yaml
use_cp: false
```
- Disables all gRPC communication with EJFAT load balancer
- No registration, no sendState calls
- Backpressure monitoring runs locally only

### 2. LB Header Handling
```yaml
with_lb_header: true
```
- Required for direct segmenter-to-reassembler testing
- Tells E2SAR reassembler to expect and ignore load balancer headers
- Normally these headers are stripped by the real load balancer

### 3. URI Format
Must still be properly formatted even though it's not used:
```
ejfat://token@host:port/lb/id?data=addr:port&sync=addr:port
```

## Running Locally

### Start the Proxy

```bash
cd build
./bin/ejfat_zmq_proxy -c ../config/local_test.yaml --stats-interval 2
```

You should see:
```
Loading configuration from: ../config/local_test.yaml
Initializing EJFAT ZMQ Proxy...
  Ring buffer: 500 events
  LB manager skipped (CP disabled)  ✓
  E2SAR reassembler initialized     ✓
    URI: ejfat://local-test@127.0.0.1:9876/lb/1?...
    Port: 19522
    Use CP: false                     ✓
    With LB header: true              ✓
  ZMQ sender created
  Backpressure monitor created
Initialization complete

Starting proxy components...
ZMQ sender bound to tcp://*:5555 (HWM=100)
Backpressure monitor started (period=100ms, CP=disabled)  ✓
All components started
Receiver thread started
```

### Start a ZMQ Consumer

In another terminal:
```bash
python3 scripts/test_receiver.py --endpoint tcp://localhost:5555
```

### Send Data via E2SAR Segmenter

You need to run an E2SAR segmenter that sends to `127.0.0.1:19522`. Example Python code:

```python
import e2sar_py

# Configure segmenter
seg_uri = e2sar_py.EjfatURI(
    uri="ejfat://local-test@127.0.0.1:9876/lb/1?data=127.0.0.1:19522&sync=127.0.0.1:19523",
    tt=e2sar_py.EjfatURI.TokenType.instance
)

sflags = e2sar_py.DataPlane.Segmenter.SegmenterFlags()
sflags.useCP = False  # Match proxy setting
sflags.syncPeriodMs = 1000

segmenter = e2sar_py.DataPlane.Segmenter(seg_uri, data_id=1, event_src_id=1, sflags)

# Send test event
test_data = b"Hello from E2SAR!"
result = segmenter.sendEvent(test_data)
```

## What Works in Local Mode

✅ **E2SAR Reassembly**
- Receives UDP packets
- Reassembles events
- Writes to ring buffer

✅ **Ring Buffer**
- Lock-free SPSC queue
- Fill level monitoring
- Overflow detection

✅ **ZMQ Output**
- PUSH socket to consumers
- High-water mark backpressure
- Statistics tracking

✅ **Backpressure Monitoring** (Local only)
- PID controller computation
- Fill level tracking
- No sendState to LB (CP disabled)

## What Doesn't Work in Local Mode

❌ **Control Plane Communication**
- No gRPC connection to load balancer
- No worker registration
- No sendState calls
- No dynamic slot assignment

❌ **Load Distribution**
- No coordination with load balancer
- Can only receive data sent directly to local IP:port
- No multi-worker load balancing

## Monitoring

### Statistics Output

The proxy prints stats at regular intervals:
```
=== Proxy Statistics ===
Events received:  74
Events dropped:   0
Buffer fill:      14.6%
Buffer size:      73 / 500
ZMQ sends:        1
ZMQ blocked:      1 (100.0%)
Last fill%:       14.2%
Last control:     0.000
========================
```

### Local Backpressure Monitor

With CP disabled, the monitor still runs but only logs locally:
```
Monitor #1: fill=0%
Monitor #51: fill=9.400%
```

No sendState calls are made to the load balancer.

## Troubleshooting

### "Capability to determine outgoing address not supported"
- This was fixed by using explicit IP address (127.0.0.1)
- The proxy now hardcodes localhost for local testing

### No Events Received
- Check E2SAR segmenter is sending to correct address/port (127.0.0.1:19522)
- Verify segmenter has `useCP=False`
- Ensure firewall allows localhost UDP traffic

### ZMQ Blocked
- This is normal if no ZMQ consumer is connected
- Start the test receiver to consume events
- Buffer will fill up without consumer

## Comparing Local vs Production

| Feature | Local Mode (`use_cp: false`) | Production (`use_cp: true`) |
|---------|---------------------------|----------------------------|
| Control Plane | Disabled | Enabled via gRPC |
| Load Balancer | None | Required |
| Worker Registration | Skipped | Required |
| SendState | Disabled | Every 100ms |
| LB Headers | Expected (withLBHeader: true) | Stripped by LB |
| Data Source | Direct UDP to localhost | LB distributes packets |
| Multi-worker | No | Yes |

## Next Steps

After validating local functionality:

1. **Update URI** with real EJFAT credentials
2. **Enable CP** (`use_cp: true`)
3. **Remove with_lb_header** (set to `false`)
4. **Configure worker_name** for identification
5. **Test with real load balancer**

See `BUILD_STATUS.md` and `TEST_REPORT.md` for production testing instructions.

## Code Changes for Local Testing

The following code changes enable local testing:

1. **Config Support** (`config.hpp`, `config.cpp`)
   - Added `with_lb_header` flag to EjfatConfig
   - Parse flag from YAML

2. **Proxy Initialization** (`proxy.cpp`)
   - Skip LB manager creation when `use_cp=false`
   - Pass ReassemblerFlags to E2SAR
   - Use explicit IP address for macOS compatibility
   - Better error handling with try-catch

3. **Backpressure Monitor** (`backpressure_monitor.cpp`)
   - Check for null LB manager
   - Skip sendState when CP disabled
   - Local-only monitoring mode

These changes maintain full compatibility with production use while enabling local development.
