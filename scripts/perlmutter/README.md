# Perlmutter SLURM Test Scripts for EJFAT ZMQ Proxy

This directory contains SLURM batch scripts and supporting tools for running end-to-end tests of the EJFAT ZMQ Proxy on NERSC Perlmutter with real EJFAT load balancers.

## Architecture

The test infrastructure runs three components across three compute nodes:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Node 0        │     │   Node 1        │     │   Node 2        │
│                 │     │                 │     │                 │
│  ejfat_zmq_     │ ZMQ │  test_receiver  │     │  e2sar_perf     │
│  proxy          │────▶│  .py            │     │  sender         │
│                 │     │                 │     │                 │
│  ▲              │     │                 │     │  │              │
│  │ EJFAT/UDP    │     │                 │     │  │ EJFAT/UDP    │
│  │              │     │                 │     │  ▼              │
└──┼──────────────┘     └─────────────────┘     └──┼──────────────┘
   │                                                │
   │            ┌──────────────────┐                │
   └────────────│  EJFAT Load      │◀───────────────┘
                │  Balancer        │
                │  (external)      │
                └──────────────────┘
```

- **Node 0**: Runs `ejfat_zmq_proxy` - receives reassembled events from EJFAT LB, pushes to ZMQ
- **Node 1**: Runs `test_receiver.py` - ZMQ PULL consumer (validates end-to-end delivery)
- **Node 2**: Runs `e2sar_perf --send` - sends data through EJFAT load balancer

## Prerequisites

### On Perlmutter Login Node

1. **Build the proxy**:
   ```bash
   cd /path/to/ejfat_proxy
   mkdir -p build && cd build
   cmake .. && make -j8
   ```

2. **Set EJFAT_URI** (obtain from EJFAT admin):
   ```bash
   export EJFAT_URI="ejfats://token@lb.es.net:443/lb/xyz?sync=..."
   ```

3. **Set E2SAR_SCRIPTS_DIR**:
   ```bash
   export E2SAR_SCRIPTS_DIR="$PWD/scripts/perlmutter"
   ```

### Python Dependencies

The NERSC Python module includes `pyzmq`, so no additional installation is required. The scripts automatically load `module load python` on compute nodes.

## File Structure

```
scripts/perlmutter/
├── README.md                           # This file
├── submit.sh                           # Convenience submission wrapper
├── perlmutter_proxy_test.sh            # Main SLURM batch script
├── perlmutter_backpressure_test.sh     # Backpressure variant (slow consumer)
├── run_proxy.sh                        # Proxy startup wrapper
├── run_consumer.sh                     # Consumer startup wrapper
├── generate_config.sh                  # Dynamic YAML config generator
├── minimal_reserve.sh                  # LB reservation (from E2SAR)
├── minimal_free.sh                     # LB release (from E2SAR)
└── minimal_sender.sh                   # e2sar_perf sender (from E2SAR)

config/
└── perlmutter.yaml.template            # Config template for Perlmutter
```

## Usage

### Quick Start with Convenience Wrapper

```bash
# Normal test (100 events, 1 Gbps)
./scripts/perlmutter/submit.sh --account m4386

# Custom sender parameters
./scripts/perlmutter/submit.sh --account m4386 --rate 5 --num 1000

# Backpressure test (slow consumer triggers backpressure)
./scripts/perlmutter/submit.sh --account m4386 --test-type backpressure

# Pre-reserve load balancer before submitting
./scripts/perlmutter/submit.sh --account m4386 --pre-reserve
```

### Direct SLURM Submission

```bash
# Normal test
sbatch -A m4386 scripts/perlmutter/perlmutter_proxy_test.sh --rate 1 --num 100

# Backpressure test
sbatch -A m4386 scripts/perlmutter/perlmutter_backpressure_test.sh --rate 1 --num 100
```

### Sender Options

Both test scripts accept the following options (passed to `minimal_sender.sh`):

- `--rate RATE` - Sending rate in Gbps (default: 1)
- `--num COUNT` - Number of events to send (default: 100)
- `--length LENGTH` - Event buffer length in bytes (default: 1048576)
- `--mtu MTU` - MTU size in bytes (default: 9000)

### SLURM Options

The convenience wrapper accepts standard SLURM options:

- `--nodes N`, `-N N` - Number of nodes (default: 3)
- `--time T`, `-t T` - Time limit (default: 00:30:00)
- `--qos Q`, `-q Q` - QOS (default: debug)

## Test Phases

### Normal Test (`perlmutter_proxy_test.sh`)

1. **Reserve LB** - Creates fresh reservation via `minimal_reserve.sh`
2. **Start Proxy** - Launches proxy on Node 0 (background)
3. **Start Consumer** - Launches ZMQ consumer on Node 1 (background)
4. **Wait for Registration** - 15s delay for proxy to register with LB
5. **Run Sender** - Sends data on Node 2 (foreground, waits for completion)
6. **Drain Buffers** - 5s delay for proxy/consumer to process remaining data
7. **Display Summary** - Shows log excerpts and metrics

### Backpressure Test (`perlmutter_backpressure_test.sh`)

Same as normal test, but consumer runs with `--delay 10` (10ms per message) to artificially slow consumption and trigger backpressure feedback.

Expected behavior: Proxy should detect slow consumption, send "not ready" signals to LB, and throttle incoming data.

## Monitoring

### During Job Execution

```bash
# Monitor job queue
squeue -u $USER

# Tail proxy log (replace JOBID)
tail -f runs/slurm_job_<JOBID>/proxy.log

# Tail consumer log
tail -f runs/slurm_job_<JOBID>/consumer.log
```

### After Completion

All logs are saved to `runs/slurm_job_<JOBID>/`:

- `proxy.log` - Proxy output (events received, backpressure state)
- `consumer.log` - ZMQ consumer output (messages received)
- `minimal_sender.log` - Sender output (events sent, completion status)
- `proxy_wrapper.log` - Proxy wrapper script output
- `consumer_wrapper.log` - Consumer wrapper script output
- `perlmutter_config.yaml` - Generated configuration
- `INSTANCE_URI` - LB reservation details

### Key Metrics

**Proxy log:**
- `Events received: N` - Total events from E2SAR reassembler
- `Events sent: N` - Total messages sent to ZMQ
- `Backpressure state: READY/NOT_READY` - Worker readiness
- `Control signal: X.XX` - Backpressure feedback value

**Consumer log:**
- `Received N messages` - Total ZMQ messages received
- `Throughput: X msg/s` - Message rate

**Sender log:**
- `Events sent: N` - Total events sent
- `Rate: X Gbps` - Actual sending rate

## Configuration

The test scripts use `config/perlmutter.yaml.template` which is processed by `generate_config.sh` to substitute environment variables:

**Auto-detected:**
- `DATA_IP` - Source IP for route to LB (via `ip route get`)
- `EJFAT_URI` - From `INSTANCE_URI` file

**Customizable via environment:**
- `ZMQ_PORT` (default: 5555)
- `DATA_PORT` (default: 10000)
- `RECV_THREADS` (default: 4)
- `BUFFER_SIZE` (default: 20000)
- `ZMQ_HWM` (default: 10000)

See `config/perlmutter.yaml.template` for full list.

## Cleanup

The scripts automatically:
- Free LB reservations on job completion (via EXIT trap)
- Stop proxy and consumer processes gracefully (SIGTERM, then SIGKILL)

Manual cleanup (if job is cancelled unexpectedly):
```bash
cd runs/slurm_job_<JOBID>
../../scripts/perlmutter/minimal_free.sh
```

## Troubleshooting

### Proxy fails to start

**Check:**
- Binary exists: `ls -l build/bin/ejfat_zmq_proxy`
- Config is valid: `cat runs/slurm_job_<JOBID>/perlmutter_config.yaml`
- Proxy log: `cat runs/slurm_job_<JOBID>/proxy.log`

### Consumer fails to start

**Check:**
- Python module loaded: `module list` (should show `python`)
- pyzmq available: `python3 -c "import zmq"`
- Consumer log: `cat runs/slurm_job_<JOBID>/consumer.log`

### No data received

**Check:**
- Proxy registered with LB: Look for "Worker registered" in `proxy.log`
- Sender completed: Check `minimal_sender.log` for "Events sent: N"
- Network connectivity: Ensure firewall allows UDP on data_port (default: 10000)

### Backpressure not triggered

**Check:**
- Consumer delay is set: `grep delay consumer_wrapper.log`
- Buffer fill level: `grep "fill level" proxy.log`
- Control signal: `grep "control" proxy.log`

## Customization

### Using Different E2SAR Image

```bash
export E2SAR_IMAGE="ibaldin/e2sar:0.3.2"
./scripts/perlmutter/submit.sh --account m4386
```

### Custom Configuration Values

```bash
export ZMQ_HWM=50000
export BUFFER_SIZE=100000
export BP_THRESHOLD=0.8
./scripts/perlmutter/submit.sh --account m4386
```

### Running with More Nodes

The scripts can be adapted for multi-receiver or multi-sender tests by modifying the SBATCH directives and node assignments in the batch scripts.

## References

- E2SAR zero_to_hero scripts: `/Users/yak/Projects/Claude/ejfat_epics/external/e2sar/scripts/zero_to_hero/`
- EJFAT documentation: [https://github.com/JeffersonLab/E2SAR](https://github.com/JeffersonLab/E2SAR)
- NERSC Perlmutter docs: [https://docs.nersc.gov/systems/perlmutter/](https://docs.nersc.gov/systems/perlmutter/)

## Support

For issues with:
- **EJFAT/E2SAR**: Contact EJFAT team
- **Perlmutter**: NERSC help desk
- **ejfat_zmq_proxy**: See main project README.md
