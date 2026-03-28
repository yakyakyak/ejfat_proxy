#include "ejfat_zmq_proxy/proxy.hpp"
#include "ejfat_zmq_proxy/config.hpp"
#include <boost/program_options.hpp>
#include <iostream>
#include <csignal>
#include <atomic>
#include <thread>
#include <chrono>

namespace po = boost::program_options;

static std::atomic<bool> shutdown_requested{false};
static ejfat_zmq_proxy::EjfatZmqProxy* g_proxy = nullptr;

void signalHandler(int signal) {
    if (signal == SIGINT || signal == SIGTERM) {
        std::cout << "\nShutdown signal received..." << std::endl;
        shutdown_requested.store(true);
        if (g_proxy) {
            g_proxy->stop();
        }
    }
}

int main(int argc, char* argv[]) {
    try {
        // Required parameters (no defaults)
        po::options_description required("Required");
        required.add_options()
            ("uri",                po::value<std::string>(),
                                   "EJFAT URI — must be set here or via --config\n"
                                   "  e.g. ejfats://token@lb.es.net:443/lb/xyz"
                                   "?data=10.0.0.1&sync=10.0.0.1:19522");

        // General / startup options
        po::options_description general("General");
        general.add_options()
            ("help,h",         "Show this help message")
            ("config,c",       po::value<std::string>(),
                               "Configuration file (YAML); all options below can be\n"
                               "  set there and overridden by these CLI flags")
            ("stats-interval", po::value<int>(),
                               "Stats print interval in seconds (0=disabled) [default: 10]");

        po::options_description ejfat_opts("EJFAT / E2SAR");
        ejfat_opts.add_options()
            ("use-cp",             po::value<bool>(),
                                   "Use gRPC control plane for LB registration [default: true]")
            ("worker-name",        po::value<std::string>(),
                                   "Worker name registered with the LB [default: zmq-proxy-1]")
            ("data-port",          po::value<uint16_t>(),
                                   "UDP port to receive reassembled events [1024-65535, default: 10000]")
            ("data-ip",            po::value<std::string>(),
                                   "Listen IP address [default: auto-detect; set explicitly on macOS]")
            ("with-lb-header",     po::value<bool>(),
                                   "Expect LB headers in packets — true for B2B/local testing [default: false]")
            ("num-recv-threads",   po::value<uint32_t>(),
                                   "E2SAR UDP receive threads [1-128, default: 1]")
            ("event-timeout-ms",   po::value<uint32_t>(),
                                   "Event assembly timeout [10-10000 ms, default: 500]")
            ("rcv-socket-buf-size",po::value<uint32_t>(),
                                   "UDP socket receive buffer [64KB-100MB, default: 3145728]")
            ("validate-cert",      po::value<bool>(),
                                   "Validate TLS certificates for CP connection [default: true]")
            ("sched-weight",       po::value<float>(),
                                   "Worker priority weight sent to LB [default: 1.0]")
            ("sched-min-factor",   po::value<float>(),
                                   "Minimum slot allocation factor [default: 0.5]")
            ("sched-max-factor",   po::value<float>(),
                                   "Maximum slot allocation factor [default: 2.0]");

        po::options_description zmq_opts("ZMQ");
        zmq_opts.add_options()
            ("endpoint",           po::value<std::string>(),
                                   "ZMQ PUSH socket bind address [default: tcp://*:5555]")
            ("zmq-send-hwm",       po::value<int>(),
                                   "Send high-water mark — messages queued before blocking [1-1000000, default: 1000]")
            ("zmq-io-threads",     po::value<int>(),
                                   "ZMQ context I/O threads [1-16, default: 1]")
            ("zmq-poll-sleep-us",  po::value<uint32_t>(),
                                   "Sleep when ring buffer is empty [1-10000 us, default: 100]")
            ("zmq-linger-ms",      po::value<int>(),
                                   "Socket linger time on close [default: 0]")
            ("zmq-sndbuf",         po::value<int>(),
                                   "SO_SNDBUF size in bytes [default: 0 (OS default)]");

        po::options_description bp_opts("Backpressure");
        bp_opts.add_options()
            ("bp-period-ms",       po::value<uint32_t>(),
                                   "Feedback reporting interval [default: 100 ms]")
            ("bp-ready-threshold", po::value<float>(),
                                   "Fill level above which worker reports not-ready [0.5-1.0, default: 0.95]")
            ("bp-log-interval",    po::value<uint32_t>(),
                                   "Log backpressure state every N updates [default: 50, 0=disable]")
            ("bp-control-min",     po::value<float>(),
                                   "Minimum PID output value [default: 0.0]")
            ("bp-control-max",     po::value<float>(),
                                   "Maximum PID output value [default: 1.0]")
            ("pid-setpoint",       po::value<float>(),
                                   "Target ring buffer fill level [0.0-1.0, default: 0.5]")
            ("pid-kp",             po::value<float>(),
                                   "PID proportional gain [default: 1.0]")
            ("pid-ki",             po::value<float>(),
                                   "PID integral gain [default: 0.0 (disabled)]")
            ("pid-kd",             po::value<float>(),
                                   "PID derivative gain [default: 0.0 (disabled)]")
            ("pid-integral-limit", po::value<float>(),
                                   "Anti-windup clamp on integral term [default: 10.0]");

        po::options_description buf_opts("Buffer");
        buf_opts.add_options()
            ("buffer-size",        po::value<size_t>(),
                                   "Ring buffer capacity in events [100-1000000, default: 2000]")
            ("recv-timeout-ms",    po::value<int>(),
                                   "E2SAR recvEvent poll timeout [default: 100 ms]");

        po::options_description log_opts("Logging");
        log_opts.add_options()
            ("drop-warn-interval", po::value<uint32_t>(),
                                   "Warn every N dropped events [default: 1000, 0=disable]")
            ("progress-interval",  po::value<uint32_t>(),
                                   "Log progress every N received events [default: 10000, 0=disable]");

        po::options_description all;
        all.add(required).add(general).add(ejfat_opts).add(zmq_opts).add(bp_opts).add(buf_opts).add(log_opts);

        po::variables_map vm;
        po::store(po::parse_command_line(argc, argv, all), vm);
        po::notify(vm);

        if (vm.count("help")) {
            std::cout << all << "\n";
            std::cout << R"(
Examples:

  Back-to-back (no load balancer) — run alongside zmq_ejfat_bridge on localhost:
    ejfat_zmq_proxy \
      --uri "ejfat://unused@127.0.0.1:9876/lb/1?data=127.0.0.1:19522&sync=127.0.0.1:19523" \
      --use-cp=false --with-lb-header=true \
      --data-ip=127.0.0.1 --data-port=19522 \
      --endpoint tcp://*:5555

    The URI ?data= address must match --data-ip and --data-port.
    Use the same URI on the bridge side (--no-cp).

  With a real load balancer:
    ejfat_zmq_proxy \
      --uri "ejfats://token@lb.es.net:443/lb/session?data=10.0.0.1&sync=10.0.0.1:19522" \
      --data-ip=10.0.0.1 \
      --endpoint tcp://*:5555

    The URI is obtained from the LB admin (ejfats:// = TLS + control plane).
    --data-ip must match the IP in the URI ?data= parameter.

  Via YAML config file (all options above can be set in the file; CLI overrides YAML):
    ejfat_zmq_proxy --config /path/to/config.yaml
    ejfat_zmq_proxy --config /path/to/config.yaml --endpoint tcp://*:5556
)" << std::endl;
            return 0;
        }

        // Load configuration
        ejfat_zmq_proxy::ProxyConfig config;
        if (vm.count("config")) {
            std::string config_file = vm["config"].as<std::string>();
            std::cout << "Loading configuration from: " << config_file << std::endl;
            config = ejfat_zmq_proxy::ProxyConfig::loadFromYaml(config_file);
        } else {
            std::cout << "Using default configuration" << std::endl;
            config = ejfat_zmq_proxy::ProxyConfig::getDefault();
        }

        // Apply CLI overrides (vm.count > 0 only when the user explicitly passed the flag)
        // EJFAT
        if (vm.count("uri"))                 config.ejfat.uri                     = vm["uri"].as<std::string>();
        if (vm.count("use-cp"))              config.ejfat.use_cp                  = vm["use-cp"].as<bool>();
        if (vm.count("worker-name"))         config.ejfat.worker_name             = vm["worker-name"].as<std::string>();
        if (vm.count("data-port"))           config.ejfat.data_port               = vm["data-port"].as<uint16_t>();
        if (vm.count("data-ip"))             config.ejfat.data_ip                 = vm["data-ip"].as<std::string>();
        if (vm.count("with-lb-header"))      config.ejfat.with_lb_header          = vm["with-lb-header"].as<bool>();
        if (vm.count("num-recv-threads"))    config.ejfat.num_recv_threads        = vm["num-recv-threads"].as<uint32_t>();
        if (vm.count("event-timeout-ms"))    config.ejfat.event_timeout_ms        = vm["event-timeout-ms"].as<uint32_t>();
        if (vm.count("rcv-socket-buf-size")) config.ejfat.rcv_socket_buf_size     = vm["rcv-socket-buf-size"].as<uint32_t>();
        if (vm.count("validate-cert"))       config.ejfat.validate_cert           = vm["validate-cert"].as<bool>();
        if (vm.count("sched-weight"))        config.ejfat.scheduling.weight       = vm["sched-weight"].as<float>();
        if (vm.count("sched-min-factor"))    config.ejfat.scheduling.min_factor   = vm["sched-min-factor"].as<float>();
        if (vm.count("sched-max-factor"))    config.ejfat.scheduling.max_factor   = vm["sched-max-factor"].as<float>();
        // ZMQ
        if (vm.count("endpoint"))            config.zmq.push_endpoint             = vm["endpoint"].as<std::string>();
        if (vm.count("zmq-send-hwm"))        config.zmq.send_hwm                  = vm["zmq-send-hwm"].as<int>();
        if (vm.count("zmq-io-threads"))      config.zmq.io_threads                = vm["zmq-io-threads"].as<int>();
        if (vm.count("zmq-poll-sleep-us"))   config.zmq.poll_sleep_us             = vm["zmq-poll-sleep-us"].as<uint32_t>();
        if (vm.count("zmq-linger-ms"))       config.zmq.linger_ms                 = vm["zmq-linger-ms"].as<int>();
        if (vm.count("zmq-sndbuf"))          config.zmq.sndbuf                    = vm["zmq-sndbuf"].as<int>();
        // Backpressure
        if (vm.count("bp-period-ms"))        config.backpressure.period_ms        = vm["bp-period-ms"].as<uint32_t>();
        if (vm.count("bp-ready-threshold"))  config.backpressure.ready_threshold  = vm["bp-ready-threshold"].as<float>();
        if (vm.count("bp-log-interval"))     config.backpressure.log_interval     = vm["bp-log-interval"].as<uint32_t>();
        if (vm.count("bp-control-min"))      config.backpressure.control_min      = vm["bp-control-min"].as<float>();
        if (vm.count("bp-control-max"))      config.backpressure.control_max      = vm["bp-control-max"].as<float>();
        if (vm.count("pid-setpoint"))        config.backpressure.pid.setpoint     = vm["pid-setpoint"].as<float>();
        if (vm.count("pid-kp"))              config.backpressure.pid.kp           = vm["pid-kp"].as<float>();
        if (vm.count("pid-ki"))              config.backpressure.pid.ki           = vm["pid-ki"].as<float>();
        if (vm.count("pid-kd"))              config.backpressure.pid.kd           = vm["pid-kd"].as<float>();
        if (vm.count("pid-integral-limit"))  config.backpressure.pid.integral_limit = vm["pid-integral-limit"].as<float>();
        // Buffer
        if (vm.count("buffer-size"))         config.buffer.size                   = vm["buffer-size"].as<size_t>();
        if (vm.count("recv-timeout-ms"))     config.buffer.recv_timeout_ms        = vm["recv-timeout-ms"].as<int>();
        // Logging
        if (vm.count("drop-warn-interval"))  config.logging.drop_warn_interval    = vm["drop-warn-interval"].as<uint32_t>();
        if (vm.count("progress-interval"))   config.logging.progress_interval     = vm["progress-interval"].as<uint32_t>();
        if (vm.count("stats-interval"))      config.stats_interval                = vm["stats-interval"].as<int>();

        // Validate required config
        if (config.ejfat.uri.empty()) {
            std::cerr << "ERROR: EJFAT URI not specified (use --uri or config file)" << std::endl;
            return 1;
        }
        config.validate();

        // Setup signal handlers
        std::signal(SIGINT, signalHandler);
        std::signal(SIGTERM, signalHandler);

        // Create and start proxy
        ejfat_zmq_proxy::EjfatZmqProxy proxy(config);
        g_proxy = &proxy;

        proxy.start();

        // Main loop - print stats periodically
        auto last_stats_time = std::chrono::steady_clock::now();

        while (!shutdown_requested.load()) {
            std::this_thread::sleep_for(std::chrono::seconds(1));

            if (config.stats_interval > 0) {
                auto now = std::chrono::steady_clock::now();
                auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                    now - last_stats_time).count();

                if (elapsed >= config.stats_interval) {
                    proxy.printStats();
                    last_stats_time = now;
                }
            }
        }

        // Clean shutdown
        std::cout << "Shutting down..." << std::endl;
        proxy.stop();
        proxy.join();

        // Final stats
        std::cout << "\nFinal statistics:" << std::endl;
        proxy.printStats();

        g_proxy = nullptr;
        std::cout << "Shutdown complete" << std::endl;

        return 0;

    } catch (const std::exception& e) {
        std::cerr << "FATAL ERROR: " << e.what() << std::endl;
        return 1;
    }
}
