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
 *
 * Multi-endpoint mode (--zmq-endpoint repeated):
 *   Each --zmq-endpoint spawns --workers ZMQ PULL threads, all sharing a
 *   single E2SAR Segmenter via addToSendQueue() (thread-safe, non-blocking).
 *   The Segmenter's internal thread pool (numSendSockets) handles parallel
 *   UDP fragmentation and sending.
 *
 *   The proxy sees exactly ONE sender (single data_id/src_id) — no
 *   reassembly confusion from multiple concurrent Segmenters.
 *
 * Buffer ownership:
 *   addToSendQueue() stores a raw pointer without copying; the buffer
 *   must remain valid until E2SAR's send thread actually transmits it.
 *   Each worker heap-copies the ZMQ message data before enqueuing and
 *   registers freeEventBuffer() as the completion callback so E2SAR's
 *   thread pool worker frees it after _send() completes.
 *
 * Topology (2 endpoints, 1 worker each):
 *   sender-A (ZMQ PUSH :5556) ── worker-0 (ZMQ PULL) ──┐
 *                                                         ├── addToSendQueue
 *   sender-B (ZMQ PUSH :5557) ── worker-1 (ZMQ PULL) ──┘   → Segmenter queue
 *                                                               → thread_pool
 *                                                                  → UDP → proxy
 */

#include "e2sar.hpp"
#include "e2sarDPSegmenter.hpp"
#include "e2sarCP.hpp"
#include <zmq.hpp>
#include <boost/program_options.hpp>
#include <boost/any.hpp>
#include <iostream>
#include <atomic>
#include <csignal>
#include <thread>
#include <vector>
#include <chrono>
#include <cstring>

namespace po = boost::program_options;

static std::atomic<bool> g_stop{false};

void signalHandler(int) {
    g_stop.store(true);
}

// Called by E2SAR's thread pool worker after _send() completes.
// Frees the heap-copied event buffer.
static void freeEventBuffer(boost::any arg) {
    delete[] boost::any_cast<uint8_t*>(arg);
}

struct WorkerStats {
    std::atomic<uint64_t> received{0};   // pulled from ZMQ
    std::atomic<uint64_t> sent{0};       // successfully enqueued to Segmenter
    std::atomic<uint64_t> dropped{0};    // Segmenter queue full
};

void workerLoop(
    int id,
    const std::string& zmq_endpoint,
    int rcvhwm,
    e2sar::Segmenter& segmenter,    // shared, single sender
    int stats_interval,
    WorkerStats& stats)
{
    // Each worker owns its own ZMQ context + socket.
    // ZMQ PUSH distributes events round-robin to all connected PULL sockets.
    zmq::context_t ctx(1);
    zmq::socket_t  sock(ctx, zmq::socket_type::pull);
    sock.set(zmq::sockopt::rcvhwm, rcvhwm);
    sock.connect(zmq_endpoint);

    auto last_stats = std::chrono::steady_clock::now();
    uint64_t local_recv = 0;

    while (!g_stop.load()) {
        zmq::message_t msg;
        auto rr = sock.recv(msg, zmq::recv_flags::dontwait);

        if (!rr) {
            if (stats_interval > 0) {
                auto now = std::chrono::steady_clock::now();
                auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                    now - last_stats).count();
                if (elapsed >= stats_interval) {
                    std::cout << "Worker " << id
                              << ": recv=" << local_recv << std::endl;
                    last_stats = now;
                }
            }
            std::this_thread::sleep_for(std::chrono::microseconds(50));
            continue;
        }

        local_recv++;
        stats.received.fetch_add(1);

        // Heap-copy: ZMQ message lifetime ends at end of this scope, but
        // addToSendQueue only stores a raw pointer. freeEventBuffer() frees
        // it after E2SAR's thread pool worker completes transmission.
        uint8_t* buf = new uint8_t[msg.size()];
        std::memcpy(buf, msg.data(), msg.size());

        auto res = segmenter.addToSendQueue(
            buf, msg.size(),
            0,              // eventNum: 0 = use internal counter
            0,              // dataId:   0 = use Segmenter's configured dataId
            0,              // entropy:  0 = default
            freeEventBuffer,
            boost::any(buf)
        );

        if (res) {
            stats.sent.fetch_add(1);
        } else {
            // Send queue full — free buffer and count as dropped
            delete[] buf;
            stats.dropped.fetch_add(1);
            if (stats.dropped.load() % 100 == 1) {
                std::cerr << "Worker " << id << ": WARNING: "
                          << stats.dropped.load()
                          << " events dropped (send queue full)" << std::endl;
            }
        }
    }

    std::cout << "Worker " << id << " exiting (received=" << local_recv << ")" << std::endl;
}

int main(int argc, char* argv[]) {
    po::options_description desc("ZMQ to EJFAT Bridge");
    desc.add_options()
        ("help,h",   "Show this help")
        ("uri,u",    po::value<std::string>()->required(),
                     "EJFAT instance URI")
        ("zmq-endpoint,e",
                     po::value<std::vector<std::string>>()->composing()
                         ->default_value(std::vector<std::string>{"tcp://localhost:5556"},
                                         "tcp://localhost:5556"),
                     "ZMQ PULL endpoint to connect to (repeat for multiple queues)")
        ("data-id,d", po::value<uint16_t>()->default_value(1),
                     "E2SAR data ID carried in RE header")
        ("src-id,s", po::value<uint32_t>()->default_value(1),
                     "E2SAR event source ID carried in Sync header")
        ("mtu,m",    po::value<uint16_t>()->default_value(9000),
                     "MTU in bytes")
        ("sockets",  po::value<int>()->default_value(16),
                     "Number of UDP send sockets (E2SAR internal thread pool size)")
        ("workers",  po::value<int>()->default_value(1),
                     "Number of parallel ZMQ PULL receiver threads")
        ("rcvhwm",   po::value<int>()->default_value(10000),
                     "ZMQ receive HWM (per worker socket)")
        ("stats-interval", po::value<int>()->default_value(10),
                     "Stats print interval in seconds (0=disable)")
        ("sender-ip", po::value<std::string>()->default_value(""),
                     "Explicit sender IP to register with LB CP (default: auto-detect)")
        ("no-cp",    po::bool_switch()->default_value(false),
                     "Disable control plane (for B2B/local testing)")
        ("multiport", po::bool_switch()->default_value(false),
                     "Use consecutive destination ports for B2B multi-thread testing");

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
    const int  workers_per_ep = vm["workers"].as<int>();
    const auto& endpoints = vm["zmq-endpoint"].as<std::vector<std::string>>();

    e2sar::EjfatURI uri(vm["uri"].as<std::string>(),
                        e2sar::EjfatURI::TokenType::instance);

    if (!no_cp) {
        e2sar::LBManager lb_mgr(uri, false, false);
        const std::string sender_ip = vm["sender-ip"].as<std::string>();
        if (sender_ip.empty()) {
            auto reg = lb_mgr.addSenderSelf(false);
            if (reg.has_error()) {
                std::cerr << "WARNING: addSenderSelf failed: "
                          << reg.error().message() << " (proceeding anyway)" << std::endl;
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

    // Single Segmenter shared by all worker threads.
    // numSendSockets controls the internal UDP send thread pool size.
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

    const int total_workers = static_cast<int>(endpoints.size()) * workers_per_ep;

    std::cout << "ZMQ EJFAT Bridge started" << std::endl;
    for (size_t i = 0; i < endpoints.size(); i++)
        std::cout << "  ZMQ endpoint[" << i << "]: " << endpoints[i] << std::endl;
    std::cout << "  Data ID      : " << vm["data-id"].as<uint16_t>()         << std::endl;
    std::cout << "  Src ID       : " << vm["src-id"].as<uint32_t>()          << std::endl;
    std::cout << "  MTU          : " << vm["mtu"].as<uint16_t>()             << std::endl;
    std::cout << "  Sockets      : " << vm["sockets"].as<int>()
              << " (E2SAR UDP send thread pool)"                             << std::endl;
    std::cout << "  Workers      : " << total_workers
              << " (" << endpoints.size() << " endpoints x "
              << workers_per_ep << " workers each)"                          << std::endl;
    std::cout << std::endl;

    WorkerStats stats;
    std::vector<std::thread> workers;
    workers.reserve(total_workers);

    int worker_id = 0;
    for (const auto& ep : endpoints) {
        for (int w = 0; w < workers_per_ep; w++) {
            workers.emplace_back(
                workerLoop,
                worker_id++,
                ep,
                vm["rcvhwm"].as<int>(),
                std::ref(segmenter),
                vm["stats-interval"].as<int>(),
                std::ref(stats)
            );
        }
    }

    for (auto& t : workers) t.join();

    // Drain the send queue before stopping (threadPool.join() inside stopThreads)
    segmenter.stopThreads();

    auto sendStats = segmenter.getSendStats();

    std::cout << "\n=== Bridge Statistics ===" << std::endl;
    std::cout << "Endpoints                 : " << endpoints.size()          << std::endl;
    std::cout << "Workers                   : " << total_workers             << std::endl;
    std::cout << "Events received from ZMQ  : " << stats.received.load()   << std::endl;
    std::cout << "Events enqueued to E2SAR  : " << stats.sent.load()       << std::endl;
    std::cout << "Events dropped (q full)   : " << stats.dropped.load()    << std::endl;
    std::cout << "Segmenter fragments sent  : " << sendStats.msgCnt        << std::endl;
    std::cout << "Segmenter send errors     : " << sendStats.errCnt        << std::endl;
    std::cout << "=========================" << std::endl;

    return (stats.dropped.load() > 0) ? 2 : 0;
}
