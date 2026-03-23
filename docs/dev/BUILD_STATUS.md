# Build & Test Status

## Build Summary

✅ **Build Successful** — `ejfat_zmq_proxy`, `zmq_ejfat_bridge`, and `reassembler_bench` compile successfully.

### Binaries

```
build/bin/ejfat_zmq_proxy     (1.9 MB)  — main proxy
build/bin/zmq_ejfat_bridge              — ZMQ→EJFAT pipeline bridge
build/bin/reassembler_bench             — standalone E2SAR reassembler benchmark
```

### Build Issues Resolved

1. **Protobuf API Mismatch**: E2SAR library expected protobuf API with fields like `syncIpv4Address()`, `dataMinPort()`. The old generated protobuf files had different field names.
   - **Solution**: Regenerated protobuf files from E2SAR's `udplbd2/proto/loadbalancer/loadbalancer.proto`. Use `-DPROTOBUF_HEADERS=e2sar` or `-DPROTOBUF_HEADERS=regenerate` to keep in sync with any E2SAR version.

2. **Protobuf Version Mismatch**: Generated files required protobuf 6.33.5, but system had 6.33.4.
   - **Solution**: Widened the version check in `grpc/loadbalancer.pb.h` to accept 6.33.4–6.33.5. For other versions, use `-DPROTOBUF_HEADERS=e2sar` to reuse headers from the E2SAR build tree instead.

3. **Include Path Configuration**: gRPC/protobuf include paths must match the build environment.
   - **Solution**: Use `scripts/setup_env.sh` to assemble `PKG_CONFIG_PATH` automatically, or set it manually before running cmake.

## Build Commands

### Native build (any platform)

```bash
export E2SAR_ROOT=/path/to/E2SAR
source scripts/setup_env.sh          # sets PKG_CONFIG_PATH for your platform
cmake --preset macos                  # or: linux, container
cmake --build build -j
```

Use `-DPROTOBUF_HEADERS=e2sar` (the preset default) to reuse headers from your E2SAR build — this avoids the protobuf version lock in the checked-in `grpc/` headers.

### Container (Perlmutter)

```bash
podman build -t ejfat-zmq-proxy:latest .
podman-hpc migrate ejfat-zmq-proxy:latest
```

See `BUILD_NOTES.md` for the full container dependency map, linker-ordering fix, and Containerfile.

### Reconfigure / clean rebuild

```bash
rm build/CMakeCache.txt
source scripts/setup_env.sh
cmake --preset macos    # re-runs configuration with preset defaults
cmake --build build -j
```

## Testing

Full test results are in `../test/TEST_REPORT.md`. Quick summary:

- ✅ ZMQ component test (2,985 messages, 100% delivery)
- ✅ E2SAR → Proxy → ZMQ back-to-back (750 events, 0 drops)
- ✅ Full pipeline (1,000 events, sequence+checksum verified)
- ✅ Multi-worker bridge (11.5 Gbps, 0 drops)
- ✅ Local B2B backpressure suite (5 tests)
- ✅ Perlmutter backpressure suite (6 tests, with real LB)

## Configuration

Default config: `config/default.yaml` — complete 39-parameter v2.0 schema.

Key settings:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `buffer.size` | 2000 (local) / 20000 (Perlmutter) | Ring buffer capacity |
| `zmq.send_hwm` | 1000 | ZMQ send high-water mark |
| `backpressure.period_ms` | 100 | Feedback reporting interval |
| `backpressure.pid.setpoint` | 0.5 | Target buffer fill level |
| `backpressure.pid.kp/ki/kd` | 1.0/0.0/0.0 | PID gains |

## Known Warnings

- Nullability extension warnings from Abseil headers (harmless)
- Deprecation warnings for MutexLock in gRPC (harmless)

All warnings are from external libraries and do not affect functionality.
