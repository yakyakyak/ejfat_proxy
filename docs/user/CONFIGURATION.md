# Configuration Reference

Environment variables used to configure `ejfat_zmq_proxy` on Perlmutter.
The proxy reads `perlmutter_config.yaml`, generated automatically by
`generate_config.sh` from `config/perlmutter.yaml.template`. All settings
can be overridden via environment variables before starting the proxy.

For implementation details, see [CONFIG_UPDATE.md](CONFIG_UPDATE.md).

## EJFAT Connection

| Variable | Default | Description |
|----------|---------|-------------|
| `EJFAT_URI` | (required) | Load balancer URI (from `INSTANCE_URI`) |
| `DATA_IP` | auto-detected | IP address for receiving LB data |
| `DATA_PORT` | 10000 | UDP port for LB data plane |
| `VALIDATE_CERT` | true | Validate LB TLS certificate |
| `USE_IPV6` | false | Use IPv6 for data plane |
| `RECV_THREADS` | 4 | E2SAR receiver threads |
| `RCV_BUF_SIZE` | 10485760 | UDP socket receive buffer (bytes) |

## ZMQ

| Variable | Default | Description |
|----------|---------|-------------|
| `ZMQ_PORT` | 5555 | PUSH socket port |
| `ZMQ_HWM` | 10000 | Send high-water mark (messages) |
| `ZMQ_IO_THREADS` | 2 | ZMQ I/O threads |
| `ZMQ_SNDBUF` | 2097152 | SO_SNDBUF via ZMQ_SNDBUF (bytes) |
| `POLL_SLEEP` | 50 | Buffer poll sleep (microseconds) |

## Backpressure

| Variable | Default | Description |
|----------|---------|-------------|
| `BP_PERIOD` | 50 | Feedback reporting interval (ms) |
| `BP_THRESHOLD` | 0.95 | Buffer fill fraction that triggers `ready=0` |
| `BP_LOG_INTERVAL` | 100 | Log state every N reports |
| `PID_SETPOINT` | 0.5 | Target buffer fill level (0.0-1.0) |
| `PID_KP` | 1.0 | Proportional gain |
| `PID_KI` | 0.0 | Integral gain |
| `PID_KD` | 0.0 | Derivative gain |

## Buffer

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
