# Troubleshooting

## No events received by consumer

1. Check proxy registered: `grep "Worker registered" proxy.log`
2. Check sender completed: `grep "Completed" minimal_sender.log`
3. Check consumer connected: `grep "Connected" consumer.log`
4. Verify `PROXY_NODE` and `ZMQ_PORT` match the proxy's endpoint.

## Backpressure not triggering

1. Lower `BUFFER_SIZE` and `ZMQ_HWM` (both to 5-100 range).
2. Increase consumer `--delay`.
3. Set `--rcvhwm 2 --rcvbuf 131072` on consumer to limit TCP buffers.
4. Use `run_soak_sender.sh` for sustained load (burst sends may complete before
   buffers fill).

## Proxy crash / segfault

1. Check `proxy_wrapper.log` for container startup errors.
2. Verify `INSTANCE_URI` exists and contains a valid session URI.
3. Ensure the container image is migrated: `podman-hpc migrate ejfat-zmq-proxy:latest`.

## LB reservation stuck

```bash
cd runs/slurm_job_<JOBID>
../../scripts/perlmutter/minimal_free.sh
```
