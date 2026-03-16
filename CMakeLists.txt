cmake_minimum_required(VERSION 3.15)
project(ejfat_zmq_proxy VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Add compiler warnings
add_compile_options(-Wall -Wextra -Wpedantic)

# Find dependencies
find_package(PkgConfig REQUIRED)

# Use freshly built E2SAR (both library and headers)
set(E2SAR_INCLUDE_DIRS
    "/Users/yak/Projects/E2SAR/include"
    "/Users/yak/Projects/E2SAR/build/src"
    "/Users/yak/Projects/E2SAR/build/src/grpc")  # For generated protobuf headers
set(E2SAR_LIBRARY_DIRS "/Users/yak/Projects/E2SAR/build/src")
set(E2SAR_LIBRARIES "/Users/yak/Projects/E2SAR/build/src/libe2sar.a")

pkg_check_modules(YAMLCPP REQUIRED yaml-cpp)
pkg_check_modules(LIBZMQ REQUIRED libzmq)
pkg_check_modules(CPPZMQ REQUIRED cppzmq)
pkg_check_modules(GRPC REQUIRED grpc++)
pkg_check_modules(PROTOBUF REQUIRED protobuf)
pkg_check_modules(ABSL_LOG REQUIRED absl_log)
pkg_check_modules(ABSL_LOG_INTERNAL REQUIRED absl_log_internal_message)

# Use Boost from e2sar-dev conda environment (matches E2SAR build)
set(BOOST_ROOT "/opt/anaconda3/envs/e2sar-dev")
set(Boost_NO_SYSTEM_PATHS ON)
find_package(Boost 1.89 REQUIRED COMPONENTS thread chrono program_options url log filesystem)

# Override protobuf to use conda version (matches E2SAR)
set(Protobuf_INCLUDE_DIR "/opt/anaconda3/envs/e2sar-dev/include")
set(Protobuf_LIBRARY "/opt/anaconda3/envs/e2sar-dev/lib/libprotobuf.dylib")

# Include directories (conda protobuf FIRST to override Homebrew)
include_directories(
    /opt/anaconda3/envs/e2sar-dev/include
    ${CMAKE_SOURCE_DIR}/include
    ${CMAKE_SOURCE_DIR}
    ${E2SAR_INCLUDE_DIRS}
    ${Boost_INCLUDE_DIRS}
    ${LIBZMQ_INCLUDE_DIRS}
    ${CPPZMQ_INCLUDE_DIRS}
    ${YAMLCPP_INCLUDE_DIRS}
    ${GRPC_INCLUDE_DIRS}
    ${PROTOBUF_INCLUDE_DIRS}
)

# Link directories
link_directories(
    ${E2SAR_LIBRARY_DIRS}
    ${LIBZMQ_LIBRARY_DIRS}
    ${YAMLCPP_LIBRARY_DIRS}
    ${GRPC_LIBRARY_DIRS}
    ${PROTOBUF_LIBRARY_DIRS}
)

# Add subdirectories
add_subdirectory(src)
add_subdirectory(bin)

# Installation
install(DIRECTORY include/ DESTINATION include)
install(DIRECTORY config/ DESTINATION share/ejfat_zmq_proxy/config)
install(PROGRAMS scripts/test_receiver.py DESTINATION bin)
