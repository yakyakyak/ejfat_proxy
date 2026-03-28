# EJFAT ZMQ Proxy User Guide

How to set up and run the EJFAT ZMQ proxy with senders and receivers on NERSC
Perlmutter.

## Architecture

```
Full Pipeline (Linear View)
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

In the full pipeline, a ZMQ source pushes events to `zmq_ejfat_bridge`, which
segments and forwards them over UDP to the EJFAT load balancer. The LB
distributes reassembled events to `ejfat_zmq_proxy` via E2SAR. The proxy
buffers events in a lock-free ring buffer and pushes them out over a ZMQ PUSH
socket. Downstream consumers connect as ZMQ PULL clients. When consumers are
slow, the proxy detects backpressure and signals the LB to throttle incoming
data.

## Documents

| Document | Description |
|----------|-------------|
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
