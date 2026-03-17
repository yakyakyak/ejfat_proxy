---
name: e2sar-build
description: Reference and rules for building ejfat_zmq_proxy against ibaldin/e2sar container images. Load this whenever working on Containerfile, CMakeLists.txt, link errors, or container build failures in this project.
---

# e2sar Container Build Reference

## Base Image Layout: `docker.io/ibaldin/e2sar:0.3.1`

- **E2SAR** installed at `/e2sar-install/` (NOT `/usr/local`):
  - Headers: `/e2sar-install/include/`
  - Library: `/e2sar-install/lib/x86_64-linux-gnu/libe2sar.a` (STATIC)
  - pkg-config: `/e2sar-install/lib/x86_64-linux-gnu/pkgconfig/e2sar.pc`
- **gRPC 1.74.1** + **Protobuf 6.31.1** + **Abseil** at `/usr/local/lib/`; `.pc` files in `/usr/local/lib/pkgconfig/`
- **Boost 1.89** CMake config at `/usr/local/lib/cmake/Boost-1.89.0/`
- `pkg-config` **NOT pre-installed** — must be added via apt
- `PKG_CONFIG_PATH` **NOT set** — must be set explicitly in every RUN command that calls cmake
- `libprotobuf32t64` (Ubuntu 3.21.x) IS pre-installed as `/usr/lib/x86_64-linux-gnu/libprotobuf.so.32` — wrong ABI; never let the linker pick this up

---

## Containerfile Rules

### Required apt packages
```
build-essential cmake pkg-config git
libyaml-cpp-dev libzmq3-dev
libssl-dev        # grpc.pc Requires.private: openssl
zlib1g-dev        # grpc.pc Requires.private: zlib
libre2-dev        # grpc.pc Requires.private: re2
libc-ares-dev     # grpc.pc Requires.private: libcares  ← NOT libcares-dev (wrong name)
```

**Why ssl/zlib/re2/c-ares**: pkg-config 1.8.1 (Ubuntu Noble) validates `Requires.private` even during existence checks. `grpc.pc` lists these as private deps — their `.pc` files must exist or `pkg_check_modules(GRPC REQUIRED grpc++)` fails with "package not found".

### cppzmq — build from source
Not in apt; installs `cppzmq.pc` to `/usr/local/lib/pkgconfig/`:
```dockerfile
RUN git clone --depth 1 --branch v4.10.0 \
        https://github.com/zeromq/cppzmq.git /tmp/cppzmq \
    && cmake -S /tmp/cppzmq -B /tmp/cppzmq/build -DCPPZMQ_BUILD_TESTS=OFF \
    && cmake --install /tmp/cppzmq/build \
    && rm -rf /tmp/cppzmq
```

### cmake configure + build command
```dockerfile
RUN PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/e2sar-install/lib/x86_64-linux-gnu/pkgconfig \
    cmake -B build -S . -DE2SAR_ROOT=/e2sar-install \
    && cmake --build build --parallel "$(nproc)"
```

---

## CMakeLists.txt Rules

### find_library for e2sar
```cmake
find_library(E2SAR_LIB_PATH NAMES e2sar
    PATHS "${E2SAR_ROOT}/lib" "${E2SAR_ROOT}/lib/${CMAKE_LIBRARY_ARCHITECTURE}"
    NO_DEFAULT_PATH REQUIRED)
```
**Never** use `NAMES e2sar libe2sar` — cmake adds `lib` prefix automatically, so `libe2sar` → searches for `liblie2sar`.

### Link order in src/CMakeLists.txt — CRITICAL
`${E2SAR_LIBRARIES}` MUST be **first** in `target_link_libraries`:
```cmake
target_link_libraries(ejfat_zmq_proxy_lib
    ${E2SAR_LIBRARIES}      # ← MUST be first
    ${Boost_LIBRARIES}
    ${LIBZMQ_LIBRARIES}
    ${YAMLCPP_LIBRARIES}
    ${GRPC_LIBRARIES}
    ${PROTOBUF_LIBRARIES}
    ${ABSL_LOG_LIBRARIES}
    ${ABSL_LOG_INTERNAL_LIBRARIES}
)
```

### Do NOT add ${Boost_LIBRARIES} to bin/CMakeLists.txt
```cmake
# CORRECT — boost already propagates transitively via ejfat_zmq_proxy_lib
target_link_libraries(ejfat_zmq_proxy
    ejfat_zmq_proxy_lib
)

# WRONG — causes boost DSOs to appear before libe2sar.a in the final link command
target_link_libraries(ejfat_zmq_proxy
    ejfat_zmq_proxy_lib
    ${Boost_LIBRARIES}   # ← never add this
)
```

---

## Root Cause: GCC Ubuntu `--as-needed`

GCC 13 on Ubuntu Noble injects `--as-needed` into every link command via the compiler spec:
```
%{!fsanitize=*:--as-needed}
```

With `--as-needed`, a DSO (`-lfoo`) is only retained in `DT_NEEDED` if an object processed **before it** (left-to-right scan) has an unresolved reference to it. References from objects appearing **after** the DSO are too late — the DSO is silently dropped.

**For this project:**
- `libe2sar.a` needs `libboost_chrono`, `libboost_thread`, `libgrpc.so`, etc.
- If those DSOs appear before `libe2sar.a` in the link command, `--as-needed` drops them because only `libejfat_zmq_proxy_lib.a` objects have been seen, and they don't call those APIs directly.
- Fix: ensure `libe2sar.a` is extracted **before** the DSOs it depends on.

**Diagnosis**: add `-- VERBOSE=1` to `cmake --build` to capture the exact linker command and verify ordering.

**Workarounds that do NOT work:**
- `-Wl,--copy-dt-needed-entries` — fixes the grpc drop but causes protobuf ABI conflicts with the pre-installed Ubuntu `libprotobuf.so.32`
- `-Wl,--no-as-needed` — works but unnecessarily bloats `DT_NEEDED`

---

## Build & Test

```bash
podman build -t ejfat-zmq-proxy:latest .

podman run --rm ejfat-zmq-proxy:latest \
    /build/ejfat_zmq_proxy/build/bin/ejfat_zmq_proxy --help
```

Successful output starts with `EJFAT ZMQ Proxy Options:`.
