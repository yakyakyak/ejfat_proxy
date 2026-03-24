#pragma once

#include "ejfat_zmq_proxy/event_ring_buffer.hpp"
#include "ejfat_zmq_proxy/config.hpp"
#include <zmq.hpp>
#include <atomic>
#include <memory>
#include <thread>

namespace ejfat_zmq_proxy {

// THREAD SAFETY:
//
// start(), stop(), and join() are designed for single-caller use from one
// control thread (the proxy's start/stop path). Do not call them concurrently.
//
// After start(), an internal sender thread runs the run() loop:
//   EventRingBuffer::pop() → zero-copy ZMQ PUSH send
//
// context_ and socket_ are created in start() and accessed exclusively by the
// sender thread thereafter — they must not be touched by any other thread.
//
// getBlockedSendCount(), getTotalSendCount(), getBlockedSendRatio() are safe
// to call from any thread (they only read atomics).
class ZmqSender {
public:
    explicit ZmqSender(const ZmqConfig& config);
    ~ZmqSender();

    // Lifecycle — call from single control thread only.
    void start(std::shared_ptr<EventRingBuffer> buffer);
    void stop();
    void join();

    // Metrics — safe to call from any thread.
    uint64_t getBlockedSendCount() const { return blocked_sends_.load(); }
    uint64_t getTotalSendCount() const { return total_sends_.load(); }
    float getBlockedSendRatio() const;

private:
    void run();

    ZmqConfig config_;

    // Shared with the receiver thread: pop() is called here, push() from the receiver.
    // See EventRingBuffer for the SPSC contract.
    std::shared_ptr<EventRingBuffer> buffer_;

    // ZMQ resources — owned exclusively by the sender thread after start().
    std::unique_ptr<zmq::context_t> context_;
    std::unique_ptr<zmq::socket_t> socket_;

    // running_ is written by the control thread (stop()) and read by the sender thread.
    // thread_ is created in start() and joined in join().
    std::atomic<bool> running_{false};
    std::unique_ptr<std::thread> thread_;

    // Written exclusively by the sender thread; read by any thread via getters above.
    std::atomic<uint64_t> blocked_sends_{0};
    std::atomic<uint64_t> total_sends_{0};
};

} // namespace ejfat_zmq_proxy
