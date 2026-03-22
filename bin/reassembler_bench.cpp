/*
 * reassembler_bench - Minimal E2SAR Reassembler benchmark
 *
 * Creates a Reassembler with withLBHeader=true, polls getEvent() in a tight
 * loop, and measures how fast events arrive. No ZMQ, no ring buffer, no
 * backpressure — just raw E2SAR recv thread performance.
 */

#include "e2sar.hpp"
#include "e2sarDPReassembler.hpp"
#include <iostream>
#include <chrono>
#include <atomic>
#include <csignal>
#include <thread>

static std::atomic<bool> g_stop{false};

void signalHandler(int) {
    g_stop.store(true);
}

int main(int argc, char* argv[]) {
    std::signal(SIGINT,  signalHandler);
    std::signal(SIGTERM, signalHandler);

    const char* uri_str = "ejfat://b2b-test@127.0.0.1:9876/lb/1?data=127.0.0.1:19522&sync=127.0.0.1:19523";
    std::string data_ip = "127.0.0.1";
    uint16_t data_port = 19522;
    int duration_sec = 30;

    e2sar::EjfatURI uri(uri_str, e2sar::EjfatURI::TokenType::instance);

    e2sar::Reassembler::ReassemblerFlags rflags;
    rflags.useCP = false;
    rflags.withLBHeader = true;
    rflags.validateCert = false;
    rflags.rcvSocketBufSize = 3 * 1024 * 1024;

    auto local_ip = boost::asio::ip::make_address(data_ip);
    e2sar::Reassembler reassembler(uri, local_ip, data_port, 1, rflags);

    auto open_result = reassembler.openAndStart();
    if (open_result.has_error()) {
        std::cerr << "Failed to open reassembler: " << open_result.error().message() << std::endl;
        return 1;
    }

    std::cout << "Reassembler listening on " << data_ip << ":" << data_port << std::endl;
    std::cout << "  withLBHeader=true, useCP=false, 1 recv thread" << std::endl;
    std::cout << "Polling getEvent() in tight loop for " << duration_sec << "s..." << std::endl;

    uint8_t* event_data = nullptr;
    size_t event_bytes = 0;
    e2sar::EventNum_t event_num = 0;
    uint16_t data_id = 0;

    uint64_t events_received = 0;
    uint64_t poll_count = 0;

    using Clock = std::chrono::steady_clock;
    auto start_time = Clock::now();
    Clock::time_point first_event_time;
    Clock::time_point last_event_time;

    while (!g_stop.load()) {
        auto now = Clock::now();
        if (std::chrono::duration_cast<std::chrono::seconds>(now - start_time).count() >= duration_sec)
            break;

        poll_count++;
        auto result = reassembler.getEvent(&event_data, &event_bytes, &event_num, &data_id);

        if (!result || result.value() != 0) {
            // Empty or error — tight spin (no sleep)
            continue;
        }

        events_received++;
        if (events_received == 1) first_event_time = Clock::now();
        last_event_time = Clock::now();

        // Free the event buffer like e2sar_perf does
        delete[] event_data;
        event_data = nullptr;
    }

    auto total_us = std::chrono::duration_cast<std::chrono::microseconds>(
        Clock::now() - start_time).count();

    std::cout << "\n=== Reassembler Bench Results ===" << std::endl;
    std::cout << "Events received : " << events_received << std::endl;
    std::cout << "Poll iterations : " << poll_count << std::endl;

    if (events_received > 0) {
        auto event_duration_us = std::chrono::duration_cast<std::chrono::microseconds>(
            last_event_time - first_event_time).count();
        std::cout << "Event duration  : " << (event_duration_us / 1000) << " ms" << std::endl;
        if (event_duration_us > 0)
            std::cout << "Event rate      : " << (events_received * 1000000 / event_duration_us) << " evt/s" << std::endl;
    }

    auto stats = reassembler.getStats();
    std::cout << "E2SAR stats     : reassembled=" << stats.eventSuccess
              << " enqLoss=" << stats.enqueueLoss
              << " reassemLoss=" << stats.reassemblyLoss
              << " dataErr=" << stats.dataErrCnt
              << " badHdr=" << stats.badHeaderDiscards
              << " totalPkts=" << stats.totalPackets << std::endl;
    std::cout << "=================================" << std::endl;

    return 0;
}
