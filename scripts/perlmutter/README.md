# Perlmutter Test Scripts

SLURM batch scripts and supporting tools for running EJFAT ZMQ Proxy tests on
NERSC Perlmutter.

For full documentation see:

- **[docs/TESTING.md](../../docs/TESTING.md)** — test descriptions, assertions, and how to run them
- **[docs/USER_GUIDE.md](../../docs/USER_GUIDE.md)** — step-by-step guide for running senders, proxy, and consumers

## Quick Reference

```bash
export EJFAT_URI="ejfats://token@ejfat-lb.es.net:18008/lb/..."
export E2SAR_SCRIPTS_DIR="$PWD/scripts/perlmutter"

# Submit a test
./scripts/perlmutter/submit.sh --account m5219 --test-type <TYPE>
```

**Test types**: `normal`, `backpressure`, `pipeline`, `backpressure-suite`, `bp1`..`bp6`

## File Layout

```
scripts/perlmutter/
  submit.sh                         # Submission wrapper for all test types
  perlmutter_backpressure_suite.sh  # Orchestrator: submits bp_test1-6 as separate jobs

  # Individual backpressure tests (self-contained Slurm scripts)
  bp_common.sh                      # Shared helpers, assertions, cleanup
  bp_test1.sh                       # Baseline (no backpressure)
  bp_test2.sh                       # Mild backpressure (activates/recovers)
  bp_test3.sh                       # Heavy backpressure (sustained saturation)
  bp_test4.sh                       # Small-event stress (64KB)
  bp_test5.sh                       # 5-minute soak (stability)
  bp_test6.sh                       # Dual-receiver fairness (fast + slow consumer)

  # Standalone tests
  perlmutter_proxy_test.sh          # Normal end-to-end test
  perlmutter_backpressure_test.sh   # Single backpressure test (configurable delay)
  perlmutter_pipeline_test.sh       # Data-integrity pipeline test (4 nodes)

  # Component wrappers (called by tests, not run directly)
  run_proxy.sh                      # Starts proxy container
  run_consumer.sh                   # Starts test_receiver.py
  run_zmq_ejfat_bridge.sh           # Starts ZMQ→EJFAT bridge
  run_pipeline_sender.sh            # Starts pipeline_sender.py
  run_pipeline_validator.sh         # Starts pipeline_validator.py
  run_soak_sender.sh                # Loops minimal_sender.sh for duration
  proxy_coordinator.sh              # Manages proxy lifecycle within srun step

  # LB management
  minimal_reserve.sh                # Reserve LB session
  minimal_free.sh                   # Free LB session
  minimal_sender.sh                 # Send events via e2sar_perf
  generate_config.sh                # Generate proxy YAML from template
```
