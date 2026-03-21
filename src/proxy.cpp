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

    // Register this worker with the LB so it receives data.
    // Must happen before sendState (which requires the session token set by registration).
    // Use the explicit data_ip from config (same IP the reassembler is bound to).
    if (lb_manager_) {
        auto data_ip = boost::asio::ip::make_address(config_.ejfat.data_ip);
        auto node_ip_port = std::make_pair(data_ip,
                                           static_cast<uint16_t>(config_.ejfat.data_port));
        auto reg_result = lb_manager_->registerWorker(
            config_.ejfat.worker_name,
            node_ip_port,
            config_.ejfat.scheduling.weight,
            1,  // source_count: one logical sender
            config_.ejfat.scheduling.min_factor,
            config_.ejfat.scheduling.max_factor,
            false  // keep_lb_header: LB strips its header before forwarding to us
        );
        if (reg_result.has_error()) {
            throw std::runtime_error("Failed to register worker with LB: " +
                                     reg_result.error().message());
        }
        if (reg_result.value() != 0) {
            throw std::runtime_error("registerWorker returned non-zero: " +
                                     std::to_string(reg_result.value()));
        }
        std::cout << "  Worker registered with LB: " << config_.ejfat.worker_name
                  << " at " << config_.ejfat.data_ip << ":" << config_.ejfat.data_port
                  << std::endl;
    }

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

    // Deregister from LB before stopping
    if (lb_manager_) {
        auto dereg = lb_manager_->deregisterWorker();
        if (dereg.has_error()) {
            std::cerr << "WARNING: Failed to deregister worker: "
                      << dereg.error().message() << std::endl;
        } else {
            std::cout << "  Worker deregistered from LB" << std::endl;
        }
    }

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

    // Print E2SAR reassembler stats to diagnose data flow
    auto stats = reassembler_->getStats();
    std::cout << "\n=== E2SAR Reassembler Stats ===" << std::endl;
    std::cout << "Events successfully reassembled: " << stats.eventSuccess << std::endl;
    std::cout << "Events lost (enqueue full):      " << stats.enqueueLoss << std::endl;
    std::cout << "Events lost (reassembly loss):   " << stats.reassemblyLoss << std::endl;
    std::cout << "Data errors:                     " << stats.dataErrCnt << std::endl;
    std::cout << "================================" << std::endl;
}

void EjfatZmqProxy::receiverThread() {
    std::cout << "Receiver thread started" << std::endl;

    uint8_t* event_data = nullptr;
    size_t event_bytes = 0;
    e2sar::EventNum_t event_num = 0;
    uint16_t data_id = 0;

    while (running_.load()) {
        // Use getEvent (non-blocking) rather than recvEvent to avoid ambiguous
        // return semantics on timeout. getEvent returns value()=0 on success
        // and value()=-1 when the queue is empty.
        auto result = reassembler_->getEvent(
            &event_data,
            &event_bytes,
            &event_num,
            &data_id
        );

        if (!result) {
            // Reassembler error
            std::this_thread::sleep_for(
                std::chrono::milliseconds(config_.buffer.recv_timeout_ms));
            continue;
        }

        if (result.value() != 0) {
            // Queue empty (-1): brief sleep then retry
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            continue;
        }

        // Successfully received event.
        // E2SAR allocates event_data; free it after copying.
        if (event_bytes == 0 || event_data == nullptr) {
            delete[] event_data;
            event_data = nullptr;
            event_bytes = 0;
            std::cerr << "WARNING: recvEvent returned 0-byte event, skipping" << std::endl;
            continue;
        }

        events_received_.fetch_add(1);

        // Create event (copies payload) and push to ring buffer.
        // E2SAR allocates event_data; free it after copying.
        Event event(event_data, event_bytes, event_num, data_id);
        delete[] event_data;
        event_data = nullptr;
        event_bytes = 0;

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
    // E2SAR reassembler stats — key for diagnosing data receipt
    auto rs = reassembler_->getStats();
    std::cout << "E2SAR reassembled:" << rs.eventSuccess
              << " enqLoss:" << rs.enqueueLoss
              << " reassemLoss:" << rs.reassemblyLoss
              << " dataErr:" << rs.dataErrCnt << std::endl;
    std::cout << "========================" << std::endl;
}

} // namespace ejfat_zmq_proxy
