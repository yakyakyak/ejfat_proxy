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
find_library(E2SAR_LIB_PATH NAMES e2sar
    PATHS "${E2SAR_ROOT}/lib" "${E2SAR_ROOT}/lib/${CMAKE_LIBRARY_ARCHITECTURE}"
          "${E2SAR_ROOT}/build/src"
    NO_DEFAULT_PATH REQUIRED)
set(E2SAR_LIBRARIES "${E2SAR_LIB_PATH}")

pkg_check_modules(YAMLCPP REQUIRED yaml-cpp)
pkg_check_modules(LIBZMQ REQUIRED libzmq)
find_package(cppzmq QUIET)
if(NOT cppzmq_FOUND)
    pkg_check_modules(CPPZMQ REQUIRED cppzmq)
endif()
pkg_check_modules(GRPC REQUIRED grpc++)
pkg_check_modules(PROTOBUF REQUIRED protobuf)
pkg_check_modules(ABSL_LOG REQUIRED absl_log)
pkg_check_modules(ABSL_LOG_INTERNAL REQUIRED absl_log_internal_message)

find_package(Boost 1.81 REQUIRED COMPONENTS thread chrono program_options url log filesystem)

# Protobuf generated headers for E2SAR's loadbalancer.proto.
# The proxy does not compile the .cc files (they are baked into libe2sar.a),
# but it does need the headers.  Three modes:
#   bundled    (default) — use checked-in grpc/ headers; requires protobuf 6.33.4-6.33.5
#   e2sar      — use headers from E2SAR's build/install tree; always ABI-compatible
#   regenerate — run protoc at configure time; requires -DPROTO_FILE=
set(PROTOBUF_HEADERS "bundled" CACHE STRING
    "Protobuf header source: bundled | e2sar | regenerate")
set_property(CACHE PROTOBUF_HEADERS PROPERTY STRINGS bundled e2sar regenerate)

if(PROTOBUF_HEADERS STREQUAL "e2sar")
    if(EXISTS "${E2SAR_ROOT}/include/grpc/loadbalancer.pb.h")
        set(GRPC_INCLUDE_DIR "${E2SAR_ROOT}/include")
        message(STATUS "PROTOBUF_HEADERS=e2sar: using installed headers from ${GRPC_INCLUDE_DIR}/grpc/")
    elseif(EXISTS "${E2SAR_ROOT}/build/src/grpc/loadbalancer.pb.h")
        set(GRPC_INCLUDE_DIR "${E2SAR_ROOT}/build/src")
        message(STATUS "PROTOBUF_HEADERS=e2sar: using build-tree headers from ${GRPC_INCLUDE_DIR}/grpc/")
    else()
        message(FATAL_ERROR
            "PROTOBUF_HEADERS=e2sar: no grpc headers found under E2SAR_ROOT=${E2SAR_ROOT}\n"
            "  Expected: ${E2SAR_ROOT}/include/grpc/loadbalancer.pb.h (installed)\n"
            "         or ${E2SAR_ROOT}/build/src/grpc/loadbalancer.pb.h (build tree)")
    endif()
elseif(PROTOBUF_HEADERS STREQUAL "regenerate")
    set(PROTO_FILE "" CACHE FILEPATH
        "Path to loadbalancer.proto (required when PROTOBUF_HEADERS=regenerate)")
    if(NOT PROTO_FILE OR NOT EXISTS "${PROTO_FILE}")
        message(FATAL_ERROR
            "PROTOBUF_HEADERS=regenerate requires -DPROTO_FILE=/path/to/loadbalancer.proto")
    endif()
    find_program(PROTOC_EXE protoc REQUIRED)
    find_program(GRPC_CPP_PLUGIN grpc_cpp_plugin REQUIRED)
    get_filename_component(PROTO_DIR "${PROTO_FILE}" DIRECTORY)
    set(GRPC_INCLUDE_DIR "${CMAKE_BINARY_DIR}/grpc_gen")
    file(MAKE_DIRECTORY "${GRPC_INCLUDE_DIR}/grpc")
    execute_process(
        COMMAND ${PROTOC_EXE} -I "${PROTO_DIR}" --cpp_out="${GRPC_INCLUDE_DIR}/grpc" "${PROTO_FILE}"
        RESULT_VARIABLE _protoc_rc1)
    execute_process(
        COMMAND ${PROTOC_EXE} -I "${PROTO_DIR}"
            --grpc_out="${GRPC_INCLUDE_DIR}/grpc"
            --plugin=protoc-gen-grpc=${GRPC_CPP_PLUGIN} "${PROTO_FILE}"
        RESULT_VARIABLE _protoc_rc2)
    if(NOT _protoc_rc1 EQUAL 0 OR NOT _protoc_rc2 EQUAL 0)
        message(FATAL_ERROR "protoc generation failed (rc1=${_protoc_rc1} rc2=${_protoc_rc2})")
    endif()
    message(STATUS "PROTOBUF_HEADERS=regenerate: generated headers in ${GRPC_INCLUDE_DIR}/grpc/")
else()
    # bundled (default)
    set(GRPC_INCLUDE_DIR "${CMAKE_SOURCE_DIR}")
    message(STATUS "PROTOBUF_HEADERS=bundled: using checked-in grpc/ headers (requires protobuf 6.33.4-6.33.5)")
endif()

# Include directories
include_directories(
    ${CMAKE_SOURCE_DIR}/include
    ${GRPC_INCLUDE_DIR}
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
install(PROGRAMS scripts/MacOS/test_receiver.py DESTINATION bin)
