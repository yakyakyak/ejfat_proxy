#!/usr/bin/env python3
"""
Pipeline test sender: ZMQ PUSH with verifiable sequence-numbered messages.

Message format:
  bytes 0-7 : uint64 big-endian sequence number (starts at 0)
  bytes 8+  : fill pattern where each byte == (seq_num & 0xFF)

Used as N1 in the pipeline test:
  pipeline_sender -> zmq_ejfat_bridge -> ejfat_zmq_proxy -> pipeline_validator
"""

import struct
import zmq
import time
import argparse
import signal
import sys


def main():
    parser = argparse.ArgumentParser(description="Pipeline test ZMQ PUSH sender")
    parser.add_argument("--endpoint", "-e", default="tcp://*:5556",
                        help="ZMQ PUSH bind endpoint (default: tcp://*:5556)")
    parser.add_argument("--count", "-n", type=int, default=1000,
                        help="Number of messages to send (0=unlimited, default: 1000)")
    parser.add_argument("--size", "-s", type=int, default=4096,
                        help="Message size in bytes (default: 4096, min: 8)")
    parser.add_argument("--rate", "-r", type=int, default=100,
                        help="Messages per second (0=unlimited, default: 100)")
    parser.add_argument("--hwm", type=int, default=10000,
                        help="ZMQ send HWM (default: 10000)")
    args = parser.parse_args()

    if args.size < 8:
        print("ERROR: --size must be >= 8 (sequence number header is 8 bytes)",
              file=sys.stderr)
        sys.exit(1)

    stop = [False]

    def on_signal(sig, frame):
        print("\nShutdown signal received...")
        stop[0] = True

    signal.signal(signal.SIGINT,  on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    ctx = zmq.Context()
    sock = ctx.socket(zmq.PUSH)
    sock.set(zmq.SNDHWM, args.hwm)
    sock.bind(args.endpoint)

    sleep_time = (1.0 / args.rate) if args.rate > 0 else 0
    unlimited = (args.count == 0)

    print(f"Pipeline sender bound to {args.endpoint}")
    print(f"  Message size : {args.size} bytes")
    print(f"  Count        : {'unlimited' if unlimited else args.count}")
    print(f"  Rate         : {'unlimited' if args.rate == 0 else str(args.rate) + ' msg/s'}")
    print("Waiting 1s for downstream connections...")
    time.sleep(1.0)
    print("Sending...\n")

    sent  = 0
    start = time.time()

    try:
        while not stop[0] and (unlimited or sent < args.count):
            seq = sent
            fill_byte = seq & 0xFF
            payload = struct.pack(">Q", seq) + bytes([fill_byte] * (args.size - 8))

            try:
                sock.send(payload, flags=zmq.DONTWAIT)
                sent += 1
            except zmq.Again:
                # Send buffer full — backpressure, yield briefly
                time.sleep(0.001)
                continue

            if sent % 1000 == 0:
                elapsed = time.time() - start
                rate    = sent / elapsed if elapsed > 0 else 0
                print(f"Sent {sent:,} | {rate:,.1f} msg/s")

            if sleep_time > 0:
                time.sleep(sleep_time)

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
    finally:
        sock.close()
        ctx.term()

    elapsed = time.time() - start
    rate    = sent / elapsed if elapsed > 0 else 0
    print(f"\n=== Sender Summary ===")
    print(f"Messages sent : {sent:,}")
    print(f"Duration      : {elapsed:.2f}s")
    print(f"Average rate  : {rate:,.1f} msg/s")
    print(f"======================")


if __name__ == "__main__":
    main()
