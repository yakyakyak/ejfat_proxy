#include "ejfat_zmq_proxy/zmq_sender.hpp"
#include <iostream>
#include <thread>

namespace ejfat_zmq_proxy {

ZmqSender::ZmqSender(const ZmqConfig& config)
    : config_(config) {
}

ZmqSender::~ZmqSender() {
    stop();
    join();
}

void ZmqSender::start(std::shared_ptr<EventRingBuffer> buffer) {
    if (running_.exchange(true)) {
        return; // Already running
    }

    buffer_ = buffer;

    // Initialize ZMQ context and socket
    context_ = std::make_unique<zmq::context_t>(config_.io_threads);
    socket_ = std::make_unique<zmq::socket_t>(*context_, zmq::socket_type::push);

    // Set socket options
    socket_->set(zmq::sockopt::sndhwm, config_.send_hwm);
    socket_->set(zmq::sockopt::linger, config_.linger_ms);
    if (config_.sndbuf > 0) {
        socket_->set(zmq::sockopt::sndbuf, config_.sndbuf);
    }

    // Bind to endpoint
    socket_->bind(config_.push_endpoint);

    std::cout << "ZMQ sender bound to " << config_.push_endpoint
              << " (HWM=" << config_.send_hwm
              << ", IO threads=" << config_.io_threads << ")" << std::endl;

    // Start sender thread
    thread_ = std::make_unique<std::thread>(&ZmqSender::run, this);
}

void ZmqSender::stop() {
    running_.store(false);
}

void ZmqSender::join() {
    if (thread_ && thread_->joinable()) {
        thread_->join();
    }
}

float ZmqSender::getBlockedSendRatio() const {
    uint64_t total = total_sends_.load();
    if (total == 0) return 0.0f;
    return static_cast<float>(blocked_sends_.load()) / static_cast<float>(total);
}

void ZmqSender::run() {
    Event event;

    while (running_.load()) {
        if (!buffer_->pop(event)) {
            // Buffer empty, brief sleep
            std::this_thread::sleep_for(std::chrono::microseconds(config_.poll_sleep_us));
            continue;
        }

        // Zero-copy ZMQ message: transfer the E2SAR buffer directly into ZMQ.
        // event.release() hands off ownership and nulls the internal pointer
        // so the Event destructor will not double-free.
        auto [buf, bytes] = event.release();

        zmq::message_t msg(buf, bytes,
            [](void* ptr, void*) { delete[] static_cast<uint8_t*>(ptr); },
            nullptr);

        // Try non-blocking send to detect backpressure.
        // On EAGAIN (!result.has_value()), msg is intact and we retry blocking.
        // On success (result.has_value()), msg is consumed by ZMQ — do NOT send again.
        try {
            auto result = socket_->send(msg, zmq::send_flags::dontwait);
            total_sends_.fetch_add(1);

            if (!result.has_value()) {
                // Send would block (HWM reached) — msg is intact, retry blocking
                blocked_sends_.fetch_add(1);
                socket_->send(msg, zmq::send_flags::none);
            }
        } catch (const zmq::error_t& e) {
            std::cerr << "ZMQ send error: " << e.what() << std::endl;
        }
    }

    std::cout << "ZMQ sender thread exiting" << std::endl;
}

} // namespace ejfat_zmq_proxy
