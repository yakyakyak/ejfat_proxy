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

// THREAD SAFETY:
//
// Public interface (start/stop/join/printStats) is designed for single-caller use
// from one external control thread. Calling start() or stop() concurrently is not
// supported; do not call them from multiple threads simultaneously.
//
// printStats() and isRunning() are safe to call from any thread — they only read
// atomics (events_received_, events_dropped_, running_) and delegate to thread-safe
// accessors on the child components.
//
// Internal thread layout (after start()):
//   - Receiver thread (owned here): recvEvent() → EventRingBuffer::push()
//   - ZMQ sender thread (owned by ZmqSender): EventRingBuffer::pop() → zmq send
//   - BP monitor thread (owned by BackpressureMonitor): getFillLevel() → sendState()
//   - E2SAR receive threads (owned by Reassembler): UDP → internal reassembly queue
class EjfatZmqProxy {
public:
    explicit EjfatZmqProxy(const ProxyConfig& config);
    ~EjfatZmqProxy();

    // Call from a single control thread only (not thread-safe with each other).
    void start();
    void stop();
    void join();

    // Safe to call from any thread.
    bool isRunning() const { return running_.load(); }
    void printStats() const;

private:
    void receiverThread();

    ProxyConfig config_;

    // E2SAR components.
    // lb_manager_ is shared with BackpressureMonitor (sendState) and the main thread
    // (registerWorker/deregisterWorker). stop() ensures the monitor has exited before
    // calling deregisterWorker() to prevent concurrent access.
    std::unique_ptr<e2sar::Reassembler> reassembler_;
    std::shared_ptr<e2sar::LBManager> lb_manager_;

    // buffer_ is shared across three threads: push() from receiver, pop() from sender,
    // getFillLevel() from monitor. See EventRingBuffer class for the SPSC contract.
    std::shared_ptr<EventRingBuffer> buffer_;
    std::shared_ptr<ZmqSender> sender_;
    std::unique_ptr<BackpressureMonitor> monitor_;

    // running_ guards the receiver thread loop and provides idempotent start/stop.
    std::atomic<bool> running_{false};
    std::unique_ptr<std::thread> receiver_thread_;

    // Written exclusively by the receiver thread; read by printStats() via atomic load.
    std::atomic<uint64_t> events_received_{0};
    std::atomic<uint64_t> events_dropped_{0};
};

} // namespace ejfat_zmq_proxy
