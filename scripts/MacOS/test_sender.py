#!/usr/bin/env python3
"""
Simple ZMQ PUSH test sender for testing the ZMQ receiver independently.
This bypasses EJFAT and directly tests the ZMQ components.
"""

import zmq
import time
import argparse
import signal
import sys


class TestSender:
    def __init__(self, endpoint, rate=100, message_size=1024):
        self.endpoint = endpoint
        self.rate = rate  # messages per second
        self.message_size = message_size
        self.running = True
        self.messages_sent = 0

    def signal_handler(self, sig, frame):
        print("\nShutdown signal received...")
        self.running = False

    def run(self):
        # Setup signal handlers
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)

        # Create ZMQ context and socket
        context = zmq.Context()
        socket = context.socket(zmq.PUSH)
        socket.bind(self.endpoint)

        print(f"Bound to {self.endpoint}")
        print(f"Sending {self.rate} messages/sec, {self.message_size} bytes each")
        print("Waiting for subscriber connection...")

        # Give time for connections to establish
        time.sleep(0.5)
        print("Starting to send...\n")

        # Calculate sleep time to achieve target rate
        sleep_time = 1.0 / self.rate if self.rate > 0 else 0

        start_time = time.time()

        try:
            while self.running:
                # Create test message
                message = b"X" * self.message_size

                # Send message (blocking with timeout)
                try:
                    socket.send(message, flags=zmq.DONTWAIT)
                    self.messages_sent += 1
                except zmq.Again:
                    # Backpressure - wait a bit
                    time.sleep(0.01)
                    continue

                # Print stats every 1000 messages
                if self.messages_sent % 1000 == 0:
                    elapsed = time.time() - start_time
                    actual_rate = self.messages_sent / elapsed if elapsed > 0 else 0
                    print(f"Sent: {self.messages_sent:,} messages | "
                          f"Rate: {actual_rate:.1f} msg/s")

                # Rate limiting
                if sleep_time > 0:
                    time.sleep(sleep_time)

        except zmq.Again:
            print("Send buffer full (backpressure detected)")
        except Exception as e:
            print(f"Error: {e}", file=sys.stderr)
        finally:
            socket.close()
            context.term()

        # Final stats
        elapsed = time.time() - start_time
        actual_rate = self.messages_sent / elapsed if elapsed > 0 else 0
        print(f"\n=== Final Statistics ===")
        print(f"Messages sent: {self.messages_sent:,}")
        print(f"Duration: {elapsed:.2f}s")
        print(f"Average rate: {actual_rate:.1f} msg/s")
        print("========================")


def main():
    parser = argparse.ArgumentParser(
        description="ZMQ PUSH test sender"
    )
    parser.add_argument(
        "--endpoint", "-e",
        default="tcp://*:5555",
        help="ZMQ endpoint to bind to (default: tcp://*:5555)"
    )
    parser.add_argument(
        "--rate", "-r",
        type=int,
        default=100,
        help="Messages per second (default: 100, 0=unlimited)"
    )
    parser.add_argument(
        "--size", "-s",
        type=int,
        default=1024,
        help="Message size in bytes (default: 1024)"
    )

    args = parser.parse_args()

    sender = TestSender(
        endpoint=args.endpoint,
        rate=args.rate,
        message_size=args.size
    )

    sender.run()


if __name__ == "__main__":
    main()
