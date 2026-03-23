# ejfat_zmq_proxy Container Build Notes

## Current Status (2026-03-16)

Build **succeeded**. The critical fix was **link ordering** — `${E2SAR_LIBRARIES}` moved to first position in `src/CMakeLists.txt`.

---

## Container Layout: `docker.io/ibaldin/e2sar:0.3.1`

- Base OS: Ubuntu Noble (24.04)
- E2SAR 0.3.1 installed at **`/e2sar-install/`** (NOT `/usr/local`):
  - Headers: `/e2sar-install/include/`
  - Library: `/e2sar-install/lib/x86_64-linux-gnu/libe2sar.a` (STATIC)
  - pkg-config: `/e2sar-install/lib/x86_64-linux-gnu/pkgconfig/e2sar.pc`
- gRPC 1.74.1 at `/usr/local/lib/` — **SHARED libraries** (`.so`)
  - `libgrpc++.so` SONAME: `libgrpc++.so.1.74`
  - `libgrpc.so` SONAME: `libgrpc.so.49` → `libgrpc.so.49.0.0`
  - `libgrpc++.so` DT_NEEDED includes: `libgrpc.so.49`, `libgpr.so.49`, many `libabsl_*.so.2505.0.0`
  - `libgrpc.so` DT_NEEDED includes: `libssl.so.3`, `libre2.so.10`, `libz.so.1`, many more
  - No DT_NEEDED for protobuf in `libgrpc.so` (protobuf statically linked into grpc, or grpc uses a separate path)
- Protobuf 6.31.1 at `/usr/local/lib/`:
  - `libprotobuf.so` SONAME: `libprotobuf.so.31.1.0` (unusual — full version as SONAME)
  - `protobuf.pc` version: `31.1.0`
- Boost 1.89 at `/usr/local/lib/` with CMake config at `/usr/local/lib/cmake/Boost-1.89.0/`
- Abseil at `/usr/local/lib/libabsl_*.so.2505.0.0`
- pkg-config files in `/usr/local/lib/pkgconfig/` (grpc++.pc, grpc.pc, gpr.pc, protobuf.pc, absl_*.pc)
- **pkg-config NOT pre-installed** — must be installed via apt
- **PKG_CONFIG_PATH not set** — must be set explicitly

### Pre-installed packages of note
- `libprotobuf32t64` (Ubuntu's protobuf 3.21.12) is pre-installed:
  - `/usr/lib/x86_64-linux-gnu/libprotobuf.so.32` SONAME: `libprotobuf.so.32`
  - This is the WRONG version — `libe2sar.a` needs protobuf 6.31.1 symbols (new TcParser ABI)
  - `TcParser::MiniParse` signature differs between versions (different argument order in mangled name)
- `libre2-10` (Ubuntu's re2 runtime)

---

## Files Modified

### `CMakeLists.txt`
- Removed `libe2sar` from `find_library NAMES` (cmake adds `lib` prefix automatically, so `libe2sar` → searches for `liblie2sar`)
- `E2SAR_ROOT` default stays `/usr/local`; container passes `-DE2SAR_ROOT=/e2sar-install`

### `src/CMakeLists.txt`
- **Critical fix**: `${E2SAR_LIBRARIES}` moved to FIRST position in `target_link_libraries`
- Reason: GCC Ubuntu 13 spec adds `--as-needed` to ALL linker invocations by default
  (`%{!fsanitize=*:--as-needed}` in GCC specs)
- With `--as-needed`, `-lgrpc` gets dropped if no proxy object DIRECTLY calls `libgrpc.so` C API
- `libe2sar.a` DOES call the C gRPC API, but was last in link order
- Fix: put `libe2sar.a` first so its symbol requirements are visible when grpc DSOs are evaluated

### `Containerfile`
- Base: `docker.io/ibaldin/e2sar:0.3.1` (pinned, not `latest`)
- Added `pkg-config` (not in base image)
- Added `libssl-dev zlib1g-dev libre2-dev libc-ares-dev` — required because Ubuntu Noble's
  pkg-config 1.8.1 resolves `Requires.private` during existence checks, and `grpc.pc` has:
  `Requires.private: libcares openssl re2 zlib` — pkg-config needs their `.pc` files to exist
- cppzmq built from source (provides `cppzmq.pc` in `/usr/local/lib/pkgconfig/`)
- cmake configure sets `PKG_CONFIG_PATH` and `E2SAR_ROOT`

---

## Debugging Journey

### Error 1: `grpc++` package not found (cmake configure)
**Root cause**: pkg-config 1.8.1 checks `Requires.private` deps even for existence checks.
`grpc.pc` has `Requires.private: libcares openssl re2 zlib` with no `.pc` files for them.
**Fix**: Install `libssl-dev zlib1g-dev libre2-dev libc-ares-dev` from apt.
(Note: `libcares-dev` is wrong name on Ubuntu Noble — must use `libc-ares-dev`)

### Error 2: `libgrpc.so: error adding symbols: DSO missing from command line`
**Root cause**: GCC Ubuntu spec adds `--as-needed` by default. With `--as-needed`:
- `-lgrpc` is evaluated when encountered in the link command (left to right)
- At that point, only `libejfat_zmq_proxy_lib.a` objects have been processed
- Those objects call gRPC C++ API (`grpc++.h`) but NOT C gRPC API (`libgrpc.so`)
- `libe2sar.a` (which calls C gRPC API) comes LAST → already past `-lgrpc` evaluation
- `-lgrpc` dropped → `libgrpc++.so` can't find `libgrpc.so.49` at runtime → link error
**Fix**: Move `${E2SAR_LIBRARIES}` (= `libe2sar.a`) FIRST in `target_link_libraries`
so its gRPC C API references are visible when `-lgrpc` is evaluated.

### Error 3 (attempted workaround, WRONG): `--copy-dt-needed-entries`
Adding `-Wl,--copy-dt-needed-entries` fixed Error 2 but caused NEW errors:
- Undefined protobuf symbols from `libe2sar.a` (TcParser::MiniParse, fixed_address_empty_string, etc.)
- Investigation: `--copy-dt-needed-entries` follows DT_NEEDED chains
- But `libe2sar.a` uses protobuf 6.31.1 ABI and `/usr/local/lib/libprotobuf.so.31.1.0` HAS these symbols
- The `--copy-dt-needed-entries` approach was abandoned in favor of the ordering fix

---

## Current Containerfile State

```dockerfile
FROM docker.io/ibaldin/e2sar:0.3.1

RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    pkg-config \
    git \
    libyaml-cpp-dev \
    libzmq3-dev \
    libssl-dev \
    zlib1g-dev \
    libre2-dev \
    libc-ares-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch v4.10.0 \
        https://github.com/zeromq/cppzmq.git /tmp/cppzmq \
    && cmake -S /tmp/cppzmq -B /tmp/cppzmq/build -DCPPZMQ_BUILD_TESTS=OFF \
    && cmake --install /tmp/cppzmq/build \
    && rm -rf /tmp/cppzmq

WORKDIR /build
COPY . /build/ejfat_zmq_proxy

WORKDIR /build/ejfat_zmq_proxy
RUN PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/e2sar-install/lib/x86_64-linux-gnu/pkgconfig \
    cmake -B build -S . -DE2SAR_ROOT=/e2sar-install \
    && cmake --build build --parallel "$(nproc)"
```

---

## Build & Test Commands

```bash
podman build -t ejfat-zmq-proxy:latest .

podman run --rm ejfat-zmq-proxy:latest \
    /build/ejfat_zmq_proxy/build/bin/ejfat_zmq_proxy --help
```

---

## Key Facts for Future Debugging

- `pkg-config --libs-only-l grpc++` DOES return `-lgrpc++ -lgrpc -labsl_statusor -lgpr ...` (full transitive list)
- `GRPC_LIBRARIES` from cmake `pkg_check_modules` contains the full transitive list
- Both `-lgrpc++` AND `-lgrpc` ARE in the cmake-generated link command
- The issue is NOT missing libraries — it's `--as-needed` DROPPING them
- `libe2sar.a` is a STATIC library (`.a`) — only symbol-dependent objects are extracted
- The proxy lib uses gRPC C++ (grpc++.h) but may not use C gRPC API (grpc.h)
- `libe2sar.a` uses BOTH gRPC C++ and C API, AND protobuf 6.31.1 API
- `/usr/local/lib/libprotobuf.so.31.1.0` has ALL the needed protobuf 6.31.1 symbols
- `/usr/lib/x86_64-linux-gnu/libprotobuf.so.32` (Ubuntu 3.21.x) has DIFFERENT symbol signatures
