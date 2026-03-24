#pragma once

#include "ejfat_zmq_proxy/event_ring_buffer.hpp"
#include "ejfat_zmq_proxy/config.hpp"
#include <e2sarCP.hpp>
#include <memory>
#include <atomic>
#include <thread>

namespace ejfat_zmq_proxy {

class BackpressureMonitor {
public:
    BackpressureMonitor(const BackpressureConfig& config,
                        std::shared_ptr<EventRingBuffer> buffer,
                        std::shared_ptr<e2sar::LBManager> lb_manager);
    ~BackpressureMonitor();

    void start();
    void stop();
    void join();

    // Get current state
    float getLastFillPercent() const { return last_fill_percent_.load(); }
    float getLastControlSignal() const { return last_control_signal_.load(); }

private:
    void run();
    float computePID(float error);

    BackpressureConfig config_;
    std::shared_ptr<EventRingBuffer> buffer_;
    std::shared_ptr<e2sar::LBManager> lb_manager_;

    std::atomic<bool> running_{false};
    std::unique_ptr<std::thread> thread_;

    // PID state
    float integral_{0.0f};
    float prev_error_{0.0f};

    // Metrics
    std::atomic<float> last_fill_percent_{0.0f};
    std::atomic<float> last_control_signal_{0.0f};
    uint64_t send_state_count_{0};
};

} // namespace ejfat_zmq_proxy
