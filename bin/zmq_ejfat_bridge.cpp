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
#include "ejfat_zmq_proxy/config.hpp"
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
    // Required parameters (no defaults)
    po::options_description required("Required");
    required.add_options()
        ("uri,u",    po::value<std::string>(),
                     "EJFAT instance URI — must be set here or via --config\n"
                     "  e.g. ejfat://token@lb.es.net:443/lb/xyz"
                     "?data=10.0.0.1&sync=10.0.0.1:19522");

    // All other options have built-in defaults
    po::options_description opts("Options");
    opts.add_options()
        ("help,h",         "Show this help")
        ("config,c",       po::value<std::string>(),
                           "Configuration file (YAML); CLI flags override YAML values")
        ("zmq-endpoint,e", po::value<std::vector<std::string>>()->composing(),
                           "ZMQ PULL endpoint (repeat for multiple; overrides config list)\n"
                           "  [default: tcp://localhost:5556]")
        ("data-id,d",      po::value<uint16_t>(),
                           "E2SAR data ID in the Reassembly Header [default: 1]")
        ("src-id,s",       po::value<uint32_t>(),
                           "E2SAR source ID in the Sync header [default: 1]")
        ("mtu,m",          po::value<uint16_t>(),
                           "MTU in bytes — use 1500 for localhost, 9000 for jumbo [default: 9000]")
        ("sockets",        po::value<int>(),
                           "UDP send sockets (E2SAR internal thread pool size) [default: 16]")
        ("workers",        po::value<int>(),
                           "ZMQ PULL receiver threads per endpoint [default: 1]")
        ("rcvhwm",         po::value<int>(),
                           "ZMQ receive high-water mark per worker socket [default: 10000]")
        ("stats-interval", po::value<int>(),
                           "Stats print interval in seconds [default: 10, 0=disable]")
        ("sender-ip",      po::value<std::string>(),
                           "Sender IP to register with LB CP [default: auto-detect]")
        ("no-cp",          po::bool_switch()->default_value(false),
                           "Disable control plane for B2B/local testing [default: false]")
        ("multiport",      po::bool_switch()->default_value(false),
                           "Use consecutive destination ports for B2B multi-thread testing [default: false]");

    po::options_description all;
    all.add(required).add(opts);

    po::variables_map vm;
    try {
        po::store(po::parse_command_line(argc, argv, all), vm);
        if (vm.count("help")) {
            std::cout << all << "\n";
            std::cout << R"(
Examples:

  Back-to-back (no load balancer) — run alongside ejfat_zmq_proxy on localhost:
    zmq_ejfat_bridge --no-cp \
      --uri "ejfat://unused@127.0.0.1:9876/lb/1?data=127.0.0.1:19522&sync=127.0.0.1:19523" \
      --zmq-endpoint tcp://sender-host:5556 \
      --mtu 1500

    Use the same URI on the proxy side (--use-cp=false --with-lb-header=true).
    The URI ?data= address is where the proxy's Reassembler listens — the bridge
    sends UDP there. Use --mtu 1500 for localhost; 9000 for jumbo-frame networks.

  With a real load balancer:
    zmq_ejfat_bridge \
      --uri "ejfats://token@lb.es.net:443/lb/session?data=10.0.0.1&sync=10.0.0.1:19522" \
      --zmq-endpoint tcp://sender-host:5556

    Multiple ZMQ senders (each --zmq-endpoint spawns --workers pull threads):
    zmq_ejfat_bridge \
      --uri "ejfats://token@lb.es.net:443/lb/session?data=10.0.0.1&sync=10.0.0.1:19522" \
      --zmq-endpoint tcp://sender-a:5556 \
      --zmq-endpoint tcp://sender-b:5557 \
      --workers 2 --sockets 16

  Via YAML config file (all options above can be set in the file; CLI overrides YAML):
    zmq_ejfat_bridge --config /path/to/bridge.yaml
    zmq_ejfat_bridge --config /path/to/bridge.yaml --mtu 1500
)" << std::endl;
            return 0;
        }
        po::notify(vm);
    } catch (const po::error& e) {
        std::cerr << "ERROR: " << e.what() << std::endl;
        std::cerr << all << std::endl;
        return 1;
    }

    // Load config from YAML if provided, then apply CLI overrides
    ejfat_zmq_proxy::BridgeConfig config;
    if (vm.count("config")) {
        std::string config_file = vm["config"].as<std::string>();
        std::cout << "Loading configuration from: " << config_file << std::endl;
        try {
            config = ejfat_zmq_proxy::BridgeConfig::loadFromYaml(config_file);
        } catch (const std::exception& e) {
            std::cerr << "ERROR: " << e.what() << std::endl;
            return 1;
        }
    } else {
        config = ejfat_zmq_proxy::BridgeConfig::getDefault();
    }

    // Apply CLI overrides (vm.count > 0 only when the user explicitly passed the flag)
    if (vm.count("uri"))            config.uri           = vm["uri"].as<std::string>();
    if (vm.count("zmq-endpoint"))   config.zmq_endpoints = vm["zmq-endpoint"].as<std::vector<std::string>>();
    if (vm.count("data-id"))        config.data_id       = vm["data-id"].as<uint16_t>();
    if (vm.count("src-id"))         config.src_id        = vm["src-id"].as<uint32_t>();
    if (vm.count("mtu"))            config.mtu           = vm["mtu"].as<uint16_t>();
    if (vm.count("sockets"))        config.sockets       = vm["sockets"].as<int>();
    if (vm.count("workers"))        config.workers       = vm["workers"].as<int>();
    if (vm.count("rcvhwm"))         config.rcvhwm        = vm["rcvhwm"].as<int>();
    if (vm.count("stats-interval")) config.stats_interval = vm["stats-interval"].as<int>();
    if (vm.count("sender-ip"))      config.sender_ip     = vm["sender-ip"].as<std::string>();
    // bool_switch: present means true; absent preserves YAML/default value
    if (vm["no-cp"].as<bool>())     config.no_cp         = true;
    if (vm["multiport"].as<bool>()) config.multiport     = true;

    if (config.uri.empty()) {
        std::cerr << "ERROR: EJFAT URI not specified (use --uri or set bridge.uri in config file)" << std::endl;
        return 1;
    }
    try {
        config.validate();
    } catch (const std::exception& e) {
        std::cerr << "ERROR: " << e.what() << std::endl;
        return 1;
    }

    std::signal(SIGINT,  signalHandler);
    std::signal(SIGTERM, signalHandler);

    e2sar::EjfatURI uri(config.uri, e2sar::EjfatURI::TokenType::instance);

    if (!config.no_cp) {
        e2sar::LBManager lb_mgr(uri, false, false);
        if (config.sender_ip.empty()) {
            auto reg = lb_mgr.addSenderSelf(false);
            if (reg.has_error()) {
                std::cerr << "WARNING: addSenderSelf failed: "
                          << reg.error().message() << " (proceeding anyway)" << std::endl;
            } else {
                std::cout << "Registered as sender with LB CP (auto-detected IP)" << std::endl;
            }
        } else {
            auto reg = lb_mgr.addSenders(std::vector<std::string>{config.sender_ip});
            if (reg.has_error()) {
                std::cerr << "WARNING: addSenders(" << config.sender_ip << ") failed: "
                          << reg.error().message() << " (proceeding anyway)" << std::endl;
            } else {
                std::cout << "Registered as sender with LB CP: " << config.sender_ip << std::endl;
            }
        }
    }

    // Single Segmenter shared by all worker threads.
    // numSendSockets controls the internal UDP send thread pool size.
    e2sar::Segmenter::SegmenterFlags sflags;
    sflags.useCP          = !config.no_cp;
    sflags.mtu            = config.mtu;
    sflags.numSendSockets = static_cast<size_t>(config.sockets);
    sflags.warmUpMs       = config.no_cp ? 0 : 500;
    sflags.multiPort      = config.multiport;

    e2sar::Segmenter segmenter(
        uri,
        config.data_id,
        config.src_id,
        sflags
    );

    auto startRes = segmenter.openAndStart();
    if (!startRes) {
        std::cerr << "ERROR: Failed to start segmenter" << std::endl;
        return 1;
    }

    const int total_workers = static_cast<int>(config.zmq_endpoints.size()) * config.workers;

    std::cout << "ZMQ EJFAT Bridge started" << std::endl;
    for (size_t i = 0; i < config.zmq_endpoints.size(); i++)
        std::cout << "  ZMQ endpoint[" << i << "]: " << config.zmq_endpoints[i] << std::endl;
    std::cout << "  Data ID      : " << config.data_id                              << std::endl;
    std::cout << "  Src ID       : " << config.src_id                               << std::endl;
    std::cout << "  MTU          : " << config.mtu                                  << std::endl;
    std::cout << "  Sockets      : " << config.sockets
              << " (E2SAR UDP send thread pool)"                                     << std::endl;
    std::cout << "  Workers      : " << total_workers
              << " (" << config.zmq_endpoints.size() << " endpoints x "
              << config.workers << " workers each)"                                  << std::endl;
    std::cout << std::endl;

    WorkerStats stats;
    std::vector<std::thread> workers;
    workers.reserve(total_workers);

    int worker_id = 0;
    for (const auto& ep : config.zmq_endpoints) {
        for (int w = 0; w < config.workers; w++) {
            workers.emplace_back(
                workerLoop,
                worker_id++,
                ep,
                config.rcvhwm,
                std::ref(segmenter),
                config.stats_interval,
                std::ref(stats)
            );
        }
    }

    for (auto& t : workers) t.join();

    // Drain the send queue before stopping (threadPool.join() inside stopThreads)
    segmenter.stopThreads();

    auto sendStats = segmenter.getSendStats();

    std::cout << "\n=== Bridge Statistics ===" << std::endl;
    std::cout << "Endpoints                 : " << config.zmq_endpoints.size()   << std::endl;
    std::cout << "Workers                   : " << total_workers                  << std::endl;
    std::cout << "Events received from ZMQ  : " << stats.received.load()         << std::endl;
    std::cout << "Events enqueued to E2SAR  : " << stats.sent.load()             << std::endl;
    std::cout << "Events dropped (q full)   : " << stats.dropped.load()          << std::endl;
    std::cout << "Segmenter fragments sent  : " << sendStats.msgCnt              << std::endl;
    std::cout << "Segmenter send errors     : " << sendStats.errCnt              << std::endl;
    std::cout << "=========================" << std::endl;

    return (stats.dropped.load() > 0) ? 2 : 0;
}
