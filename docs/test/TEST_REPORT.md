# EJFAT ZMQ Proxy — Test Reports

Test results are split by platform:

| Report | Platform | Status |
|--------|----------|--------|
| [TEST_REPORT_MACOS.md](TEST_REPORT_MACOS.md) | macOS (local, loopback, no EJFAT LB) | ✅ Current |
| TEST_REPORT_PERLMUTTER.md | Perlmutter HPC (100G HDR IB, real EJFAT LB) | Pending |

---

## Quick Status (March 22, 2026)

### macOS

| Test | Result |
|------|--------|
| Build | ✅ |
| ZMQ component | ✅ |
| E2SAR back-to-back | ✅ |
| B2B backpressure suite (5 tests) | ✅ |
| Pipeline data integrity | ✅ |
| Multi-worker bridge, 100K msg/s, 42 Gbps | ✅ |

### Perlmutter

| Test | Result |
|------|--------|
| Build (container) | ✅ |
| Backpressure suite (6 tests, LB mode) | ✅ |
| Pipeline data integrity (4-node) | ✅ |
| Multi-worker bridge throughput sweep | Pending |
