# EJFAT ZMQ Proxy User Guide

How to set up and run the EJFAT ZMQ proxy with senders and receivers on NERSC
Perlmutter.

## Overview

```
                         EJFAT Load Balancer
                        /         |          \
                       /          |           \
 e2sar_perf  ───UDP──▶    data plane    ──UDP──▶  ejfat_zmq_proxy ──ZMQ──▶  consumer(s)
   (sender)            \          |           /       (proxy)              (ZMQ PULL)
                        \  control plane  ◀──/
                         (backpressure)
```

The proxy receives reassembled events from the EJFAT load balancer via E2SAR,
buffers them in a lock-free ring buffer, and pushes them out over a ZMQ PUSH
socket. Downstream consumers connect as ZMQ PULL clients. When consumers are
slow, the proxy detects backpressure and signals the LB to throttle incoming
data.

## Prerequisites

### 1. Build the Proxy Container

```bash
cd /path/to/ejfat_proxy
podman-hpc build -t ejfat-zmq-proxy:latest .
podman-hpc migrate ejfat-zmq-proxy:latest
```

### 2. Obtain an EJFAT URI

Get an admin URI from the EJFAT team:

```bash
export EJFAT_URI="ejfats://token@ejfat-lb.es.net:18008/lb/"
```

### 3. Set Script Directory

```bash
export E2SAR_SCRIPTS_DIR="$PWD/scripts/perlmutter"
```

### 4. Python (for consumers)

The Perlmutter `python` module includes `pyzmq`. Scripts load it automatically.
To verify manually:

```bash
module load python
python3 -c "import zmq; print(zmq.zmq_version())"
```

---

## Step-by-Step: Running the System

The system has three components that run on separate compute nodes within a
Slurm allocation. This section walks through running them manually.

### Step 1: Get a Slurm Allocation

```bash
salloc -A m5219 -N 3 -C cpu -q interactive -t 00:30:00
```

Record the node names:

```bash
NODES=($(scontrol show hostname $SLURM_JOB_NODELIST))
NODE_PROXY=${NODES[0]}
NODE_CONSUMER=${NODES[1]}
NODE_SENDER=${NODES[2]}
echo "Proxy=$NODE_PROXY  Consumer=$NODE_CONSUMER  Sender=$NODE_SENDER"
```

### Step 2: Reserve the Load Balancer

```bash
mkdir -p runs/manual_test && cd runs/manual_test
$E2SAR_SCRIPTS_DIR/minimal_reserve.sh
cat INSTANCE_URI
```

This creates an `INSTANCE_URI` file containing the session-specific EJFAT URI
with sync and data addresses.

### Step 3: Start the Proxy

```bash
srun --nodes=1 --ntasks=1 --nodelist=$NODE_PROXY \
    bash -c "cd $PWD && $E2SAR_SCRIPTS_DIR/run_proxy.sh" \
    > proxy_wrapper.log 2>&1 &
PROXY_PID=$!
```

The proxy:
1. Generates `perlmutter_config.yaml` from the template + environment variables.
2. Starts the `ejfat_zmq_proxy` binary inside a podman container.
3. Registers as a worker with the LB.
4. Binds a ZMQ PUSH socket on port 5555 (default).
5. Writes stats to `proxy.log`.

Wait for registration (look for "Worker registered"):

```bash
sleep 10
grep "Worker registered" proxy.log
```

**Environment variables** that tune proxy behavior:

| Variable | Default | Description |
|----------|---------|-------------|
| `BUFFER_SIZE` | 20000 | Ring buffer capacity (events) |
| `ZMQ_HWM` | 10000 | ZMQ send high-water mark |
| `ZMQ_PORT` | 5555 | ZMQ PUSH endpoint port |
| `ZMQ_SNDBUF` | 2097152 | ZMQ send buffer (bytes, 0=OS default) |
| `BP_THRESHOLD` | 0.95 | Buffer fill level that triggers `ready=0` |
| `BP_PERIOD` | 50 | Backpressure reporting interval (ms) |
| `BP_LOG_INTERVAL` | 100 | Log backpressure state every N reports |
| `DATA_PORT` | 10000 | UDP port for LB data plane |
| `RECV_THREADS` | 4 | E2SAR receiver threads |

### Step 4: Start the Consumer(s)

```bash
export PROXY_NODE=$NODE_PROXY
export ZMQ_PORT=5555

# Single consumer (fast)
srun --nodes=1 --ntasks=1 --nodelist=$NODE_CONSUMER \
    bash -c "cd $PWD && $E2SAR_SCRIPTS_DIR/run_consumer.sh" \
    > consumer_wrapper.log 2>&1 &
```

**Consumer options** (`run_consumer.sh`):

| Option | Default | Description |
|--------|---------|-------------|
| `--delay MS` | 0 | Artificial per-message delay (for backpressure testing) |
| `--rcvhwm N` | 1000 | ZMQ receive high-water mark |
| `--rcvbuf BYTES` | 0 (OS) | Kernel TCP receive buffer size |
| `--log-name NAME` | consumer | Log filename prefix (`NAME.log`) |

**Multiple consumers**: ZMQ PUSH/PULL distributes events round-robin across all
connected PULL sockets. When a consumer's buffers fill, ZMQ skips it:

```bash
# Fast consumer
srun --overlap --nodes=1 --ntasks=1 --nodelist=$NODE_CONSUMER \
    bash -c "cd $PWD && $E2SAR_SCRIPTS_DIR/run_consumer.sh --log-name consumer_fast" \
    > consumer_fast_wrapper.log 2>&1 &

# Slow consumer (same node, use --overlap)
srun --overlap --nodes=1 --ntasks=1 --nodelist=$NODE_CONSUMER \
    bash -c "cd $PWD && $E2SAR_SCRIPTS_DIR/run_consumer.sh --delay 100 --rcvhwm 2 --log-name consumer_slow" \
    > consumer_slow_wrapper.log 2>&1 &
```

### Step 5: Send Data

```bash
srun --nodes=1 --ntasks=1 --nodelist=$NODE_SENDER \
    bash -c "cd $PWD && $E2SAR_SCRIPTS_DIR/minimal_sender.sh --rate 10 --num 200"
```

**Sender options** (`minimal_sender.sh`):

| Option | Default | Description |
|--------|---------|-------------|
| `--rate RATE` | 1 | Sending rate in Gbps |
| `--num COUNT` | 100 | Number of events |
| `--length LENGTH` | 1048576 | Event size in bytes |
| `--mtu MTU` | 9000 | MTU size |
| `--ipv6` | off | Use IPv6 |
| `--no-monitor` | off | Disable memory monitoring |

For sustained load testing, use the soak sender:

```bash
srun --nodes=1 --ntasks=1 --nodelist=$NODE_SENDER \
    bash -c "cd $PWD && $E2SAR_SCRIPTS_DIR/run_soak_sender.sh --duration 300 --rate 10"
```

This loops `minimal_sender.sh` in batches of 100 events for the specified duration.

### Step 6: Monitor

In another terminal:

```bash
# Proxy stats (fill level, backpressure state)
tail -f runs/manual_test/proxy.log

# Consumer throughput
tail -f runs/manual_test/consumer.log
```

Key proxy log fields:
- `fill=N%` — ring buffer utilization
- `ready=1/0` — whether proxy is accepting more data from LB
- `control=X.X` — PID control signal sent to LB (0.0-1.0)

### Step 7: Cleanup

```bash
# Stop background processes
kill $PROXY_PID $CONSUMER_PID 2>/dev/null
wait

# Free the LB reservation
cd runs/manual_test
$E2SAR_SCRIPTS_DIR/minimal_free.sh
```

---

## Pipeline Mode (ZMQ Source → EJFAT → ZMQ Sink)

For testing with a ZMQ data source (instead of e2sar_perf), use the pipeline:

```
pipeline_sender.py → zmq_ejfat_bridge → EJFAT LB → proxy → consumer/validator
```

This requires 4 nodes. The bridge receives from a ZMQ PUSH socket and
injects events into EJFAT via the E2SAR Segmenter.

```bash
salloc -A m5219 -N 4 -C cpu -q interactive -t 00:30:00

NODES=($(scontrol show hostname $SLURM_JOB_NODELIST))
NODE_SENDER=${NODES[0]}   # pipeline_sender.py
NODE_BRIDGE=${NODES[1]}   # zmq_ejfat_bridge
NODE_PROXY=${NODES[2]}    # ejfat_zmq_proxy
NODE_VALIDATOR=${NODES[3]} # pipeline_validator.py

# Reserve LB, start proxy (same as above)...

# Start bridge (connects to sender, segments into EJFAT)
export SENDER_NODE=$NODE_SENDER
export SENDER_ZMQ_PORT=5556
srun --nodes=1 --ntasks=1 --nodelist=$NODE_BRIDGE \
    bash -c "cd $PWD && $E2SAR_SCRIPTS_DIR/run_zmq_ejfat_bridge.sh" \
    > bridge_wrapper.log 2>&1 &

# Start validator (connects to proxy, checks sequence/checksum)
srun --nodes=1 --ntasks=1 --nodelist=$NODE_VALIDATOR \
    bash -c "cd $PWD && $E2SAR_SCRIPTS_DIR/run_pipeline_validator.sh --expected 1000 --timeout 60" \
    > validator_wrapper.log 2>&1 &

# Start sender (binds ZMQ PUSH, bridge connects to it)
srun --nodes=1 --ntasks=1 --nodelist=$NODE_SENDER \
    bash -c "cd $PWD && $E2SAR_SCRIPTS_DIR/run_pipeline_sender.sh --count 1000 --size 4096 --rate 100"
```

---

## Configuration Reference

The proxy reads `perlmutter_config.yaml`, generated automatically by
`generate_config.sh` from `config/perlmutter.yaml.template`. All settings
can be overridden via environment variables before starting the proxy.

### EJFAT Connection

| Variable | Default | Description |
|----------|---------|-------------|
| `EJFAT_URI` | (required) | Load balancer URI (from `INSTANCE_URI`) |
| `DATA_IP` | auto-detected | IP address for receiving LB data |
| `DATA_PORT` | 10000 | UDP port for LB data plane |
| `VALIDATE_CERT` | true | Validate LB TLS certificate |
| `USE_IPV6` | false | Use IPv6 for data plane |
| `RECV_THREADS` | 4 | E2SAR receiver threads |
| `RCV_BUF_SIZE` | 10485760 | UDP socket receive buffer (bytes) |

### ZMQ

| Variable | Default | Description |
|----------|---------|-------------|
| `ZMQ_PORT` | 5555 | PUSH socket port |
| `ZMQ_HWM` | 10000 | Send high-water mark (messages) |
| `ZMQ_IO_THREADS` | 2 | ZMQ I/O threads |
| `ZMQ_SNDBUF` | 2097152 | SO_SNDBUF via ZMQ_SNDBUF (bytes) |
| `POLL_SLEEP` | 50 | Buffer poll sleep (microseconds) |

### Backpressure

| Variable | Default | Description |
|----------|---------|-------------|
| `BP_PERIOD` | 50 | Feedback reporting interval (ms) |
| `BP_THRESHOLD` | 0.95 | Buffer fill fraction that triggers `ready=0` |
| `BP_LOG_INTERVAL` | 100 | Log state every N reports |
| `PID_SETPOINT` | 0.5 | Target buffer fill level (0.0-1.0) |
| `PID_KP` | 1.0 | Proportional gain |
| `PID_KI` | 0.0 | Integral gain |
| `PID_KD` | 0.0 | Derivative gain |

### Buffer

| Variable | Default | Description |
|----------|---------|-------------|
| `BUFFER_SIZE` | 20000 | Ring buffer capacity (events) |
| `RECV_TIMEOUT` | 100 | Event receive timeout (ms) |

---

## Tuning for Backpressure

| Goal | Adjust |
|------|--------|
| Trigger backpressure sooner | Lower `BUFFER_SIZE` (e.g., 100) and `ZMQ_HWM` (e.g., 5) |
| More aggressive throttling | Lower `BP_THRESHOLD` (e.g., 0.5) |
| Higher throughput | Raise `BUFFER_SIZE` (20000+), `ZMQ_HWM` (10000+), `ZMQ_SNDBUF` |
| Constrain consumer receive rate | Set `--rcvhwm` low and `--rcvbuf` small on consumer |
| Smoother control signal | Tune PID: start with `KP=1.0, KI=0.0, KD=0.0` |

## Troubleshooting

### No events received by consumer

1. Check proxy registered: `grep "Worker registered" proxy.log`
2. Check sender completed: `grep "Completed" minimal_sender.log`
3. Check consumer connected: `grep "Connected" consumer.log`
4. Verify `PROXY_NODE` and `ZMQ_PORT` match the proxy's endpoint.

### Backpressure not triggering

1. Lower `BUFFER_SIZE` and `ZMQ_HWM` (both to 5-100 range).
2. Increase consumer `--delay`.
3. Set `--rcvhwm 2 --rcvbuf 131072` on consumer to limit TCP buffers.
4. Use `run_soak_sender.sh` for sustained load (burst sends may complete before
   buffers fill).

### Proxy crash / segfault

1. Check `proxy_wrapper.log` for container startup errors.
2. Verify `INSTANCE_URI` exists and contains a valid session URI.
3. Ensure the container image is migrated: `podman-hpc migrate ejfat-zmq-proxy:latest`.

### LB reservation stuck

```bash
cd runs/slurm_job_<JOBID>
../../scripts/perlmutter/minimal_free.sh
```
