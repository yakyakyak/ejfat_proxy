#pragma once

#include "ejfat_zmq_proxy/config.hpp"
#include "ejfat_zmq_proxy/event_ring_buffer.hpp"
#include "ejfat_zmq_proxy/zmq_sender.hpp"
#include "ejfat_zmq_proxy/backpressure_monitor.hpp"
#include <e2sarDPReassembler.hpp>
#include <e2sarCP.hpp>
#include <memory>
#include <atomic>
#include <thread>

namespace ejfat_zmq_proxy {

class EjfatZmqProxy {
public:
    explicit EjfatZmqProxy(const ProxyConfig& config);
    ~EjfatZmqProxy();

    void start();
    void stop();
    void join();

    // Status
    bool isRunning() const { return running_.load(); }
    void printStats() const;

private:
    void receiverThread();

    ProxyConfig config_;

    // E2SAR components
    std::unique_ptr<e2sar::Reassembler> reassembler_;
    std::shared_ptr<e2sar::LBManager> lb_manager_;

    // Internal components
    std::shared_ptr<EventRingBuffer> buffer_;
    std::shared_ptr<ZmqSender> sender_;
    std::unique_ptr<BackpressureMonitor> monitor_;

    // Receiver thread
    std::atomic<bool> running_{false};
    std::unique_ptr<std::thread> receiver_thread_;

    // Stats
    std::atomic<uint64_t> events_received_{0};
    std::atomic<uint64_t> events_dropped_{0};
};

} // namespace ejfat_zmq_proxy
