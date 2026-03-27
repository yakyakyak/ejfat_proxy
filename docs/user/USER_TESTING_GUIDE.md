# EJFAT ZMQ Proxy User Guide

How to set up and run the EJFAT ZMQ proxy with senders and receivers on NERSC
Perlmutter.

## Architecture

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

## Documents

| Document | Description |
|----------|-------------|
| [PERLMUTTER_QUICKSTART.md](PERLMUTTER_QUICKSTART.md) | Prerequisites, container build, and step-by-step srun workflow (3 nodes) |
| [PERLMUTTER_PIPELINE.md](PERLMUTTER_PIPELINE.md) | 4-node pipeline mode: ZMQ source → bridge → EJFAT → proxy → validator |
| [PERLMUTTER_INTERACTIVE.md](PERLMUTTER_INTERACTIVE.md) | SSH-based interactive workflow — start each component manually in a separate terminal |
| [CONFIGURATION.md](CONFIGURATION.md) | Full environment variable reference and backpressure tuning recipes |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Diagnostic steps for common issues |

## Related Guides

| Document | Description |
|----------|-------------|
| [PIPELINE_GUIDE.md](PIPELINE_GUIDE.md) | Pipeline architecture and multi-worker design |
| [LOCAL_TESTING.md](LOCAL_TESTING.md) | macOS local back-to-back testing (no Perlmutter) |
| [DISTRIBUTED_PIPELINE.md](DISTRIBUTED_PIPELINE.md) | Multi-machine distributed pipeline testing |
| [DOCKER_SCRIPTS.md](DOCKER_SCRIPTS.md) | Docker-based run scripts |
