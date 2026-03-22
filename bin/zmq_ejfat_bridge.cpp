/*
 * zmq_ejfat_bridge - ZMQ PULL -> E2SAR Segmenter bridge
 *
 * Pulls events from a ZMQ PUSH sender and forwards them into the EJFAT
 * load balancer via the E2SAR Segmenter. Used as N2 in the pipeline test:
 *
 *   pipeline_sender (ZMQ PUSH)
 *       --> zmq_ejfat_bridge (ZMQ PULL -> EJFAT send)
 *       --> ejfat_zmq_proxy  (EJFAT recv -> ZMQ PUSH)
 *       --> pipeline_validator (ZMQ PULL)
 */

#include "e2sar.hpp"
#include "e2sarDPSegmenter.hpp"
#include "e2sarCP.hpp"
#include <zmq.hpp>
#include <boost/program_options.hpp>
#include <iostream>
#include <atomic>
#include <csignal>
#include <thread>
#include <chrono>

namespace po = boost::program_options;

static std::atomic<bool> g_stop{false};

void signalHandler(int) {
    g_stop.store(true);
}

int main(int argc, char* argv[]) {
    po::options_description desc("ZMQ to EJFAT Bridge");
    desc.add_options()
        ("help,h",   "Show this help")
        ("uri,u",    po::value<std::string>()->required(),
                     "EJFAT instance URI")
        ("zmq-endpoint,e", po::value<std::string>()->default_value("tcp://localhost:5556"),
                     "ZMQ PULL endpoint to connect to")
        ("data-id,d", po::value<uint16_t>()->default_value(1),
                     "E2SAR data ID carried in RE header")
        ("src-id,s", po::value<uint32_t>()->default_value(1),
                     "E2SAR event source ID carried in Sync header")
        ("mtu,m",    po::value<uint16_t>()->default_value(9000),
                     "MTU in bytes")
        ("sockets",  po::value<int>()->default_value(16),
                     "Number of UDP send sockets")
        ("rcvhwm",   po::value<int>()->default_value(10000),
                     "ZMQ receive HWM")
        ("stats-interval", po::value<int>()->default_value(10),
                     "Stats print interval in seconds (0=disable)")
        ("sender-ip", po::value<std::string>()->default_value(""),
                     "Explicit sender IP to register with LB CP (default: auto-detect via addSenderSelf)")
        ("no-cp",    po::bool_switch()->default_value(false),
                     "Disable control plane (no LB registration, no sync packets; for B2B/local testing)")
        ("multiport", po::bool_switch()->default_value(false),
                     "Use consecutive destination ports (socket 0->basePort, 1->basePort+1, ...) for B2B multi-thread testing");

    po::variables_map vm;
    try {
        po::store(po::parse_command_line(argc, argv, desc), vm);
        if (vm.count("help")) {
            std::cout << desc << std::endl;
            return 0;
        }
        po::notify(vm);
    } catch (const po::error& e) {
        std::cerr << "ERROR: " << e.what() << std::endl;
        std::cerr << desc << std::endl;
        return 1;
    }

    std::signal(SIGINT,  signalHandler);
    std::signal(SIGTERM, signalHandler);

    const bool no_cp = vm["no-cp"].as<bool>();

    // Parse EJFAT URI (instance token — reservation already made)
    e2sar::EjfatURI uri(vm["uri"].as<std::string>(),
                        e2sar::EjfatURI::TokenType::instance);

    // Register this node as a sender with the LB control plane.
    // Skipped in --no-cp (B2B/local) mode.
    if (!no_cp) {
        e2sar::LBManager lb_mgr(uri, false, false);  // validateServer=false, useHostAddress=false
        const std::string sender_ip = vm["sender-ip"].as<std::string>();
        if (sender_ip.empty()) {
            auto reg = lb_mgr.addSenderSelf(false);  // false = IPv4
            if (reg.has_error()) {
                std::cerr << "WARNING: addSenderSelf failed: " << reg.error().message()
                          << " (proceeding anyway)" << std::endl;
            } else {
                std::cout << "Registered as sender with LB CP (auto-detected IP)" << std::endl;
            }
        } else {
            auto reg = lb_mgr.addSenders(std::vector<std::string>{sender_ip});
            if (reg.has_error()) {
                std::cerr << "WARNING: addSenders(" << sender_ip << ") failed: "
                          << reg.error().message() << " (proceeding anyway)" << std::endl;
            } else {
                std::cout << "Registered as sender with LB CP: " << sender_ip << std::endl;
            }
        }
    }

    // Configure Segmenter
    e2sar::Segmenter::SegmenterFlags sflags;
    sflags.useCP          = !no_cp;
    sflags.mtu            = vm["mtu"].as<uint16_t>();
    sflags.numSendSockets = static_cast<size_t>(vm["sockets"].as<int>());
    sflags.warmUpMs       = no_cp ? 0 : 500;
    sflags.multiPort      = vm["multiport"].as<bool>();

    e2sar::Segmenter segmenter(
        uri,
        vm["data-id"].as<uint16_t>(),
        vm["src-id"].as<uint32_t>(),
        sflags
    );

    auto startRes = segmenter.openAndStart();
    if (!startRes) {
        std::cerr << "ERROR: Failed to start segmenter" << std::endl;
        return 1;
    }

    // Setup ZMQ PULL socket
    zmq::context_t ctx(2);
    zmq::socket_t  sock(ctx, zmq::socket_type::pull);
    sock.set(zmq::sockopt::rcvhwm, vm["rcvhwm"].as<int>());
    sock.connect(vm["zmq-endpoint"].as<std::string>());

    const int stats_interval = vm["stats-interval"].as<int>();

    std::cout << "ZMQ EJFAT Bridge started" << std::endl;
    std::cout << "  ZMQ endpoint : " << vm["zmq-endpoint"].as<std::string>() << std::endl;
    std::cout << "  Data ID      : " << vm["data-id"].as<uint16_t>() << std::endl;
    std::cout << "  Src ID       : " << vm["src-id"].as<uint32_t>()  << std::endl;
    std::cout << "  MTU          : " << vm["mtu"].as<uint16_t>()     << std::endl;
    std::cout << "  Sockets      : " << vm["sockets"].as<int>()      << std::endl;
    std::cout << "  Outgoing intf: " << segmenter.getIntf()          << std::endl;
    std::cout << std::endl;

    uint64_t events_received = 0;
    uint64_t events_sent     = 0;
    uint64_t events_dropped  = 0;

    // Timing diagnostics
    using Clock = std::chrono::steady_clock;
    int64_t zmq_recv_us_total = 0;
    int64_t send_event_us_total = 0;
    int64_t send_event_us_max = 0;
    Clock::time_point first_recv_time;
    Clock::time_point last_send_time;

    auto last_stats = std::chrono::steady_clock::now();

    while (!g_stop.load()) {
        zmq::message_t msg;
        auto t_zmq = Clock::now();
        auto rr = sock.recv(msg, zmq::recv_flags::dontwait);

        if (!rr) {
            // No message available — check stats then yield
            if (stats_interval > 0) {
                auto now = std::chrono::steady_clock::now();
                auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                    now - last_stats).count();
                if (elapsed >= stats_interval) {
                    auto ss = segmenter.getSendStats();
                    auto sy = segmenter.getSyncStats();
                    std::cout << "Events: recv=" << events_received
                              << " sent=" << events_sent
                              << " dropped=" << events_dropped
                              << " | seg_frags=" << ss.msgCnt
                              << " seg_errs=" << ss.errCnt
                              << " | sync_pkts=" << sy.msgCnt
                              << " sync_errs=" << sy.errCnt << std::endl;
                    last_stats = now;
                }
            }
            std::this_thread::sleep_for(std::chrono::microseconds(50));
            continue;
        }

        auto t_after_zmq = Clock::now();
        zmq_recv_us_total += std::chrono::duration_cast<std::chrono::microseconds>(
            t_after_zmq - t_zmq).count();

        events_received++;
        if (events_received == 1)
            first_recv_time = t_after_zmq;

        // Use sendEvent (synchronous) rather than addToSendQueue (async/zero-copy).
        // addToSendQueue holds a raw pointer to msg.data() without copying; msg is
        // destroyed at the end of this loop iteration, leaving E2SAR with a dangling
        // pointer when the send queue backs up at high throughput.
        // sendEvent copies/sends the data before returning, so msg lifetime is safe.
        auto t_send = Clock::now();
        auto res = segmenter.sendEvent(
            static_cast<uint8_t*>(msg.data()),
            msg.size()
        );
        auto t_after_send = Clock::now();
        auto send_us = std::chrono::duration_cast<std::chrono::microseconds>(
            t_after_send - t_send).count();
        send_event_us_total += send_us;
        if (send_us > send_event_us_max) send_event_us_max = send_us;

        if (!res) {
            events_dropped++;
            if (events_dropped % 1000 == 0) {
                std::cerr << "WARNING: " << events_dropped
                          << " events dropped (send failed)" << std::endl;
            }
        } else {
            events_sent++;
            last_send_time = t_after_send;
        }

        if (stats_interval > 0 && events_received % 10000 == 0) {
            std::cout << "Progress: recv=" << events_received
                      << " sent=" << events_sent
                      << " dropped=" << events_dropped << std::endl;
        }
    }

    segmenter.stopThreads();

    auto sendStats = segmenter.getSendStats();
    auto total_send_duration_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        last_send_time - first_recv_time).count();
    std::cout << "\n=== Bridge Statistics ===" << std::endl;
    std::cout << "Events received from ZMQ  : " << events_received << std::endl;
    std::cout << "Events sent via EJFAT     : " << events_sent     << std::endl;
    std::cout << "Events dropped            : " << events_dropped  << std::endl;
    std::cout << "Segmenter fragments sent  : " << sendStats.msgCnt << std::endl;
    std::cout << "Segmenter send errors     : " << sendStats.errCnt << std::endl;
    std::cout << "=== Bridge Timing ===" << std::endl;
    std::cout << "Total send duration (ms)  : " << total_send_duration_ms << std::endl;
    if (events_sent > 0) {
        std::cout << "Avg zmq_recv (us)         : " << (zmq_recv_us_total / (int64_t)events_received) << std::endl;
        std::cout << "Avg sendEvent (us)        : " << (send_event_us_total / (int64_t)events_sent) << std::endl;
        std::cout << "Max sendEvent (us)        : " << send_event_us_max << std::endl;
        std::cout << "Effective send rate       : " << (events_sent * 1000 / std::max(total_send_duration_ms, (int64_t)1)) << " evt/s" << std::endl;
    }
    std::cout << "=========================" << std::endl;

    return (events_dropped > 0) ? 2 : 0;
}
