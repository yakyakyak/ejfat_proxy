#pragma once

#include <boost/lockfree/spsc_queue.hpp>
#include <memory>
#include <vector>
#include <cstdint>
#include <atomic>

namespace ejfat_zmq_proxy {

struct Event {
    std::vector<uint8_t> data;
    uint64_t event_num{0};
    uint16_t data_id{0};

    Event() = default;
    Event(const uint8_t* buf, size_t size, uint64_t num, uint16_t id)
        : data(buf, buf + size), event_num(num), data_id(id) {}
};

class EventRingBuffer {
public:
    explicit EventRingBuffer(size_t capacity);
    ~EventRingBuffer() = default;

    // Producer (receiver thread)
    bool push(const Event& event);
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
