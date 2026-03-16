# EJFAT ZMQ Proxy

A high-performance proxy that bridges E2SAR (EJFAT) receivers with ZeroMQ consumers, providing end-to-end flow control through backpressure feedback to the EJFAT load balancer.

## Architecture

```
e2sar sender -> EJFAT LB -> e2sar receiver -> ZMQ PUSH -> ZMQ PULL (consumer)
                   ^                              |
                   |______ sendState (backpressure feedback)
```

The proxy monitors internal queue fill levels and ZMQ backpressure, then signals the EJFAT load balancer to adjust data flow accordingly.

## Components

- **EjfatZmqProxy**: Main orchestrator
- **EventRingBuffer**: Lock-free SPSC queue between receiver and sender threads
- **ZmqSender**: ZMQ PUSH socket with high-water mark configuration
- **BackpressureMonitor**: Monitors queue state and sends feedback to LB via PID control

## Dependencies

- **E2SAR** (e2sar) - EJFAT data plane and control plane libraries
- **Boost** (≥1.74) - thread, chrono, lockfree, program_options
- **ZeroMQ** (≥4.3) - libzmq and cppzmq
- **yaml-cpp** - YAML configuration parsing
- **CMake** (≥3.15) - Build system

## Building

```bash
mkdir build && cd build
cmake ..
make
```

## Configuration

Create a YAML configuration file (see `config/default.yaml` for example):

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

```bash
# With config file
./build/bin/ejfat_zmq_proxy -c config/myconfig.yaml

# With command-line overrides
./build/bin/ejfat_zmq_proxy -c config/default.yaml --uri "ejfats://..." --endpoint "tcp://*:5555"

# Show help
./build/bin/ejfat_zmq_proxy --help
```

## Testing

### 1. Start test receiver (simulates slow consumer)

```bash
# Normal speed
./scripts/test_receiver.py --endpoint tcp://localhost:5555

# With artificial 10ms delay per message (triggers backpressure)
./scripts/test_receiver.py --endpoint tcp://localhost:5555 --delay 10
```

### 2. Start proxy

```bash
./build/bin/ejfat_zmq_proxy -c config/myconfig.yaml --stats-interval 5
```

### 3. Send data via E2SAR sender

Use your E2SAR sender application to push data to the EJFAT load balancer.

### 4. Observe backpressure

Watch the proxy stats output:
- `Buffer fill`: Should stay near 50% (or configured setpoint)
- `ZMQ blocked`: Percentage of sends that hit high-water mark
- `Last control`: Control signal sent to LB (0.0-1.0)

The load balancer should adjust data distribution based on these signals.

## Key Configuration Parameters

### ZMQ High-Water Mark (`zmq.send_hwm`)

Controls when ZMQ starts blocking sends. Lower values trigger backpressure earlier but may reduce throughput. Typical values: 100-10000.

### Buffer Size (`buffer.size`)

Internal ring buffer capacity. Should be larger than `send_hwm` to absorb bursts. Typical values: 1000-10000.

### PID Setpoint (`backpressure.pid.setpoint`)

Target buffer fill level (0.0-1.0). Default 0.5 (50%) provides headroom for bursts while maintaining low latency.

### PID Gains

- `kp`: Proportional gain - immediate response to fill level deviation
- `ki`: Integral gain - corrects steady-state error (usually 0 for this use case)
- `kd`: Derivative gain - dampens oscillations (usually 0 for this use case)

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

- **Events dropped**: Should be 0 - indicates buffer overflow
- **Buffer fill**: Current queue utilization
- **ZMQ blocked**: Percentage of sends hitting high-water mark
- **Last control**: Control signal (0.0-1.0) sent to LB

## Troubleshooting

### Events being dropped

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

## License

See LICENSE file for details.
