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
        // Parse command line
        po::options_description desc("EJFAT ZMQ Proxy Options");
        desc.add_options()
            ("help,h", "Show this help message")
            ("config,c", po::value<std::string>(), "Configuration file (YAML)")
            ("uri", po::value<std::string>(), "EJFAT URI (overrides config)")
            ("endpoint", po::value<std::string>(), "ZMQ PUSH endpoint (overrides config)")
            ("stats-interval", po::value<int>()->default_value(10), "Stats print interval (seconds, 0=disabled)");

        po::variables_map vm;
        po::store(po::parse_command_line(argc, argv, desc), vm);
        po::notify(vm);

        if (vm.count("help")) {
            std::cout << desc << std::endl;
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

        // Apply command-line overrides
        if (vm.count("uri")) {
            config.ejfat.uri = vm["uri"].as<std::string>();
            std::cout << "URI override: " << config.ejfat.uri << std::endl;
        }

        if (vm.count("endpoint")) {
            config.zmq.push_endpoint = vm["endpoint"].as<std::string>();
            std::cout << "ZMQ endpoint override: " << config.zmq.push_endpoint << std::endl;
        }

        // Validate required config
        if (config.ejfat.uri.empty()) {
            std::cerr << "ERROR: EJFAT URI not specified (use --uri or config file)" << std::endl;
            return 1;
        }

        // Setup signal handlers
        std::signal(SIGINT, signalHandler);
        std::signal(SIGTERM, signalHandler);

        // Create and start proxy
        ejfat_zmq_proxy::EjfatZmqProxy proxy(config);
        g_proxy = &proxy;

        proxy.start();

        // Main loop - print stats periodically
        int stats_interval = vm["stats-interval"].as<int>();
        auto last_stats_time = std::chrono::steady_clock::now();

        while (!shutdown_requested.load()) {
            std::this_thread::sleep_for(std::chrono::seconds(1));

            if (stats_interval > 0) {
                auto now = std::chrono::steady_clock::now();
                auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                    now - last_stats_time).count();

                if (elapsed >= stats_interval) {
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
