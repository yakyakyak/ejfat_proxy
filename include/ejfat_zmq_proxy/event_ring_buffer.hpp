#pragma once

#include <boost/lockfree/spsc_queue.hpp>
#include <cstdint>
#include <atomic>

namespace ejfat_zmq_proxy {

// Event holds the E2SAR-allocated buffer directly (no copy).
// Ownership is exclusive: exactly one Event owns the buffer at any time.
// The buffer is freed via delete[] by the ZMQ sender after transmission.
struct Event {
    uint8_t*  data{nullptr};
    size_t    bytes{0};
    uint64_t  event_num{0};
    uint16_t  data_id{0};

    Event() = default;

    // Transfer ownership of an E2SAR-allocated buffer.
    Event(uint8_t* buf, size_t size, uint64_t num, uint16_t id)
        : data(buf), bytes(size), event_num(num), data_id(id) {}

    // Non-copyable: ownership is unique.
    Event(const Event&)            = delete;
    Event& operator=(const Event&) = delete;

    // Movable: transfers ownership and nulls the source.
    Event(Event&& o) noexcept
        : data(o.data), bytes(o.bytes), event_num(o.event_num), data_id(o.data_id)
    { o.data = nullptr; o.bytes = 0; }

    Event& operator=(Event&& o) noexcept {
        if (this != &o) {
            delete[] data;
            data = o.data; bytes = o.bytes;
            event_num = o.event_num; data_id = o.data_id;
            o.data = nullptr; o.bytes = 0;
        }
        return *this;
    }

    ~Event() { delete[] data; }
};

class EventRingBuffer {
public:
    explicit EventRingBuffer(size_t capacity);
    ~EventRingBuffer() = default;

    // Producer (receiver thread) — move only, Event is non-copyable
    bool push(Event&& event);

    // Consumer (sender thread)
    bool pop(Event& event);

    // Metrics
    float getFillLevel() const;
    size_t getCapacity() const { return capacity_; }
    size_t size() const;

private:
    boost::lockfree::spsc_queue<Event> queue_;
    size_t capacity_;
    std::atomic<size_t> approx_size_{0};
};

} // namespace ejfat_zmq_proxy
