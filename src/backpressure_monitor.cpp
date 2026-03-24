#include "ejfat_zmq_proxy/backpressure_monitor.hpp"
#include <iostream>
#include <chrono>

namespace ejfat_zmq_proxy {

BackpressureMonitor::BackpressureMonitor(
    const BackpressureConfig& config,
    std::shared_ptr<EventRingBuffer> buffer,
    std::shared_ptr<e2sar::LBManager> lb_manager)
    : config_(config),
      buffer_(buffer),
      lb_manager_(lb_manager) {
}

BackpressureMonitor::~BackpressureMonitor() {
    stop();
    join();
}

void BackpressureMonitor::start() {
    if (running_.exchange(true)) {
        return; // Already running
    }

    thread_ = std::make_unique<std::thread>(&BackpressureMonitor::run, this);
}

void BackpressureMonitor::stop() {
    running_.store(false);
}

void BackpressureMonitor::join() {
    if (thread_ && thread_->joinable()) {
        thread_->join();
    }
}

float BackpressureMonitor::computePID(float error) {
    // Proportional
    float p_term = config_.pid.kp * error;

    // Integral (with anti-windup clamping)
    integral_ += error;
    integral_ = std::max(-config_.pid.integral_limit, std::min(config_.pid.integral_limit, integral_));
    float i_term = config_.pid.ki * integral_;

    // Derivative
    float d_term = config_.pid.kd * (error - prev_error_);
    prev_error_ = error;

    return p_term + i_term + d_term;
}

void BackpressureMonitor::run() {
    bool has_cp = (lb_manager_ != nullptr);
    std::cout << "Backpressure monitor started (period=" << config_.period_ms << "ms, CP="
              << (has_cp ? "enabled" : "disabled") << ")" << std::endl;

    while (running_.load()) {
        // Sample queue fill level
        float fill_level = buffer_->getFillLevel();

        // Compute error from setpoint
        float error = fill_level - config_.pid.setpoint;

        // Compute control signal using PID
        float control_signal = computePID(error);

        // Clamp control signal to configured range
        control_signal = std::max(config_.control_min, std::min(config_.control_max, control_signal));

        // Store for reporting
        last_fill_percent_.store(fill_level * 100.0f);
        last_control_signal_.store(control_signal);

        // Send state to load balancer (only if CP is enabled)
        if (has_cp) {
            bool is_ready = (fill_level < config_.ready_threshold);

            try {
                lb_manager_->sendState(fill_level * 100.0f, control_signal, is_ready);
                send_state_count_++;

                if (config_.log_interval > 0 && send_state_count_ % config_.log_interval == 0) {
                    std::cout << "sendState #" << send_state_count_
                              << ": fill=" << (fill_level * 100.0f) << "%"
                              << ", control=" << control_signal
                              << ", ready=" << is_ready << std::endl;
                }
            } catch (const std::exception& e) {
                std::cerr << "Error sending state to LB: " << e.what() << std::endl;
            }
        } else {
            // Just monitor locally without sending to CP
            if (config_.log_interval > 0 && send_state_count_++ % config_.log_interval == 0) {
                std::cout << "Monitor #" << send_state_count_
                          << ": fill=" << (fill_level * 100.0f) << "%" << std::endl;
            }
        }

        // Sleep for configured period
        std::this_thread::sleep_for(std::chrono::milliseconds(config_.period_ms));
    }

    std::cout << "Backpressure monitor thread exiting" << std::endl;
}

} // namespace ejfat_zmq_proxy
