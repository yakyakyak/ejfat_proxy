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
   - **Solution**: Regenerated protobuf files from `/Users/yak/Projects/E2SAR/udplbd2/proto/loadbalancer/loadbalancer.proto`

2. **Protobuf Version Mismatch**: Generated files required protobuf 6.33.5, but system had 6.33.4.
   - **Solution**: Modified version check in `grpc/loadbalancer.pb.h` to accept both 6.33.4 and 6.33.5

3. **Include Path Configuration**: Added conda environment's include paths.
   - **Solution**: Updated `CMakeLists.txt` to include `/opt/anaconda3/envs/e2sar-dev/include`

## Build Commands

### macOS (native)

```bash
cd build
PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:/opt/anaconda3/envs/e2sar-dev/lib/pkgconfig" \
cmake .. \
  -DE2SAR_ROOT=/Users/yak/Projects/E2SAR \
  -DE2SAR_LIB_PATH=/Users/yak/Projects/E2SAR/build/src/libe2sar.a
make -j8
```

`-DE2SAR_ROOT` and `-DE2SAR_LIB_PATH` are required. The default `/usr/local` E2SAR uses deprecated `boost::asio::io_service` which conflicts with conda Boost 1.89.

### Container (Perlmutter)

```bash
podman build -t ejfat-zmq-proxy:latest .
podman-hpc migrate ejfat-zmq-proxy:latest
```

See `BUILD_NOTES.md` for the full container dependency map, linker-ordering fix, and Containerfile.

### Reconfigure / clean rebuild

```bash
cd build
rm CMakeCache.txt
PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:/opt/anaconda3/envs/e2sar-dev/lib/pkgconfig" \
cmake .. -DE2SAR_ROOT=... -DE2SAR_LIB_PATH=...
make -j8
```

## Testing

Full test results are in `TEST_REPORT.md`. Quick summary:

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
