#pragma once

#include "ejfat_zmq_proxy/event_ring_buffer.hpp"
#include "ejfat_zmq_proxy/config.hpp"
#include <zmq.hpp>
#include <atomic>
#include <memory>
#include <thread>

namespace ejfat_zmq_proxy {

class ZmqSender {
public:
    explicit ZmqSender(const ZmqConfig& config);
    ~ZmqSender();

    void start(std::shared_ptr<EventRingBuffer> buffer);
    void stop();
    void join();

    // Backpressure metrics
    uint64_t getBlockedSendCount() const { return blocked_sends_.load(); }
    uint64_t getTotalSendCount() const { return total_sends_.load(); }
    float getBlockedSendRatio() const;

private:
    void run();

    ZmqConfig config_;
    std::shared_ptr<EventRingBuffer> buffer_;
    std::unique_ptr<zmq::context_t> context_;
    std::unique_ptr<zmq::socket_t> socket_;

    std::atomic<bool> running_{false};
    std::unique_ptr<std::thread> thread_;

    std::atomic<uint64_t> blocked_sends_{0};
    std::atomic<uint64_t> total_sends_{0};
};

} // namespace ejfat_zmq_proxy
