# Perlmutter Interactive / Login-Node Workflow

Running each pipeline component manually in a separate terminal via SSH, rather
than through `srun`.

You still need a Slurm allocation so that the containers can access the HSN
network; the difference is that you SSH directly to each node and run the
wrapper script there instead of using `srun`.

## Startup Order

Start components in this order and wait for each readiness signal before
proceeding:

```
1. Proxy     — registers with LB, binds ZMQ PUSH :5555
2. Validator — connects to proxy ZMQ PULL (must see proxy bound first)
3. Bridge    — starts ZMQ PULL workers, waits to connect to sender
4. Sender    — binds ZMQ PUSH :5556, sleeps 5 s, then sends
```

The 5-second delay built into `run_pipeline_sender.sh` gives the bridge time
to connect after the sender binds. Do not start the sender until the bridge is
running.

## Step 0: Allocate Nodes and Prepare

From a login node, get an interactive allocation and record the node names:

```bash
salloc -A <your_account> -N 4 -C cpu -q interactive -t 01:00:00

NODES=($(scontrol show hostname $SLURM_JOB_NODELIST))
NODE_PROXY=${NODES[0]}
NODE_VALIDATOR=${NODES[1]}
NODE_BRIDGE=${NODES[2]}
NODE_SENDER=${NODES[3]}
echo "Proxy=$NODE_PROXY  Validator=$NODE_VALIDATOR  Bridge=$NODE_BRIDGE  Sender=$NODE_SENDER"
```

Create a working directory and reserve the LB:

```bash
mkdir -p runs/interactive_test && cd runs/interactive_test
$E2SAR_SCRIPTS_DIR/minimal_reserve.sh
cat INSTANCE_URI    # verify the file was created
```

## Step 1: Start the Proxy (Terminal 1)

SSH to the proxy node, set env vars, and run the proxy wrapper:

```bash
ssh $NODE_PROXY
cd /path/to/runs/interactive_test

# Required (already set by salloc env — verify with: echo $SLURM_JOB_ID)
# Optional overrides:
export RECV_THREADS=4
export BUFFER_SIZE=20000
export ZMQ_HWM=10000
export ZMQ_PORT=5555

/path/to/scripts/perlmutter/run_proxy.sh
```

The proxy generates `proxy_config.yaml`, starts the container, and prints:

```
Worker registered
```

Wait for this message before starting the validator.

## Step 2: Start the Validator (Terminal 2)

SSH to the validator node:

```bash
ssh $NODE_VALIDATOR
cd /path/to/runs/interactive_test

export PROXY_NODE=<proxy-node-hostname>   # e.g., nid001234
export ZMQ_PORT=5555                       # must match proxy

/path/to/scripts/perlmutter/run_pipeline_validator.sh --expected 1000 --timeout 120
```

The validator connects to the proxy's ZMQ PUSH socket and waits for messages.
It prints a summary (sequence gaps, checksum errors) when it receives the
expected count or the timeout expires.

## Step 3: Start the Bridge (Terminal 3)

SSH to the bridge node. The bridge connects to the sender's ZMQ PUSH socket,
which the sender will bind in the next step:

```bash
ssh $NODE_BRIDGE
cd /path/to/runs/interactive_test

export SENDER_NODE=<sender-node-hostname>  # e.g., nid005678
export SENDER_ZMQ_PORT=5556
export BRIDGE_WORKERS=1     # ZMQ PULL threads (default: 1)
export BRIDGE_SOCKETS=16    # E2SAR UDP send threads (default: 16)

/path/to/scripts/perlmutter/run_zmq_ejfat_bridge.sh
```

The bridge reads `INSTANCE_URI`, constructs the EJFAT URI, and prints:

```
ZMQ EJFAT Bridge started
```

## Step 4: Start the Sender (Terminal 4, Last)

SSH to the sender node. The sender binds the ZMQ PUSH socket, sleeps 5 s to
let the bridge connect, then begins sending:

```bash
ssh $NODE_SENDER
cd /path/to/runs/interactive_test

export SENDER_ZMQ_PORT=5556

/path/to/scripts/perlmutter/run_pipeline_sender.sh --count 1000 --size 4096 --rate 100
```

The sender exits when all messages have been sent. Monitor progress in the
proxy and bridge terminals while it runs.

## Monitoring

While the pipeline runs, check in any terminal:

```bash
# Proxy buffer fill level and backpressure state
tail -f runs/interactive_test/proxy.log

# Bridge throughput (received from ZMQ / enqueued to Segmenter)
tail -f runs/interactive_test/bridge.log

# Validator receipt progress
tail -f runs/interactive_test/validator.log
```

## Cleanup

After the sender exits, stop the remaining components and free the LB:

```bash
# In each terminal: Ctrl-C to stop proxy, validator, and bridge

# Free the LB reservation (from the working directory)
cd runs/interactive_test
$E2SAR_SCRIPTS_DIR/minimal_free.sh
```
