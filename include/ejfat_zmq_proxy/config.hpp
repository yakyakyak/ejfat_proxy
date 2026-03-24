#pragma once

#include <string>
#include <cstdint>

namespace ejfat_zmq_proxy {

struct SchedulingConfig {
    float weight{1.0f};
    float min_factor{0.5f};
    float max_factor{2.0f};
};

struct EjfatConfig {
    std::string uri;
    bool use_cp{true};
    std::string worker_name{"zmq-proxy-1"};
    uint16_t data_port{10000};
    std::string data_ip;  // Empty = auto-detect
    bool with_lb_header{false};  // Set to true for local testing without real LB
    uint32_t num_recv_threads{1};
    uint32_t event_timeout_ms{500};
    uint32_t rcv_socket_buf_size{3145728};  // 3MB default
    bool validate_cert{true};
    SchedulingConfig scheduling;
};

struct ZmqConfig {
    std::string push_endpoint{"tcp://*:5555"};
    int send_hwm{1000};
    int io_threads{1};
    uint32_t poll_sleep_us{100};
    int linger_ms{0};
    int sndbuf{0};  // 0 = OS default
};

struct PidConfig {
    float setpoint{0.5f};
    float kp{1.0f};
    float ki{0.0f};
    float kd{0.0f};
    float integral_limit{10.0f};
};

struct BackpressureConfig {
    uint32_t period_ms{100};
    float ready_threshold{0.95f};
    uint32_t log_interval{50};
    float control_min{0.0f};
    float control_max{1.0f};
    PidConfig pid;
};

struct BufferConfig {
    size_t size{2000};
    int recv_timeout_ms{100};
};

struct LoggingConfig {
    uint32_t drop_warn_interval{1000};
    uint32_t progress_interval{10000};
};

struct ProxyConfig {
    EjfatConfig ejfat;
    ZmqConfig zmq;
    BackpressureConfig backpressure;
    BufferConfig buffer;
    LoggingConfig logging;

    static ProxyConfig loadFromYaml(const std::string& filepath);
    static ProxyConfig getDefault();
    void validate() const;
};

} // namespace ejfat_zmq_proxy
