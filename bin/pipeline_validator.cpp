/*
 * pipeline_validator - ZMQ PULL receiver with sequence number and payload validation
 *
 * Expects messages in the format produced by pipeline_sender:
 *   bytes 0-7 : uint64 big-endian sequence number
 *   bytes 8+  : fill pattern where each byte == (seq_num & 0xFF)
 *
 * Validates:
 *   - Sequence continuity (gaps, duplicates, reordering)
 *   - Payload fill pattern correctness
 *
 * Exit codes:
 *   0 - All messages received and validated successfully
 *   1 - Validation errors (gaps, payload corruption, etc.)
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

    const uint64_t expected        = vm["expected"].as<uint64_t>();
    const int      timeout_s       = vm["timeout"].as<int>();
    const bool     no_payload_check = vm["no-payload-check"].as<bool>();
    const bool     unlimited       = (expected == 0);

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
    std::cout << "Waiting for messages...\n" << std::endl;

    uint64_t received       = 0;
    uint64_t payload_errors = 0;
    uint64_t gaps           = 0;
    uint64_t duplicates     = 0;
    bool     first_msg      = true;
    uint64_t next_expected  = 0;

    auto start_time    = std::chrono::steady_clock::now();
    auto last_recv     = start_time;
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
        received++;

        // Sequence check
        if (first_msg) {
            next_expected = seq + 1;
            first_msg = false;
        } else if (seq == next_expected) {
            next_expected++;
        } else if (seq < next_expected) {
            duplicates++;
            std::cout << "DUPLICATE: seq=" << seq << " (expected " << next_expected << ")" << std::endl;
            continue;
        } else {
            uint64_t gap = seq - next_expected;
            gaps += gap;
            std::cout << "GAP: seq=" << seq << " expected=" << next_expected
                      << " (missing " << gap << " messages)" << std::endl;
            next_expected = seq + 1;
        }

        // Payload check
        if (!no_payload_check) {
            if (!validate_payload(data, msg.size(), seq)) {
                payload_errors++;
                if (payload_errors <= 10)
                    std::cout << "PAYLOAD ERROR: seq=" << seq << std::endl;
            }
        }

        if (received % 1000 == 0) {
            auto now    = std::chrono::steady_clock::now();
            double elapsed = std::chrono::duration<double>(now - start_time).count();
            double r    = (elapsed > 0) ? (static_cast<double>(received) / elapsed) : 0.0;
            std::cout << "Received " << received << " | " << static_cast<int>(r) << " msg/s"
                      << " | gaps=" << gaps << " dup=" << duplicates
                      << " err=" << payload_errors << std::endl;
        }
    }

    auto end     = std::chrono::steady_clock::now();
    double elapsed = std::chrono::duration<double>(end - start_time).count();
    double avg_rate = (elapsed > 0) ? (static_cast<double>(received) / elapsed) : 0.0;

    bool ok = (gaps == 0 && duplicates == 0 && payload_errors == 0
               && (unlimited || received >= expected));

    std::cout << "\n=== Validation Summary ===" << std::endl;
    std::cout << "Messages received : " << received << std::endl;
    std::cout << "Expected          : " << (unlimited ? "unlimited" : std::to_string(expected)) << std::endl;
    std::cout << "Duration          : " << elapsed << "s" << std::endl;
    std::cout << "Average rate      : " << static_cast<int>(avg_rate) << " msg/s" << std::endl;
    std::cout << "Gaps (missing)    : " << gaps << std::endl;
    std::cout << "Duplicates        : " << duplicates << std::endl;
    std::cout << "Payload errors    : " << payload_errors << std::endl;
    std::cout << "Result            : " << (ok ? "PASS" : "FAIL") << std::endl;
    std::cout << "==========================" << std::endl;

    if (!ok && exit_code == 0)
        exit_code = 1;

    sock.close();
    ctx.close();
    return exit_code;
}
