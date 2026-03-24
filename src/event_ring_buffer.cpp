// EventRingBuffer — bounded SPSC queue bridging the E2SAR receiver and ZMQ sender threads.
//
// push() is called by the receiver thread after each recvEvent(); pop() is called by the
// ZMQ sender thread before each socket send. getFillLevel() is polled by BackpressureMonitor
// to compute the PID control signal sent to the load balancer.
//
// approx_size_ shadows the queue depth as a relaxed atomic so getFillLevel() can be read
// from the monitor thread without touching the lock-free queue internals.
//------------------------------------------------------------------------------------------

#include "ejfat_zmq_proxy/event_ring_buffer.hpp"

namespace ejfat_zmq_proxy {

EventRingBuffer::EventRingBuffer(size_t capacity)
    : queue_(capacity), capacity_(capacity) {
}

bool EventRingBuffer::push(Event&& event) {
    if (queue_.push(std::move(event))) {
        approx_size_.fetch_add(1, std::memory_order_relaxed);
        return true;
    }
    return false;
}

bool EventRingBuffer::pop(Event& event) {
    if (queue_.pop(event)) {
        approx_size_.fetch_sub(1, std::memory_order_relaxed);
        return true;
    }
    return false;
}

float EventRingBuffer::getFillLevel() const {
    size_t current_size = approx_size_.load(std::memory_order_relaxed);
    return static_cast<float>(current_size) / static_cast<float>(capacity_);
}

size_t EventRingBuffer::size() const {
    return approx_size_.load(std::memory_order_relaxed);
}

} // namespace ejfat_zmq_proxy
