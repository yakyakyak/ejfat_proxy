FROM docker.io/ibaldin/e2sar:0.3.1

# Install build tools and proxy-specific dependencies
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

# Install cppzmq (header-only; installs cppzmq.pc to /usr/local/lib/pkgconfig)
RUN git clone --depth 1 --branch v4.10.0 \
        https://github.com/zeromq/cppzmq.git /tmp/cppzmq \
    && cmake -S /tmp/cppzmq -B /tmp/cppzmq/build -DCPPZMQ_BUILD_TESTS=OFF \
    && cmake --install /tmp/cppzmq/build \
    && rm -rf /tmp/cppzmq

# Copy project source
WORKDIR /build
COPY . /build/ejfat_zmq_proxy

# Configure and build
# PKG_CONFIG_PATH: grpc++/protobuf/abseil .pc files live in /usr/local/lib/pkgconfig;
#                  e2sar.pc lives in /e2sar-install/lib/x86_64-linux-gnu/pkgconfig
# E2SAR_ROOT: overrides CMakeLists.txt default (/usr/local) for this container's layout
WORKDIR /build/ejfat_zmq_proxy
RUN PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/e2sar-install/lib/x86_64-linux-gnu/pkgconfig \
    cmake -B build -S . -DE2SAR_ROOT=/e2sar-install \
    && cmake --build build --parallel "$(nproc)"
