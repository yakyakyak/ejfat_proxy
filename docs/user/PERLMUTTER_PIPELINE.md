# Perlmutter Pipeline Mode

Running the full ZMQ-source pipeline on Perlmutter: `pipeline_sender → zmq_ejfat_bridge → EJFAT LB → proxy → consumer/validator`.
For architecture details, see [PIPELINE_GUIDE.md](PIPELINE_GUIDE.md).

## Overview

```
pipeline_sender.py → zmq_ejfat_bridge → EJFAT LB → proxy → consumer/validator
```

This requires 4 nodes. The bridge receives from a ZMQ PUSH socket and
injects events into EJFAT via the E2SAR Segmenter.

## Running the Pipeline

```bash
salloc -A m5219 -N 4 -C cpu -q interactive -t 00:30:00

NODES=($(scontrol show hostname $SLURM_JOB_NODELIST))
NODE_SENDER=${NODES[0]}   # pipeline_sender.py
NODE_BRIDGE=${NODES[1]}   # zmq_ejfat_bridge
NODE_PROXY=${NODES[2]}    # ejfat_zmq_proxy
NODE_VALIDATOR=${NODES[3]} # pipeline_validator.py

# Reserve LB, start proxy (same as quickstart)...

# Start bridge (connects to sender, segments into EJFAT)
export SENDER_NODE=$NODE_SENDER
export SENDER_ZMQ_PORT=5556
# Optional: tune bridge parallelism
export BRIDGE_WORKERS=1       # ZMQ PULL worker threads (default: 1)
export BRIDGE_SOCKETS=1       # E2SAR UDP send thread pool (default: 1)
export BRIDGE_MTU=9000        # MTU in bytes (default: 9000 on Perlmutter)
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

For the SSH-based interactive version of this workflow, see
[PERLMUTTER_INTERACTIVE.md](PERLMUTTER_INTERACTIVE.md).
