# Distributed Scripts — Implementation & Design Reference

## Overview

This document describes the design, architecture, and implementation decisions behind `scripts/MacOS/distributed/` — a set of bash scripts that orchestrate the EJFAT ZMQ pipeline across four separate remote hosts using SSH. It covers the problems the scripts solve, how they solve them, what non-obvious decisions were made and why, and where the implementation diverges from the existing Perlmutter scripts it was modelled on.

---

## Context: What Problem This Solves

The project had two orchestration tiers before this work:

1. **`scripts/MacOS/local_*`** — runs all four components on localhost. Simple: subprocesses, local log files, local PIDs. No network concerns.
2. **`scripts/perlmutter/`** — runs on Perlmutter supercomputer via Slurm. Uses `srun` for remote execution and a Lustre/GPFS shared filesystem for inter-node coordination via signal files (`proxy_go_N`, `proxy_ready_N`, etc.).

Neither works for the scenario of running pipeline components on arbitrary remote machines where:
- There is no shared filesystem between nodes
- There is no Slurm job manager
- SSH is the only inter-node transport available from the controlling machine

The distributed scripts fill this gap, targeting the common case where a developer has SSH access to 4 machines (HPC interactive nodes, cloud VMs, lab servers) and wants to run a real multi-node pipeline test without a Slurm batch job.

---

## File Structure

```
scripts/MacOS/distributed/
├── distributed_env.sh          # Configuration layer: all shared variables
├── ssh_common.sh               # Library layer: SSH helper functions
├── start_proxy.sh              # Thin launch scripts (one per component)
├── start_bridge.sh
├── start_sender.sh
├── start_validator.sh
├── run_pipeline.sh             # Orchestrator: sequences component launches
├── stop_all.sh                 # Teardown: SIGTERM all remote components
└── status.sh                   # Status: pgrep on each host

config/
└── distributed.yaml.template   # Unified proxy config template (B2B + LB)
```

This is a **three-layer architecture**:

```
┌─────────────────────────────────────┐
│  Orchestration  (run_pipeline.sh)   │  launches start_*.sh in sequence
├─────────────────────────────────────┤
│  Component scripts  (start_*.sh)    │  one responsibility each
├─────────────────────────────────────┤
│  Library  (ssh_common.sh)           │  reusable SSH primitives
├─────────────────────────────────────┤
│  Configuration  (distributed_env.sh)│  all shared state in one place
└─────────────────────────────────────┘
```

This mirrors the Perlmutter pattern (`bp_common.sh` = library, `bp_testN.sh` = scripts) but adds an explicit configuration layer, because the distributed case has more machine-specific values (host addresses, binary paths, network IPs) that need to be overridable without editing the scripts.

---

## Core Design Decision: SSH Log Streaming vs. File-Based IPC

The Perlmutter scripts coordinate through signal files on a shared GPFS filesystem:

```bash
# Suite writes to trigger proxy start for test N:
echo "BUFFER_SIZE=100 ZMQ_HWM=5" > "$JOB_DIR/proxy_go_N"

# Coordinator detects file, starts proxy, then writes:
echo "$PROXY_PID" > "$JOB_DIR/proxy_ready_N"
```

This is elegant on Perlmutter because all nodes mount the same Lustre filesystem. Without a shared filesystem, this approach requires setting up NFS, rsync polling, or a message broker — all far too heavyweight for the use case.

**The alternative used here:** run each remote component as a background SSH session with its stdout/stderr piped to a local log file on the controlling machine:

```bash
ssh user@host "stdbuf -oL /path/to/binary args" >> local.log 2>&1 &
SSH_PID=$!
```

This gives the orchestrator:
- **Real-time log access** — the log file is local; no SSH round-trip to read it
- **Process liveness detection** — `kill -0 $SSH_PID` checks if the SSH session (and therefore the remote process) is still alive
- **Readiness detection** — `grep -q "pattern" local.log` on the local file, polled in a loop
- **Exit code propagation** — `wait $SSH_PID` returns the remote process's exit code

The core readiness polling function (`dist_poll_log`) is essentially identical to `wait_proxy_ready()` in `local_pipeline_test.sh`, just operating on a local log file fed by SSH instead of a local process:

```bash
# local_pipeline_test.sh (local process)
"$PROXY_BIN" -c "$config" >> "$log" 2>&1 &
PROXY_PID=$!

# ssh_common.sh (remote process via SSH)
ssh user@host "stdbuf -oL $bin -c $config" >> "$log" 2>&1 &
DIST_PROXY_SSH_PID=$!
```

The rest of the orchestration is identical.

---

## The `stdbuf -oL` Requirement

This is the most subtle technical requirement in the entire implementation.

When a C++ program writes to `stdout`, the C library (`libc`) chooses a buffering mode based on whether `stdout` is connected to a TTY:
- **TTY** (interactive terminal): **line-buffered** — each `\n` flushes the buffer immediately
- **Pipe** (including SSH): **block-buffered** — data accumulates until the buffer is full (~4–8 KB)

The remote command runs through SSH, which means its stdout is a pipe, not a TTY. Without intervention, a line like:

```
All components started
```

(31 characters) would sit in a 4096-byte block buffer for seconds — or until the next 4 KB of output accumulated — before being flushed to the SSH pipe and written to the local log file. Since the orchestrator polls the log for this exact string with a 30-second timeout, buffering can cause a false timeout.

`stdbuf -oL` (part of GNU coreutils) overrides the buffering mode for the child process's stdout to line-buffered, regardless of whether it's connected to a TTY. The `-o` flag targets stdout specifically; `-L` means line-buffered.

```bash
ssh user@host "stdbuf -oL $REMOTE_PROXY_BIN -c $config" >> proxy.log 2>&1 &
```

**Why not use `ssh -t` (pseudo-TTY)?** `ssh -t` allocates a pseudo-terminal on the remote side, which makes the process think it's connected to a TTY and enables line buffering. However, pseudo-TTY allocation has side effects: it merges stdout and stderr, adds carriage returns to output, and can cause issues with background SSH sessions (the shell may become a session leader and orphan the subprocess on disconnect). For automation, `stdbuf -oL` is cleaner.

---

## PID Tracking Strategy

The scripts track two PID types per component:

**SSH PID** (`*_ssh.pid`): the local SSH process PID on the controlling machine. Used for:
- `kill -0 $SSH_PID` — liveness check during readiness polling
- `wait $SSH_PID` — propagate remote exit code to local script
- `kill -TERM $SSH_PID` — signals the SSH connection to close

**Remote PID** (`*_remote.pid`): the actual binary's PID on the remote host. Obtained via:
```bash
dist_ssh "$HOST" "pgrep -f '$BINARY' | head -1"
```
Used by `stop_all.sh` and `status.sh` for direct `pkill` targeting. This is a best-effort lookup; the remote PID is fetched shortly after launch and may be stale if the process restarts.

**Why both?** The SSH PID alone isn't sufficient for cleanup — killing the local SSH process closes the connection cleanly but may not send a signal to the remote subprocess. The remote process may continue running as an orphan. Explicit `pkill -f $BINARY` on the remote host is necessary for reliable cleanup.

---

## Startup Order and the Settle Sleeps

The correct startup order for the pipeline is:

```
Proxy → Validator → Sender → Bridge
```

**Proxy first** is obvious: it opens the UDP port that the bridge targets and the ZMQ port that the validator connects to.

**Validator before sender** ensures the validator's ZMQ PULL socket is connected to the proxy before messages start flowing. ZMQ PUSH sockets drop messages if no PULL sockets are connected (depending on HWM). With a 1-second settle after starting the validator, the `connect()` call has completed before the sender generates its first message.

**Sender before bridge** is the subtlest ordering constraint. The sender uses ZMQ PUSH and *binds* to `tcp://*:5556`; the bridge uses ZMQ PULL and *connects* to the sender's address. The bridge's `connect()` is called at startup and is asynchronous — ZMQ silently retries in the background. However, if the sender hasn't bound yet when the bridge's first ZMQ poll fires (within ~10 ms of bridge startup), those early messages are lost. The 1-second settle between starting the sender and starting the bridge ensures the sender is bound and ZMQ's internal reconnect loop has succeeded.

The `run_pipeline.sh` phase structure:
```
Phase 1: Proxy     → wait for "All components started"   (blocking, up to 30s)
Phase 2: Validator → 1s settle
Phase 3: Sender    → 1s settle (binds ZMQ)
Phase 4: Bridge    → wait for "ZMQ EJFAT Bridge started" (blocking, up to 15s)
Phase 5: Wait for sender to exit
Phase 6: Sleep DRAIN_TIME, wait for validator to exit
```

---

## Config Generation: Unified Template

The project previously had two config templates:
- `perlmutter.yaml.template` — LB mode (`use_cp: true`, `with_lb_header: false`)
- `perlmutter_b2b.yaml.template` — B2B mode (`use_cp: false`, `with_lb_header: true`)

Rather than create a third template, the distributed scripts introduce a single unified `config/distributed.yaml.template` that parameterizes the two mode-switching fields:

```yaml
use_cp: ${USE_CP}
with_lb_header: ${WITH_LB_HEADER}
```

`dist_generate_config()` in `ssh_common.sh` sets these based on `PIPELINE_MODE`:

```bash
if [[ "${PIPELINE_MODE}" == "lb" ]]; then
    USE_CP="true"
    WITH_LB_HEADER="false"
else  # b2b
    USE_CP="false"
    WITH_LB_HEADER="true"
fi
```

This avoids template duplication and makes mode switching a single environment variable change. The trade-off is that `envsubst` substitutes `${USE_CP}` literally as the string `"true"` or `"false"`, which YAML parses as a boolean — this works correctly with yaml-cpp's type coercion, but is worth noting if the template is used with a stricter YAML parser.

---

## B2B URI Construction

In back-to-back mode, no load balancer is involved. The Segmenter (in the bridge) needs a URI telling it where to send UDP packets. The URI's `data=` parameter points directly at the proxy's reassembler:

```
ejfat://b2b-dist@${PROXY_DATA_IP}:9876/lb/1?data=${PROXY_DATA_IP}:${DATA_PORT}&sync=${PROXY_DATA_IP}:19523
```

The authority (`${PROXY_DATA_IP}:9876`) would be the control plane address in LB mode; in B2B mode it is never contacted (port 9876 doesn't need to be open). The `sync=` address (port 19523) is the E2SAR sync channel, also unused with `--no-cp`. These dummy values are required by the E2SAR URI parser but have no effect in B2B mode.

This is the same pattern used by `local_pipeline_test.sh`, `local_b2b_test.sh`, and `b2b_generate_config.sh` — all use the same URI structure with `127.0.0.1` replaced by the actual proxy IP.

---

## SENDER_IP Auto-Detection

The bridge needs to know the sender's IP address to construct the ZMQ connect endpoint: `tcp://${SENDER_IP}:${SENDER_ZMQ_PORT}`. This must be the sender's IP as reachable from the bridge host.

If `SENDER_IP` is not set, `dist_resolve_sender_ip()` fetches it:

```bash
dist_ssh "${SENDER_HOST}" "hostname -I | awk '{print \$1}'"
```

`hostname -I` returns all non-loopback IP addresses in no guaranteed order; `awk '{print $1}'` takes the first one. This heuristic works on single-homed machines. On multi-homed nodes, the user should set `SENDER_IP` explicitly.

The analogous step in the Perlmutter scripts uses `ip route get` to find the source IP for packets destined to a specific target — a more precise approach but one that requires knowing the routing target in advance.

---

## Cleanup and Teardown

The orchestrator registers a `trap cleanup EXIT INT TERM` handler that runs on any exit, including Ctrl+C. The cleanup function stops components in reverse pipeline order to avoid confusing log output from the surviving components:

```
Bridge → Sender → Validator → Proxy
```

Bridge first: stops new data from entering the pipeline. Proxy last: keeps the ZMQ output socket alive as long as possible so in-flight events can drain.

Each `dist_stop_remote` call:
1. Sends `pkill -TERM -f $BINARY` via SSH (graceful shutdown)
2. Polls `pgrep -f $BINARY` for up to 10 seconds
3. Sends `pkill -KILL -f $BINARY` if still running (force kill)
4. Kills the local SSH PID (closes the log streaming connection)

After all components are stopped, `dist_collect_logs` pulls any remote log files from the run directories on each host (supplementing the locally-streamed logs with any writes that went to remote files).

---

## run_pipeline.sh vs. start_*.sh: When to Use Each

`run_pipeline.sh` owns the full lifecycle, including the cleanup trap. The individual `start_*.sh` scripts create their own (separate) run directories and don't install a cleanup trap.

This design means each `start_*.sh` is safe to run standalone for debugging a single component, but the orchestrator must be the one managing cleanup when running the full pipeline. To avoid multiple run directories when using the orchestrator, `DIST_RUN_ID` is set once by `dist_init()` in `run_pipeline.sh`, and all subsequent `source`s of `ssh_common.sh` (one per component script) detect the existing `DIST_RUN_ID` and reuse it.

Actually the current implementation inlines the component launch logic directly in `run_pipeline.sh` rather than calling the component scripts. This avoids the `DIST_RUN_ID` coordination problem at the cost of some code duplication. The component scripts exist as standalone tools only. If a future refactor makes the component scripts aware of an external `DIST_RUN_ID`, the orchestrator could delegate to them cleanly.

---

## status.sh and Idempotent Status Checks

`status.sh` reads host information from the run directory's `*.host` files (or falls back to `distributed_env.sh`), then performs a single SSH command per host:

```bash
dist_ssh "${host}" "pgrep -af '${binary}' | head -1"
```

`pgrep -af` matches against the full command line, not just the process name. This is important because the binary name `ejfat_zmq_proxy` might match unintended processes if searched by name alone. The `-a` flag prints the full command line alongside the PID, which helps distinguish multiple concurrent runs.

The status check deliberately uses two SSH connections per host when a process is not found (one for pgrep, one for `true` to check reachability), to distinguish between `STOPPED` (host reachable, process absent) and `UNREACHABLE` (host not reachable). A single-connection design would report `STOPPED` for unreachable hosts, which is misleading.

---

## The `distributed_env.local.sh` Pattern

`distributed_env.sh` ships with all variables defaulting to empty or conservative values. Users are instructed to copy it to `distributed_env.local.sh` and fill in their machine-specific values.

`distributed_env.local.sh` is listed in `.gitignore`. This prevents accidental commits of host addresses, usernames, or EJFAT credentials.

`dist_init()` loads the local override if it exists, falling back to the canonical `distributed_env.sh`:

```bash
if [[ -f "${script_dir}/distributed_env.local.sh" ]]; then
    source "${script_dir}/distributed_env.local.sh"
elif [[ -f "${script_dir}/distributed_env.sh" ]]; then
    source "${script_dir}/distributed_env.sh"
fi
```

This pattern is identical to how `CMakeUserPresets.json` (gitignored) overrides `CMakePresets.json` (tracked) in the build system.

---

## Coordination API: Design for Future Implementation

The shell scripts are coordination-by-convention: each script follows informal contracts (log patterns for readiness, exit codes for results, PID files for tracking). A future REST/WebSocket API would formalize these contracts and make them accessible to a web GUI.

### State machine

Each component follows:
```
IDLE → STARTING → RUNNING → STOPPED
                         ↘ FAILED
```

The pipeline as a whole follows:
```
UNCONFIGURED → CONFIGURED → LAUNCHING → RUNNING → DRAINING → COMPLETED
                                                ↘ FAILED
```

Transitions map directly to the existing script phases: LAUNCHING = Phases 1–4 of `run_pipeline.sh`, DRAINING = Phase 6.

### API design (FastAPI)

```
GET  /api/v1/config                   — current PipelineConfig as JSON
PUT  /api/v1/config                   — update config (Pydantic validation)
POST /api/v1/config/validate          — run dist_preflight equivalent
POST /api/v1/pipeline/launch          — launch full pipeline, returns run_id
POST /api/v1/pipeline/stop            — teardown (equivalent to stop_all.sh)
GET  /api/v1/pipeline/status          — pipeline + component states
GET  /api/v1/pipeline/result          — PASS/FAIL + validator exit code
POST /api/v1/components/{name}/start  — launch single component
POST /api/v1/components/{name}/stop   — stop single component
GET  /api/v1/components/{name}/logs   — recent log lines (?tail=N)
GET  /api/v1/runs                     — run history
ws   /ws/logs/{component}             — real-time log stream
ws   /ws/status                       — real-time state change events
```

### WebSocket log streaming

The shell scripts stream logs to local files via SSH pipe. The API wraps this in an async file tailer:

```
SSH process → local log file → asyncio file watcher → WebSocket clients
```

This is the same data flow as the shell scripts, just with WebSocket consumers instead of `tail -f` in a terminal. The implementation would use `asyncio.create_subprocess_exec("ssh", ...)` to manage the SSH session and `asyncio` file I/O to detect new log lines.

### Implementation stack

- **Framework**: Python FastAPI with uvicorn (async, native WebSocket, auto OpenAPI docs)
- **SSH management**: `asyncio.create_subprocess_exec` wrapping the same SSH commands as the shell scripts (avoids paramiko dependency, ensures behavioral parity)
- **Config validation**: Pydantic models with the same constraints as `dist_preflight()`
- **State persistence**: in-memory during a session; JSON file for run history

The API is designed so the web GUI communicates exclusively via HTTP/WebSocket — no shell scripts run in the browser. The server-side implementation shells out to the same SSH commands.

---

## Comparison with Perlmutter Scripts

| Concern | Perlmutter (`scripts/perlmutter/`) | Distributed (`scripts/MacOS/distributed/`) |
|---------|-------------------------------------|---------------------------------------------|
| Remote execution | `srun` (Slurm step) | `ssh` |
| Inter-node coordination | Signal files on shared GPFS | SSH-piped log streaming |
| Readiness detection | Poll remote signal file | Poll local log file fed by SSH pipe |
| Config upload | Shared filesystem (file exists on all nodes) | `scp` from local machine to remote host |
| Container runtime | `podman-hpc` | None (direct binary execution) |
| Log collection | Files on shared filesystem | `scp` from remote run directories |
| Process tracking | `PROXY_PID` in coordinator script | SSH PIDs (local) + `pgrep` (remote) |
| Multi-test sequencing | `proxy_coordinator.sh` file-based IPC | Not applicable (single-test design) |
| Cleanup | `_bp_cleanup()` in `bp_common.sh` | `cleanup()` trap in `run_pipeline.sh` |
| Readiness pattern (proxy) | `"Worker registered"` (LB mode) | `"All components started"` (B2B mode) |

The critical structural difference is the absence of a shared filesystem. Every inter-node communication mechanism in the Perlmutter scripts that writes a file is replaced with either an SSH command or a locally-captured log stream in the distributed scripts.

---

## Known Limitations

### No multi-test sequencing

The Perlmutter backpressure suite (`perlmutter_backpressure_suite.sh`) runs 5–6 tests sequentially against different proxy configs using a persistent coordinator. The distributed scripts have no equivalent — each `run_pipeline.sh` invocation runs a single test. Multi-test sequencing could be added as a wrapper script.

### SENDER_IP auto-detection is heuristic

`hostname -I | awk '{print $1}'` takes the first non-loopback IP. On multi-homed nodes this may not be the IP reachable from the bridge host. The Perlmutter scripts use the more precise `ip route get` approach, which finds the source IP for a specific destination.

### Remote PIDs may be stale

`dist_remote_pid()` fetches the PID at component startup. If the remote process crashes and restarts (or a different instance starts), the stored PID is wrong. The `stop_all.sh` script uses `pkill -f $BINARY` rather than the stored PID, which avoids this issue at the cost of killing all matching processes.

### No port conflict detection

If previous test components are still running on the remote hosts, `start_proxy.sh` will fail because `DATA_PORT` is already bound. A pre-flight port check (`ss -ulnp | grep $PORT`) would catch this, but is not currently implemented.

---

## File Reference

| File | Key functions | Lines |
|------|--------------|-------|
| `distributed_env.sh` | Variable declarations | ~90 |
| `ssh_common.sh` | `dist_init`, `dist_ssh`, `dist_ssh_bg`, `dist_poll_log`, `dist_stop_remote`, `dist_generate_config`, `dist_construct_b2b_uri`, `dist_preflight` | ~270 |
| `start_proxy.sh` | Config gen → upload → launch → poll | ~90 |
| `start_bridge.sh` | URI construction → IP resolution → launch → poll | ~85 |
| `start_sender.sh` | Launch foreground or background | ~75 |
| `start_validator.sh` | Launch background | ~65 |
| `run_pipeline.sh` | 7-phase orchestration loop + cleanup trap | ~185 |
| `stop_all.sh` | Read host files → SIGTERM loop | ~65 |
| `status.sh` | pgrep per host → status table | ~85 |
| `config/distributed.yaml.template` | Unified proxy YAML (B2B + LB) | ~75 |
