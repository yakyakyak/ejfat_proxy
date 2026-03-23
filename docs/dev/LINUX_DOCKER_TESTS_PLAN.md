# Plan: `scripts/linux/` Docker-Based Test Scripts

## Context

The project has test scripts for two environments:
- **`scripts/perlmutter/`** — HPC tests using Slurm + `podman-hpc` on multi-node clusters
- **`scripts/MacOS/`** — local tests running native binaries on localhost

There is no option for **Linux hosts with Docker** — the most common development/CI setup. The goal is to create `scripts/linux/` scripts that replicate the Perlmutter test scenarios but run on a single Linux host using Docker containers (no Podman, no Slurm).

## Approach

Follow the macOS script structure (single-file orchestration per test type) but replace every native binary invocation with a `docker run --network host` call. Extract shared Docker helper functions into a `docker_common.sh` library.

## Files to Create

### 1. `scripts/linux/docker_common.sh` — Shared Docker helper library

Sourced by both test scripts. Provides:

**Constants:**
- `PROXY_IMAGE=ejfat-zmq-proxy:latest` (built from `Containerfile`)
- `E2SAR_IMAGE=docker.io/ibaldin/e2sar:0.3.1a3` (upstream e2sar_perf)
- `CONSUMER_IMAGE=ejfat-test-consumer:latest` (built inline at preflight)
- Binary paths inside containers: `/build/ejfat_zmq_proxy/build/bin/{ejfat_zmq_proxy,zmq_ejfat_bridge,pipeline_sender,pipeline_validator}`

**Functions:**

| Function | Purpose |
|----------|---------|
| `docker_preflight()` | Checks Docker daemon, images exist (pulls E2SAR if missing, warns if proxy image missing with build command), builds `ejfat-test-consumer:latest` inline (`FROM python:3-slim; RUN pip install pyzmq`) if not present, checks `envsubst` and required files |
| `docker_cleanup_all()` | `docker rm -f` all test container names + kill log-follow PIDs. Used in `trap ... EXIT INT TERM` |
| `docker_start_proxy(config, log, name)` | `docker run -d --rm --name $name --network host -v dir:/job:ro $PROXY_IMAGE /build/.../ejfat_zmq_proxy -c /job/config.yaml` + `docker logs -f $name > $log &` |
| `docker_wait_proxy_ready(name, log, timeout=30)` | Polls log for "All components started", checks `docker inspect --format '{{.State.Running}}'` for early death |
| `docker_stop_container(name)` | `docker stop -t 10 $name; docker rm -f $name` + sleep 2 for port release |
| `docker_start_consumer(delay, rcvhwm, log, name)` | Runs `test_receiver.py` in `ejfat-test-consumer:latest` with the script bind-mounted |
| `docker_run_e2sar_sender(num, length, log, name)` | Foreground `docker run --rm --network host $E2SAR_IMAGE e2sar_perf --send ...` |
| `docker_soak_send(duration, ...)` | Loop calling `docker_run_e2sar_sender` for $duration seconds |
| `docker_start_bridge(zmq_endpoint, mtu, sockets, workers, log, name)` | `docker run -d --rm --name $name --network host $PROXY_IMAGE /build/.../zmq_ejfat_bridge --no-cp ...` |
| `docker_start_pipeline_sender(endpoint, count, size, rate, log, name)` | Runs C++ `pipeline_sender` in proxy container |
| `docker_start_pipeline_validator(endpoint, expected, timeout, log, name)` | Runs C++ `pipeline_validator` in proxy container |
| `docker_generate_config(out_path)` | Same `envsubst` logic as macOS scripts; exports variables, runs `envsubst < template > out` |

**Container names** (deterministic for cleanup): `ejfat-proxy-test`, `ejfat-consumer-test`, `ejfat-sender-test`, `ejfat-bridge-test`, `ejfat-pipeline-sender`, `ejfat-validator-test`

### 2. `scripts/linux/docker_b2b_test.sh` — B2B Backpressure Test Suite (5 tests)

Equivalent to `scripts/MacOS/local_b2b_test.sh` (~580 lines).

**Structure mirrors macOS script exactly:**
- Same argument parsing (`--tests`, `--soak-duration`, `--quick`)
- Same fixed local settings (DATA_IP=127.0.0.1, DATA_PORT=19522, ZMQ_PORT=5555)
- Same config template defaults
- Sources `docker_common.sh` + `bp_common.sh` (assertions only, B2B_MODE=true)
- Same 5 test scenarios with same parameters/thresholds
- Same `bp_print_summary_noexit()` usage for multi-test reporting

**Key differences from macOS:**

| macOS (native) | Linux/Docker |
|----------------|-------------|
| `"$PROXY_BIN" -c "$config" &` | `docker_start_proxy "$config" "$log" "ejfat-proxy-test"` |
| `python3 -u "$RECEIVER" ... &` | `docker_start_consumer $delay $rcvhwm "$log" "ejfat-consumer-test"` |
| `"$E2SAR_PERF_BIN" --send ...` | `docker_run_e2sar_sender $num $length "$log" "ejfat-sender-test"` |
| `kill -TERM $PID` | `docker_stop_container "ejfat-proxy-test"` |
| PID-based cleanup trap | `docker_cleanup_all()` (rm -f by name) |
| Check native binaries | Check Docker images |

### 3. `scripts/linux/docker_pipeline_test.sh` — Pipeline Data-Integrity Test

Equivalent to `scripts/MacOS/local_pipeline_test.sh` (~420 lines).

**Same phased structure:**
1. Generate config, start proxy container, wait ready
2. Start validator container (background)
3. Start bridge container (background), wait ready
4. Run sender container (foreground, blocks)
5. Drain, `docker wait ejfat-validator-test` for exit code
6. Stop remaining containers, print summary

**Key differences from macOS:**
- All 4 components (proxy, bridge, sender, validator) run in `ejfat-zmq-proxy:latest` containers
- `docker wait` replaces `wait $PID` for validator exit code
- Same bind-mount pattern for config

### 4. `scripts/linux/README.md` — Usage documentation

Prerequisites, build instructions, examples, environment variables.

## Key Design Decisions

### 1. Consumer runs in a pre-built Docker image

`ejfat-test-consumer:latest` = `python:3-slim` + pyzmq. Built automatically at preflight time (~10s one-time). Avoids requiring pyzmq on the host.

### 2. Named containers for deterministic cleanup

`docker rm -f` by name is more robust than PID-based cleanup since Docker containers can outlive shell processes.

### 3. `--network host` on all containers

Matches Perlmutter pattern, avoids port-mapping complexity. All containers share the host network namespace.

### 4. Log collection via `docker logs -f`

Background `docker logs -f $name > file 2>&1 &` for long-running containers (proxy, consumer). Log-follow PIDs tracked for cleanup.

### 5. Same test parameters as macOS

Both run on localhost. The macOS scripts already adjusted thresholds down from Perlmutter values for single-host performance.

## Container Images Used

| Image | Source | Contains |
|-------|--------|----------|
| `ejfat-zmq-proxy:latest` | `docker build -t ejfat-zmq-proxy:latest .` | proxy, bridge, pipeline_sender, pipeline_validator at `/build/ejfat_zmq_proxy/build/bin/` |
| `docker.io/ibaldin/e2sar:0.3.1a3` | Docker Hub (pull) | e2sar_perf, lbadm |
| `ejfat-test-consumer:latest` | Built inline at preflight | python:3-slim + pyzmq |

## Verification

```bash
# Build proxy image first
docker build -t ejfat-zmq-proxy:latest .

# Quick smoke test (tests 1 and 2 only)
./scripts/linux/docker_b2b_test.sh --tests 1,2 --quick

# Full B2B suite
./scripts/linux/docker_b2b_test.sh

# Pipeline test
./scripts/linux/docker_pipeline_test.sh --count 100

# Verify cleanup: start a test, Ctrl+C, confirm no orphaned containers
docker ps | grep ejfat
```

## Critical Reference Files

| File | Role |
|------|------|
| `scripts/MacOS/local_b2b_test.sh` | Primary structure template for B2B test |
| `scripts/MacOS/local_pipeline_test.sh` | Primary structure template for pipeline test |
| `scripts/MacOS/test_receiver.py` | Python consumer (bind-mounted into container) |
| `scripts/perlmutter/bp_common.sh` | Assertion library (sourced unchanged) |
| `config/perlmutter_b2b.yaml.template` | Config template (used via envsubst) |
| `Containerfile` | Container image layout, binary paths |
| `scripts/perlmutter/run_proxy.sh` | Reference for container execution pattern |
