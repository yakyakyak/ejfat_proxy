#include "ejfat_zmq_proxy/config.hpp"
#include <yaml-cpp/yaml.h>
#include <stdexcept>
#include <sstream>

namespace ejfat_zmq_proxy {

ProxyConfig ProxyConfig::loadFromYaml(const std::string& filepath) {
    ProxyConfig config;

    try {
        YAML::Node root = YAML::LoadFile(filepath);

        // Load EJFAT config
        if (root["ejfat"]) {
            const auto& ejfat = root["ejfat"];
            if (ejfat["uri"]) config.ejfat.uri = ejfat["uri"].as<std::string>();
            if (ejfat["use_cp"]) config.ejfat.use_cp = ejfat["use_cp"].as<bool>();
            if (ejfat["worker_name"]) config.ejfat.worker_name = ejfat["worker_name"].as<std::string>();
            if (ejfat["data_port"]) config.ejfat.data_port = ejfat["data_port"].as<uint16_t>();
            if (ejfat["data_ip"]) config.ejfat.data_ip = ejfat["data_ip"].as<std::string>();
            if (ejfat["with_lb_header"]) config.ejfat.with_lb_header = ejfat["with_lb_header"].as<bool>();
            if (ejfat["num_recv_threads"]) config.ejfat.num_recv_threads = ejfat["num_recv_threads"].as<uint32_t>();
            if (ejfat["event_timeout_ms"]) config.ejfat.event_timeout_ms = ejfat["event_timeout_ms"].as<uint32_t>();
            if (ejfat["rcv_socket_buf_size"]) config.ejfat.rcv_socket_buf_size = ejfat["rcv_socket_buf_size"].as<uint32_t>();
            if (ejfat["validate_cert"]) config.ejfat.validate_cert = ejfat["validate_cert"].as<bool>();

            if (ejfat["scheduling"]) {
                const auto& sched = ejfat["scheduling"];
                if (sched["weight"]) config.ejfat.scheduling.weight = sched["weight"].as<float>();
                if (sched["min_factor"]) config.ejfat.scheduling.min_factor = sched["min_factor"].as<float>();
                if (sched["max_factor"]) config.ejfat.scheduling.max_factor = sched["max_factor"].as<float>();
            }
        }

        // Load ZMQ config
        if (root["zmq"]) {
            const auto& zmq = root["zmq"];
            if (zmq["push_endpoint"]) config.zmq.push_endpoint = zmq["push_endpoint"].as<std::string>();
            if (zmq["send_hwm"]) config.zmq.send_hwm = zmq["send_hwm"].as<int>();
            if (zmq["io_threads"]) config.zmq.io_threads = zmq["io_threads"].as<int>();
            if (zmq["poll_sleep_us"]) config.zmq.poll_sleep_us = zmq["poll_sleep_us"].as<uint32_t>();
            if (zmq["linger_ms"]) config.zmq.linger_ms = zmq["linger_ms"].as<int>();
            if (zmq["sndbuf"]) config.zmq.sndbuf = zmq["sndbuf"].as<int>();
        }

        // Load backpressure config
        if (root["backpressure"]) {
            const auto& bp = root["backpressure"];
            if (bp["period_ms"]) config.backpressure.period_ms = bp["period_ms"].as<uint32_t>();
            if (bp["ready_threshold"]) config.backpressure.ready_threshold = bp["ready_threshold"].as<float>();
            if (bp["log_interval"]) config.backpressure.log_interval = bp["log_interval"].as<uint32_t>();
            if (bp["control_min"]) config.backpressure.control_min = bp["control_min"].as<float>();
            if (bp["control_max"]) config.backpressure.control_max = bp["control_max"].as<float>();

            if (bp["pid"]) {
                const auto& pid = bp["pid"];
                if (pid["setpoint"]) config.backpressure.pid.setpoint = pid["setpoint"].as<float>();
                if (pid["kp"]) config.backpressure.pid.kp = pid["kp"].as<float>();
                if (pid["ki"]) config.backpressure.pid.ki = pid["ki"].as<float>();
                if (pid["kd"]) config.backpressure.pid.kd = pid["kd"].as<float>();
                if (pid["integral_limit"]) config.backpressure.pid.integral_limit = pid["integral_limit"].as<float>();
            }
        }

        // Load buffer config
        if (root["buffer"]) {
            const auto& buf = root["buffer"];
            if (buf["size"]) config.buffer.size = buf["size"].as<size_t>();
            if (buf["recv_timeout_ms"]) config.buffer.recv_timeout_ms = buf["recv_timeout_ms"].as<int>();
        }

        // Load logging config
        if (root["logging"]) {
            const auto& log = root["logging"];
            if (log["drop_warn_interval"]) config.logging.drop_warn_interval = log["drop_warn_interval"].as<uint32_t>();
            if (log["progress_interval"]) config.logging.progress_interval = log["progress_interval"].as<uint32_t>();
        }

    } catch (const YAML::Exception& e) {
        throw std::runtime_error(std::string("YAML parse error: ") + e.what());
    }

    config.validate();
    return config;
}

ProxyConfig ProxyConfig::getDefault() {
    return ProxyConfig{};
}

void ProxyConfig::validate() const {
    std::ostringstream errors;

    // Validate EJFAT config
    if (ejfat.data_port < 1024 || ejfat.data_port > 65535) {
        errors << "ejfat.data_port must be in range [1024, 65535], got " << ejfat.data_port << "\n";
    }
    if (ejfat.num_recv_threads < 1 || ejfat.num_recv_threads > 128) {
        errors << "ejfat.num_recv_threads must be in range [1, 128], got " << ejfat.num_recv_threads << "\n";
    }
    if (ejfat.event_timeout_ms < 10 || ejfat.event_timeout_ms > 10000) {
        errors << "ejfat.event_timeout_ms must be in range [10, 10000], got " << ejfat.event_timeout_ms << "\n";
    }
    if (ejfat.rcv_socket_buf_size < 65536 || ejfat.rcv_socket_buf_size > 104857600) {
        errors << "ejfat.rcv_socket_buf_size must be in range [64KB, 100MB], got " << ejfat.rcv_socket_buf_size << "\n";
    }

    // Validate ZMQ config
    if (zmq.send_hwm < 1 || zmq.send_hwm > 1000000) {
        errors << "zmq.send_hwm must be in range [1, 1000000], got " << zmq.send_hwm << "\n";
    }
    if (zmq.io_threads < 1 || zmq.io_threads > 16) {
        errors << "zmq.io_threads must be in range [1, 16], got " << zmq.io_threads << "\n";
    }
    if (zmq.poll_sleep_us < 1 || zmq.poll_sleep_us > 10000) {
        errors << "zmq.poll_sleep_us must be in range [1, 10000], got " << zmq.poll_sleep_us << "\n";
    }

    // Validate backpressure config
    if (backpressure.pid.setpoint < 0.0f || backpressure.pid.setpoint > 1.0f) {
        errors << "backpressure.pid.setpoint must be in range [0.0, 1.0], got " << backpressure.pid.setpoint << "\n";
    }
    if (backpressure.ready_threshold < 0.5f || backpressure.ready_threshold > 1.0f) {
        errors << "backpressure.ready_threshold must be in range [0.5, 1.0], got " << backpressure.ready_threshold << "\n";
    }

    // Validate buffer config
    if (buffer.size < 100 || buffer.size > 1000000) {
        errors << "buffer.size must be in range [100, 1000000], got " << buffer.size << "\n";
    }

    std::string error_str = errors.str();
    if (!error_str.empty()) {
        throw std::runtime_error("Configuration validation failed:\n" + error_str);
    }
}

} // namespace ejfat_zmq_proxy
