cmake_minimum_required(VERSION 3.15)
project(ejfat_zmq_proxy VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Add compiler warnings
add_compile_options(-Wall -Wextra -Wpedantic)

# Find dependencies
find_package(PkgConfig REQUIRED)

# E2SAR installation (default: /usr/local as installed by ibaldin/e2sar container)
set(E2SAR_ROOT "/usr/local" CACHE PATH "E2SAR installation prefix")
set(E2SAR_INCLUDE_DIRS "${E2SAR_ROOT}/include")
set(E2SAR_LIBRARY_DIRS "${E2SAR_ROOT}/lib")
find_library(E2SAR_LIB_PATH NAMES e2sar
    PATHS "${E2SAR_ROOT}/lib" "${E2SAR_ROOT}/lib/${CMAKE_LIBRARY_ARCHITECTURE}"
    NO_DEFAULT_PATH REQUIRED)
set(E2SAR_LIBRARIES "${E2SAR_LIB_PATH}")

pkg_check_modules(YAMLCPP REQUIRED yaml-cpp)
pkg_check_modules(LIBZMQ REQUIRED libzmq)
pkg_check_modules(CPPZMQ REQUIRED cppzmq)
pkg_check_modules(GRPC REQUIRED grpc++)
pkg_check_modules(PROTOBUF REQUIRED protobuf)
pkg_check_modules(ABSL_LOG REQUIRED absl_log)
pkg_check_modules(ABSL_LOG_INTERNAL REQUIRED absl_log_internal_message)

find_package(Boost 1.74 REQUIRED COMPONENTS thread chrono program_options url log filesystem)

# Include directories
include_directories(
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
