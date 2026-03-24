/*
 * pipeline_validator - ZMQ PULL receiver with sequence number and payload validation
 *
 * Expects messages in the format produced by pipeline_sender:
 *   bytes 0-7 : uint64 big-endian sequence number
 *   bytes 8+  : fill pattern where each byte == (seq_num & 0xFF)
 *
 * Validates:
 *   - All expected sequence numbers are received (order-tolerant)
 *   - No duplicate sequence numbers
 *   - Payload fill pattern correctness
 *
 * Note: Out-of-order delivery is expected and tolerated — the proxy makes no
 * ordering guarantees due to multi-threaded reassembly. Only truly missing
 * sequences and actual duplicates are counted as failures.
 *
 * Exit codes:
 *   0 - All messages received and validated successfully
 *   1 - Validation errors (missing seqs, duplicates, payload corruption)
 *   2 - Timeout before expected count reached
 *
 * Used as N4 in the pipeline test.
 */

#include <zmq.hpp>
#include <boost/program_options.hpp>
#include <iostream>
#include <atomic>
#include <csignal>
#include <thread>
#include <chrono>
#include <cstring>
#include <cstdint>
#include <optional>
#include <unordered_set>
#include <vector>
#include <algorithm>

namespace po = boost::program_options;

static std::atomic<bool> g_stop{false};

void signalHandler(int) {
    g_stop.store(true);
}

static inline uint64_t from_be64(const uint8_t* p) {
    uint64_t v;
    std::memcpy(&v, p, 8);
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    return __builtin_bswap64(v);
#else
    return v;
#endif
}

static bool validate_payload(const uint8_t* data, size_t len, uint64_t seq) {
    if (len < 8) return false;
    uint8_t fill = static_cast<uint8_t>(seq & 0xFF);
    for (size_t i = 8; i < len; i++) {
        if (data[i] != fill) return false;
    }
    return true;
}

int main(int argc, char* argv[]) {
    po::options_description desc("Pipeline ZMQ PULL Validator");
    desc.add_options()
        ("help,h",           "Show this help")
        ("endpoint,e",       po::value<std::string>()->default_value("tcp://localhost:5555"),
                             "ZMQ PULL endpoint to connect to")
        ("expected,n",       po::value<uint64_t>()->default_value(1000),
                             "Number of messages to expect (0=unlimited)")
        ("timeout,t",        po::value<int>()->default_value(30),
                             "Seconds of silence before giving up")
        ("no-payload-check", po::bool_switch()->default_value(false),
                             "Skip per-byte payload validation")
        ("start-seq",        po::value<uint64_t>()->default_value(UINT64_MAX),
                             "First expected sequence number (default: auto-detect from first message)")
        ("rcvhwm",           po::value<int>()->default_value(10000),
                             "ZMQ receive HWM");

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

    const uint64_t expected         = vm["expected"].as<uint64_t>();
    const int      timeout_s        = vm["timeout"].as<int>();
    const bool     no_payload_check = vm["no-payload-check"].as<bool>();
    const uint64_t start_seq_arg    = vm["start-seq"].as<uint64_t>();
    const bool     unlimited        = (expected == 0);

    std::signal(SIGINT,  signalHandler);
    std::signal(SIGTERM, signalHandler);

    zmq::context_t ctx(1);
    zmq::socket_t  sock(ctx, zmq::socket_type::pull);
    sock.set(zmq::sockopt::rcvhwm, vm["rcvhwm"].as<int>());
    sock.connect(vm["endpoint"].as<std::string>());

    std::cout << "Pipeline validator connected to " << vm["endpoint"].as<std::string>() << std::endl;
    std::cout << "  Expecting    : " << (unlimited ? "unlimited" : std::to_string(expected)) << " messages" << std::endl;
    std::cout << "  Timeout      : " << timeout_s << "s of silence" << std::endl;
    std::cout << "  Payload check: " << (no_payload_check ? "disabled" : "enabled") << std::endl;
    if (start_seq_arg != UINT64_MAX)
        std::cout << "  Start seq    : " << start_seq_arg << std::endl;
    std::cout << "Waiting for messages...\n" << std::endl;

    uint64_t received       = 0;
    uint64_t payload_errors = 0;
    uint64_t duplicates     = 0;
    std::unordered_set<uint64_t> seen_seqs;
    seen_seqs.reserve(expected > 0 ? expected : 1024);
    bool     first_msg      = true;
    uint64_t first_seq      = 0;

    auto start_time    = std::chrono::steady_clock::now();
    auto last_recv     = start_time;
    std::chrono::steady_clock::time_point first_msg_time;
    std::chrono::steady_clock::time_point last_msg_time;
    auto timeout_dur   = std::chrono::seconds(timeout_s);

    int exit_code = 0;

    while (!g_stop.load() && (unlimited || received < expected)) {
        zmq::message_t msg;
        auto rr = sock.recv(msg, zmq::recv_flags::dontwait);

        if (!rr.has_value()) {
            // No message — check timeout
            if (std::chrono::steady_clock::now() - last_recv > timeout_dur) {
                std::cout << "TIMEOUT: No message for " << timeout_s << "s, stopping." << std::endl;
                if (!unlimited && received < expected)
                    exit_code = 2;
                break;
            }
            std::this_thread::sleep_for(std::chrono::microseconds(100));
            continue;
        }

        last_recv = std::chrono::steady_clock::now();

        if (msg.size() < 8) {
            std::cerr << "ERROR: Message too short (" << msg.size() << " bytes), skipping" << std::endl;
            payload_errors++;
            continue;
        }

        const uint8_t* data = static_cast<const uint8_t*>(msg.data());
        uint64_t seq = from_be64(data);

        if (first_msg) {
            first_seq = seq;
            first_msg = false;
        }

        // Order-tolerant duplicate detection
        if (seen_seqs.count(seq)) {
            duplicates++;
            std::cout << "DUPLICATE: seq=" << seq << std::endl;
            continue;
        }
        seen_seqs.insert(seq);
        received++;
        if (received == 1) first_msg_time = std::chrono::steady_clock::now();
        last_msg_time = std::chrono::steady_clock::now();

        // Payload check
        if (!no_payload_check) {
            if (!validate_payload(data, msg.size(), seq)) {
                payload_errors++;
                if (payload_errors <= 10)
                    std::cout << "PAYLOAD ERROR: seq=" << seq << std::endl;
            }
        }

        if (received % 10000 == 0) {
            auto now    = std::chrono::steady_clock::now();
            double elapsed = std::chrono::duration<double>(now - start_time).count();
            double r    = (elapsed > 0) ? (static_cast<double>(received) / elapsed) : 0.0;
            std::cout << "Received " << received << " | " << static_cast<int>(r) << " msg/s"
                      << " | dup=" << duplicates
                      << " err=" << payload_errors << std::endl;
        }
    }

    auto end     = std::chrono::steady_clock::now();
    double elapsed = std::chrono::duration<double>(end - start_time).count();
    double avg_rate = (elapsed > 0) ? (static_cast<double>(received) / elapsed) : 0.0;

    // Compute truly missing sequences
    uint64_t missing = 0;
    if (!unlimited && !first_msg) {
        uint64_t range_start = (start_seq_arg != UINT64_MAX) ? start_seq_arg : first_seq;
        for (uint64_t s = range_start; s < range_start + expected; s++) {
            if (!seen_seqs.count(s)) {
                missing++;
                if (missing <= 10)
                    std::cout << "MISSING: seq=" << s << std::endl;
            }
        }
        if (missing > 10)
            std::cout << "  ... (" << missing << " total missing)" << std::endl;
    }

    bool ok = (missing == 0 && duplicates == 0 && payload_errors == 0
               && (unlimited || received >= expected));

    std::cout << "\n=== Validation Summary ===" << std::endl;
    std::cout << "Messages received : " << received << std::endl;
    std::cout << "Expected          : " << (unlimited ? "unlimited" : std::to_string(expected)) << std::endl;
    std::cout << "Duration          : " << elapsed << "s" << std::endl;
    std::cout << "Average rate      : " << static_cast<int>(avg_rate) << " msg/s" << std::endl;
    std::cout << "Missing           : " << missing << std::endl;
    std::cout << "Duplicates        : " << duplicates << std::endl;
    std::cout << "Payload errors    : " << payload_errors << std::endl;
    std::cout << "Result            : " << (ok ? "PASS" : "FAIL") << std::endl;
    if (received > 1) {
        double msg_span = std::chrono::duration<double>(last_msg_time - first_msg_time).count();
        double burst_rate = (msg_span > 0) ? ((received - 1) / msg_span) : 0;
        std::cout << "First-to-last span: " << msg_span << "s" << std::endl;
        std::cout << "Burst rate        : " << static_cast<int>(burst_rate) << " msg/s" << std::endl;
    }
    std::cout << "==========================" << std::endl;

    if (!ok && exit_code == 0)
        exit_code = 1;

    sock.close();
    ctx.close();
    return exit_code;
}
