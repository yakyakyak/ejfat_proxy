# Source files
set(SOURCES
    config.cpp
    event_ring_buffer.cpp
    zmq_sender.cpp
    backpressure_monitor.cpp
    proxy.cpp
)

# Create library
add_library(ejfat_zmq_proxy_lib STATIC ${SOURCES})

target_link_libraries(ejfat_zmq_proxy_lib
    ${Boost_LIBRARIES}
    ${LIBZMQ_LIBRARIES}
    ${YAMLCPP_LIBRARIES}
    ${GRPC_LIBRARIES}
    ${PROTOBUF_LIBRARIES}
    ${ABSL_LOG_LIBRARIES}
    ${ABSL_LOG_INTERNAL_LIBRARIES}
    ${E2SAR_LIBRARIES}
)

target_include_directories(ejfat_zmq_proxy_lib PUBLIC
    ${CMAKE_SOURCE_DIR}/include
)
