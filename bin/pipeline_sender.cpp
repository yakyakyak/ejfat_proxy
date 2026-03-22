/*
 * pipeline_sender - ZMQ PUSH sender with verifiable sequence-numbered messages
 *
 * Message format (compatible with pipeline_validator):
 *   bytes 0-7 : uint64 big-endian sequence number (starts at 0)
 *   bytes 8+  : fill pattern where each byte == (seq_num & 0xFF)
 *
 * Used as N1 in the pipeline test:
 *   pipeline_sender -> zmq_ejfat_bridge -> ejfat_zmq_proxy -> pipeline_validator
 */

#include <zmq.hpp>
#include <boost/program_options.hpp>
#include <iostream>
#include <atomic>
#include <csignal>
#include <thread>
#include <chrono>
#include <cstring>
#include <vector>

namespace po = boost::program_options;

static std::atomic<bool> g_stop{false};

void signalHandler(int) {
    g_stop.store(true);
}

static inline uint64_t to_be64(uint64_t v) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    return __builtin_bswap64(v);
#else
    return v;
#endif
}

int main(int argc, char* argv[]) {
    po::options_description desc("Pipeline ZMQ PUSH Sender");
    desc.add_options()
        ("help,h",     "Show this help")
        ("endpoint,e", po::value<std::string>()->default_value("tcp://*:5556"),
                       "ZMQ PUSH bind endpoint")
        ("count,n",    po::value<uint64_t>()->default_value(1000),
                       "Number of messages to send (0=unlimited)")
        ("size,s",     po::value<int>()->default_value(4096),
                       "Message size in bytes (min: 8)")
        ("rate,r",     po::value<int>()->default_value(100),
                       "Messages per second (0=unlimited)")
        ("hwm",        po::value<int>()->default_value(10000),
                       "ZMQ send HWM");

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

    const int msg_size = vm["size"].as<int>();
    if (msg_size < 8) {
        std::cerr << "ERROR: --size must be >= 8 (sequence number header is 8 bytes)" << std::endl;
        return 1;
    }

    const uint64_t count    = vm["count"].as<uint64_t>();
    const int      rate     = vm["rate"].as<int>();
    const bool     unlimited = (count == 0);

    std::signal(SIGINT,  signalHandler);
    std::signal(SIGTERM, signalHandler);

    zmq::context_t ctx(1);
    zmq::socket_t  sock(ctx, zmq::socket_type::push);
    sock.set(zmq::sockopt::sndhwm, vm["hwm"].as<int>());
    sock.bind(vm["endpoint"].as<std::string>());

    // Pre-allocate reusable send buffer
    std::vector<uint8_t> buf(static_cast<size_t>(msg_size), 0);

    const std::chrono::nanoseconds sleep_ns =
        (rate > 0) ? std::chrono::nanoseconds(1'000'000'000LL / rate)
                   : std::chrono::nanoseconds(0);

    std::cout << "Pipeline sender bound to " << vm["endpoint"].as<std::string>() << std::endl;
    std::cout << "  Message size : " << msg_size << " bytes" << std::endl;
    std::cout << "  Count        : " << (unlimited ? "unlimited" : std::to_string(count)) << std::endl;
    std::cout << "  Rate         : " << (rate == 0 ? "unlimited" : std::to_string(rate) + " msg/s") << std::endl;
    std::cout << "Waiting 1s for downstream connections..." << std::endl;
    std::this_thread::sleep_for(std::chrono::seconds(1));
    std::cout << "Sending...\n" << std::endl;

    uint64_t sent  = 0;
    auto     start = std::chrono::steady_clock::now();
    auto     next_send = start;

    while (!g_stop.load() && (unlimited || sent < count)) {
        uint64_t seq       = sent;
        uint64_t seq_be    = to_be64(seq);
        uint8_t  fill_byte = static_cast<uint8_t>(seq & 0xFF);

        std::memcpy(buf.data(), &seq_be, 8);
        std::memset(buf.data() + 8, fill_byte, static_cast<size_t>(msg_size - 8));

        zmq::message_t msg(buf.data(), static_cast<size_t>(msg_size));

        auto result = sock.send(msg, zmq::send_flags::dontwait);
        if (!result.has_value()) {
            // Send buffer full — backpressure, yield briefly
            std::this_thread::sleep_for(std::chrono::microseconds(1));
            continue;
        }

        sent++;

        if (sent % 1000 == 0) {
            auto now     = std::chrono::steady_clock::now();
            double elapsed = std::chrono::duration<double>(now - start).count();
            double r     = (elapsed > 0) ? (static_cast<double>(sent) / elapsed) : 0.0;
            std::cout << "Sent " << sent << " | " << static_cast<int>(r) << " msg/s" << std::endl;
        }

        if (rate > 0) {
            next_send += sleep_ns;
            auto now = std::chrono::steady_clock::now();
            if (next_send > now)
                std::this_thread::sleep_until(next_send);
        }
    }

    auto end     = std::chrono::steady_clock::now();
    double elapsed = std::chrono::duration<double>(end - start).count();
    double avg_rate = (elapsed > 0) ? (static_cast<double>(sent) / elapsed) : 0.0;

    std::cout << "\n=== Sender Summary ===" << std::endl;
    std::cout << "Messages sent : " << sent << std::endl;
    std::cout << "Duration      : " << elapsed << "s" << std::endl;
    std::cout << "Average rate  : " << static_cast<int>(avg_rate) << " msg/s" << std::endl;
    std::cout << "Throughput    : "
              << static_cast<double>(sent * static_cast<uint64_t>(msg_size)) / 1e9 / elapsed
              << " GB/s" << std::endl;
    std::cout << "======================" << std::endl;

    sock.close();
    ctx.close();
    return 0;
}
