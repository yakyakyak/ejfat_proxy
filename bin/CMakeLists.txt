# Main executable
add_executable(ejfat_zmq_proxy ejfat_zmq_proxy.cpp)

target_link_libraries(ejfat_zmq_proxy
    ejfat_zmq_proxy_lib
)

# Install
install(TARGETS ejfat_zmq_proxy DESTINATION bin)
