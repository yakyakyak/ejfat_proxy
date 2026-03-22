# Main proxy executable
add_executable(ejfat_zmq_proxy ejfat_zmq_proxy.cpp)

target_link_libraries(ejfat_zmq_proxy
    ejfat_zmq_proxy_lib
)

# ZMQ -> EJFAT bridge (used as N2 in the pipeline test)
add_executable(zmq_ejfat_bridge zmq_ejfat_bridge.cpp)

target_link_libraries(zmq_ejfat_bridge
    ejfat_zmq_proxy_lib
)

# Pipeline test components (C++ sender and validator)
add_executable(pipeline_sender pipeline_sender.cpp)
target_link_libraries(pipeline_sender ejfat_zmq_proxy_lib)

add_executable(pipeline_validator pipeline_validator.cpp)
target_link_libraries(pipeline_validator ejfat_zmq_proxy_lib)

# Install
install(TARGETS ejfat_zmq_proxy zmq_ejfat_bridge pipeline_sender pipeline_validator DESTINATION bin)
