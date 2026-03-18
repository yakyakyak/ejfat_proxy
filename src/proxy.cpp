#include "ejfat_zmq_proxy/proxy.hpp"
#include <iostream>
#include <iomanip>
#include <stdexcept>

namespace ejfat_zmq_proxy {

EjfatZmqProxy::EjfatZmqProxy(const ProxyConfig& config)
    : config_(config) {

    std::cout << "Initializing EJFAT ZMQ Proxy..." << std::endl;

    // Create ring buffer
    buffer_ = std::make_shared<EventRingBuffer>(config_.buffer.size);
    std::cout << "  Ring buffer: " << config_.buffer.size << " events" << std::endl;

    // Parse EJFAT URI (use instance token type for local testing)
    e2sar::EjfatURI uri(config_.ejfat.uri, e2sar::EjfatURI::TokenType::instance);

    // Create LB manager for sendState (only if using control plane)
    if (config_.ejfat.use_cp) {
        lb_manager_ = std::make_shared<e2sar::LBManager>(uri, true, false);
        std::cout << "  LB manager created (CP enabled)" << std::endl;
    } else {
        std::cout << "  LB manager skipped (CP disabled)" << std::endl;
    }

    // Configure E2SAR reassembler flags
    e2sar::Reassembler::ReassemblerFlags rflags;
    rflags.useCP = config_.ejfat.use_cp;
    rflags.withLBHeader = config_.ejfat.with_lb_header;
    rflags.validateCert = config_.ejfat.validate_cert;
    // Note: useIPv6 not available in E2SAR API (determined by data_ip type)
    rflags.eventTimeout_ms = config_.ejfat.event_timeout_ms;
    rflags.rcvSocketBufSize = config_.ejfat.rcv_socket_buf_size;
    rflags.weight = config_.ejfat.scheduling.weight;
    rflags.min_factor = config_.ejfat.scheduling.min_factor;
    rflags.max_factor = config_.ejfat.scheduling.max_factor;

    // Initialize E2SAR reassembler with flags
    // Use configured IP address (empty = auto-detect, or explicit IP for macOS)
    try {
        std::string ip_to_use = config_.ejfat.data_ip.empty() ? "127.0.0.1" : config_.ejfat.data_ip;
        auto local_ip = boost::asio::ip::make_address(ip_to_use);
        reassembler_ = std::make_unique<e2sar::Reassembler>(
            uri,
            local_ip,
            config_.ejfat.data_port,
            config_.ejfat.num_recv_threads,
            rflags
        );
        std::cout << "  E2SAR reassembler initialized" << std::endl;
        std::cout << "    URI: " << config_.ejfat.uri << std::endl;
        std::cout << "    Port: " << config_.ejfat.data_port << std::endl;
        std::cout << "    Data IP: " << (config_.ejfat.data_ip.empty() ? "auto-detect" : config_.ejfat.data_ip) << std::endl;
        std::cout << "    Recv threads: " << config_.ejfat.num_recv_threads << std::endl;
        std::cout << "    Use CP: " << (config_.ejfat.use_cp ? "true" : "false") << std::endl;
        std::cout << "    With LB header: " << (config_.ejfat.with_lb_header ? "true" : "false") << std::endl;
    } catch (const e2sar::E2SARException& e) {
        std::cerr << "ERROR: Failed to initialize E2SAR Reassembler" << std::endl;
        std::cerr << "  Exception: " << e.what() << std::endl;
        throw;
    } catch (const std::exception& e) {
        std::cerr << "ERROR: Failed to initialize E2SAR Reassembler" << std::endl;
        std::cerr << "  Exception: " << e.what() << std::endl;
        throw;
    }

    // Create ZMQ sender
    sender_ = std::make_shared<ZmqSender>(config_.zmq);
    std::cout << "  ZMQ sender created" << std::endl;

    // Create backpressure monitor
    monitor_ = std::make_unique<BackpressureMonitor>(
        config_.backpressure,
        buffer_,
        sender_,
        lb_manager_
    );
    std::cout << "  Backpressure monitor created" << std::endl;

    std::cout << "Initialization complete" << std::endl;
}

EjfatZmqProxy::~EjfatZmqProxy() {
    stop();
    join();
}

void EjfatZmqProxy::start() {
    if (running_.exchange(true)) {
        return; // Already running
    }

    std::cout << "\nStarting proxy components..." << std::endl;

    // Open E2SAR reassembler sockets and start its receive threads
    auto open_result = reassembler_->openAndStart();
    if (open_result.has_error()) {
        throw std::runtime_error("Failed to open E2SAR reassembler: " +
                                 open_result.error().message());
    }
    std::cout << "  E2SAR reassembler started (UDP sockets open)" << std::endl;

    // Start ZMQ sender
    sender_->start(buffer_);

    // Start backpressure monitor
    monitor_->start();

    // Start receiver thread
    receiver_thread_ = std::make_unique<std::thread>(
        &EjfatZmqProxy::receiverThread, this
    );

    std::cout << "All components started" << std::endl;
}

void EjfatZmqProxy::stop() {
    if (!running_.exchange(false)) {
        return; // Already stopped
    }

    std::cout << "\nStopping proxy components..." << std::endl;

    // Stop all components
    monitor_->stop();
    sender_->stop();
}

void EjfatZmqProxy::join() {
    if (receiver_thread_ && receiver_thread_->joinable()) {
        receiver_thread_->join();
    }
    monitor_->join();
    sender_->join();
}

void EjfatZmqProxy::receiverThread() {
    std::cout << "Receiver thread started" << std::endl;

    uint8_t* event_data = nullptr;
    size_t event_bytes = 0;
    e2sar::EventNum_t event_num = 0;
    uint16_t data_id = 0;

    while (running_.load()) {
        // Receive event from E2SAR reassembler
        auto result = reassembler_->recvEvent(
            &event_data,
            &event_bytes,
            &event_num,
            &data_id,
            config_.buffer.recv_timeout_ms
        );

        if (!result) {
            // Error or timeout occurred
            continue;
        }

        if (result.value() != 0) {
            // Timeout or queue empty (-1), no event available
            continue;
        }

        // Successfully received event (value == 0 means success in E2SAR API)
        events_received_.fetch_add(1);

        // Create event and push to ring buffer
        Event event(event_data, event_bytes, event_num, data_id);

        if (!buffer_->push(std::move(event))) {
            // Buffer full, drop event
            events_dropped_.fetch_add(1);

            if (config_.logging.drop_warn_interval > 0 &&
                events_dropped_.load() % config_.logging.drop_warn_interval == 0) {
                std::cerr << "WARNING: Dropped " << events_dropped_.load()
                          << " events (buffer full)" << std::endl;
            }
        }

        // Log progress periodically
        if (config_.logging.progress_interval > 0 &&
            events_received_.load() % config_.logging.progress_interval == 0) {
            std::cout << "Received " << events_received_.load() << " events" << std::endl;
        }
    }

    std::cout << "Receiver thread exiting" << std::endl;
}

void EjfatZmqProxy::printStats() const {
    std::cout << "\n=== Proxy Statistics ===" << std::endl;
    std::cout << "Events received:  " << events_received_.load() << std::endl;
    std::cout << "Events dropped:   " << events_dropped_.load() << std::endl;
    std::cout << "Buffer fill:      " << std::fixed << std::setprecision(1)
              << (buffer_->getFillLevel() * 100.0f) << "%" << std::endl;
    std::cout << "Buffer size:      " << buffer_->size() << " / "
              << buffer_->getCapacity() << std::endl;
    std::cout << "ZMQ sends:        " << sender_->getTotalSendCount() << std::endl;
    std::cout << "ZMQ blocked:      " << sender_->getBlockedSendCount()
              << " (" << std::fixed << std::setprecision(1)
              << (sender_->getBlockedSendRatio() * 100.0f) << "%)" << std::endl;
    std::cout << "Last fill%%:       " << std::fixed << std::setprecision(1)
              << monitor_->getLastFillPercent() << "%" << std::endl;
    std::cout << "Last control:     " << std::fixed << std::setprecision(3)
              << monitor_->getLastControlSignal() << std::endl;
    std::cout << "========================" << std::endl;
}

} // namespace ejfat_zmq_proxy
