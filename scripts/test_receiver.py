#!/usr/bin/env python3
"""
Simple ZMQ PULL test receiver for testing EJFAT ZMQ Proxy.

This script pulls messages from the proxy and optionally introduces
artificial delays to simulate a slow consumer and trigger backpressure.
"""

import zmq
import time
import argparse
import signal
import sys


class TestReceiver:
    def __init__(self, endpoint, delay_ms=0, stats_interval=1000):
        self.endpoint = endpoint
        self.delay_ms = delay_ms
        self.stats_interval = stats_interval
        self.running = True

        # Stats
        self.messages_received = 0
        self.bytes_received = 0
        self.start_time = time.time()

    def signal_handler(self, sig, frame):
        print("\nShutdown signal received...")
        self.running = False

    def run(self):
        # Setup signal handlers
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)

        # Create ZMQ context and socket
        context = zmq.Context()
        socket = context.socket(zmq.PULL)
        socket.connect(self.endpoint)

        print(f"Connected to {self.endpoint}")
        if self.delay_ms > 0:
            print(f"Artificial delay: {self.delay_ms}ms per message")
        print("Waiting for messages... (Ctrl+C to stop)\n")

        last_stats_time = time.time()

        try:
            while self.running:
                # Receive message (non-blocking with timeout)
                try:
                    message = socket.recv(flags=zmq.NOBLOCK)

                    # Update stats
                    self.messages_received += 1
                    self.bytes_received += len(message)

                    # Artificial delay to simulate slow consumer
                    if self.delay_ms > 0:
                        time.sleep(self.delay_ms / 1000.0)

                    # Print stats periodically
                    if self.messages_received % self.stats_interval == 0:
                        self.print_stats()

                except zmq.Again:
                    # No message available, brief sleep
                    time.sleep(0.001)
                    continue

                # Print stats every second even if no messages
                now = time.time()
                if now - last_stats_time >= 1.0:
                    if self.messages_received > 0:
                        self.print_stats()
                    last_stats_time = now

        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
        finally:
            socket.close()
            context.term()

        # Final stats
        print("\n=== Final Statistics ===")
        self.print_stats()
        print("========================")

    def print_stats(self):
        elapsed = time.time() - self.start_time
        rate = self.messages_received / elapsed if elapsed > 0 else 0
        throughput = (self.bytes_received / elapsed / 1024 / 1024) if elapsed > 0 else 0

        print(f"Messages: {self.messages_received:,} | "
              f"Rate: {rate:,.1f} msg/s | "
              f"Throughput: {throughput:.2f} MB/s | "
              f"Bytes: {self.bytes_received:,}")


def main():
    parser = argparse.ArgumentParser(
        description="ZMQ PULL test receiver for EJFAT ZMQ Proxy"
    )
    parser.add_argument(
        "--endpoint", "-e",
        default="tcp://localhost:5555",
        help="ZMQ endpoint to connect to (default: tcp://localhost:5555)"
    )
    parser.add_argument(
        "--delay", "-d",
        type=int,
        default=0,
        help="Artificial delay in milliseconds per message (default: 0, no delay)"
    )
    parser.add_argument(
        "--stats-interval", "-s",
        type=int,
        default=1000,
        help="Print stats every N messages (default: 1000)"
    )

    args = parser.parse_args()

    receiver = TestReceiver(
        endpoint=args.endpoint,
        delay_ms=args.delay,
        stats_interval=args.stats_interval
    )

    receiver.run()


if __name__ == "__main__":
    main()
