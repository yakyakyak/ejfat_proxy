# User Documentation

---

## Step 1 — Validate locally (no load balancer)

Start here. All components run on `127.0.0.1` with the control plane disabled,
so you can verify E2SAR reassembly, ring buffer, ZMQ output, and backpressure
logic before touching a real LB.

```
  ◀───────────────────────── all on localhost (127.0.0.1) ─────────────────────────▶

sender ──ZMQ:5556──▶ zmq_ejfat_bridge ──UDP:19522──▶ ejfat_zmq_proxy ──ZMQ:5555──▶ consumer
                         (--no-cp)                     (use_cp: false)

                      No load balancer · No gRPC
```

| Document | Description |
|----------|-------------|
| [LOCAL_TESTING.md](LOCAL_TESTING.md) | Manual and scripted localhost tests — back-to-back, backpressure suite, and full pipeline data-integrity |

Once all events flow end-to-end and the backpressure suite passes, proceed to
Step 2.

---

## Step 2 — Test with a real load balancer

The pipeline topology is the same regardless of platform. The load balancer sits
in the data path, and the proxy holds an active gRPC session to report
backpressure:

```
 Node 1              Node 2                                    Node 3              Node 4

sender ──ZMQ──▶ zmq_ejfat_bridge ──UDP──▶ EJFAT LB ──UDP──▶ ejfat_zmq_proxy ──ZMQ──▶ consumer
         :5556      (CP enabled)         data plane          (CP enabled)     :5555

                                                     ◀────     backpressure   ◀─────────
```
### Option A — NERSC Perlmutter

Use `srun` or SSH to allocate compute nodes on Perlmutter, which is already
connected to the EJFAT load balancer.

| Document | Description |
|----------|-------------|
| [PERLMUTTER_PIPELINE.md](PERLMUTTER_PIPELINE.md) | Full 4-node pipeline: ZMQ source → `zmq_ejfat_bridge` → EJFAT LB → proxy → validator |
| [PERLMUTTER_INTERACTIVE.md](PERLMUTTER_INTERACTIVE.md) | SSH to each node manually in separate terminals — most control over startup order |

### Option B — Docker / Podman on DTNs connected to a real LB

If you have access to Data Transfer Nodes (DTNs) that are already connected to
an EJFAT load balancer, use the Docker/Podman scripts to run all components
without SLURM.

| Document | Description |
|----------|-------------|
| [DOCKER_SCRIPTS.md](DOCKER_SCRIPTS.md) | `docker` / `podman-hpc` run scripts for single-node or multi-node deployments on DTNs |

---

## Reference

| Document | Description |
|----------|-------------|
| [PIPELINE_GUIDE.md](PIPELINE_GUIDE.md) | Full pipeline data flow, control plane integration, and multi-worker bridge design |
| [DISTRIBUTED_PIPELINE.md](DISTRIBUTED_PIPELINE.md) | SSH-controlled multi-machine pipeline from a local workstation (no SLURM) |
| [CONFIGURATION.md](CONFIGURATION.md) | Complete YAML and CLI flag reference, environment variable overrides, and backpressure tuning recipes |
| [CONFIG_UPDATE.md](CONFIG_UPDATE.md) | Implementation notes on the configuration system (struct layout, field mapping, version history) |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Diagnostic steps for common failure modes: no events received, backpressure not triggering, container crashes |
