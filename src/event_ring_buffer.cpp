#include "ejfat_zmq_proxy/event_ring_buffer.hpp"

namespace ejfat_zmq_proxy {

EventRingBuffer::EventRingBuffer(size_t capacity)
    : queue_(capacity), capacity_(capacity) {
}

bool EventRingBuffer::push(const Event& event) {
    if (queue_.push(event)) {
        approx_size_.fetch_add(1, std::memory_order_relaxed);
        return true;
    }
    return false;
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
