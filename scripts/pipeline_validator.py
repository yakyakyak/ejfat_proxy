#!/usr/bin/env python3
"""
Pipeline test validator: ZMQ PULL with sequence number and payload validation.

Expects messages in the format produced by pipeline_sender.py:
  bytes 0-7 : uint64 big-endian sequence number
  bytes 8+  : fill pattern where each byte == (seq_num & 0xFF)

Validates:
  - Sequence continuity (gaps, duplicates, reordering)
  - Payload fill pattern correctness

Exit codes:
  0 - All messages received and validated successfully
  1 - Validation errors (gaps, payload corruption, etc.)
  2 - Timeout before expected count reached

Used as N4 in the pipeline test.
"""

import struct
import zmq
import time
import argparse
import signal
import sys


def validate_payload(data: bytes, seq: int) -> bool:
    if len(data) < 8:
        return False
    fill_byte = seq & 0xFF
    for b in data[8:]:
        if b != fill_byte:
            return False
    return True


def main():
    parser = argparse.ArgumentParser(description="Pipeline test ZMQ PULL validator")
    parser.add_argument("--endpoint", "-e", default="tcp://localhost:5555",
                        help="ZMQ PULL endpoint to connect to (default: tcp://localhost:5555)")
    parser.add_argument("--expected", "-n", type=int, default=1000,
                        help="Number of messages to expect before exiting (0=run until signal, default: 1000)")
    parser.add_argument("--timeout", "-t", type=int, default=30,
                        help="Seconds of silence before giving up (default: 30)")
    parser.add_argument("--no-payload-check", action="store_true",
                        help="Skip per-byte payload validation (faster)")
    args = parser.parse_args()

    stop = [False]

    def on_signal(sig, frame):
        print("\nShutdown signal received...")
        stop[0] = True

    signal.signal(signal.SIGINT,  on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    ctx  = zmq.Context()
    sock = ctx.socket(zmq.PULL)
    sock.set(zmq.RCVHWM, 10000)
    sock.connect(args.endpoint)

    unlimited = (args.expected == 0)

    print(f"Pipeline validator connected to {args.endpoint}")
    print(f"  Expecting    : {'unlimited' if unlimited else args.expected} messages")
    print(f"  Timeout      : {args.timeout}s of silence")
    print(f"  Payload check: {'disabled' if args.no_payload_check else 'enabled'}")
    print("Waiting for messages...\n")

    received        = 0
    payload_errors  = 0
    gaps            = 0
    duplicates      = 0
    next_expected   = None
    last_recv_time  = time.time()
    start_time      = time.time()

    exit_code = 0

    try:
        while not stop[0] and (unlimited or received < args.expected):
            try:
                msg = sock.recv(flags=zmq.NOBLOCK)
            except zmq.Again:
                if time.time() - last_recv_time > args.timeout:
                    print(f"TIMEOUT: No message for {args.timeout}s, stopping.")
                    if not unlimited and received < args.expected:
                        exit_code = 2
                    break
                time.sleep(0.001)
                continue

            last_recv_time = time.time()

            if len(msg) < 8:
                print(f"ERROR: Message too short ({len(msg)} bytes), skipping", file=sys.stderr)
                payload_errors += 1
                continue

            seq = struct.unpack(">Q", msg[:8])[0]
            received += 1

            # Sequence check
            if next_expected is None:
                next_expected = seq + 1
            elif seq == next_expected:
                next_expected += 1
            elif seq < next_expected:
                duplicates += 1
                print(f"DUPLICATE: seq={seq} (expected {next_expected})")
                continue
            else:
                gap = seq - next_expected
                gaps += gap
                print(f"GAP: seq={seq} expected={next_expected} (missing {gap} messages)")
                next_expected = seq + 1

            # Payload check
            if not args.no_payload_check:
                if not validate_payload(msg, seq):
                    payload_errors += 1
                    if payload_errors <= 10:
                        print(f"PAYLOAD ERROR: seq={seq}")

            if received % 1000 == 0:
                elapsed = time.time() - start_time
                rate    = received / elapsed if elapsed > 0 else 0
                print(f"Received {received:,} | {rate:,.1f} msg/s | "
                      f"gaps={gaps} dup={duplicates} err={payload_errors}")

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        exit_code = 1
    finally:
        sock.close()
        ctx.term()

    elapsed = time.time() - start_time
    rate    = received / elapsed if elapsed > 0 else 0

    ok = (gaps == 0 and duplicates == 0 and payload_errors == 0
          and (unlimited or received >= args.expected))

    print(f"\n=== Validation Summary ===")
    print(f"Messages received : {received:,}")
    print(f"Expected          : {'unlimited' if unlimited else args.expected}")
    print(f"Duration          : {elapsed:.2f}s")
    print(f"Average rate      : {rate:,.1f} msg/s")
    print(f"Gaps (missing)    : {gaps}")
    print(f"Duplicates        : {duplicates}")
    print(f"Payload errors    : {payload_errors}")
    print(f"Result            : {'PASS' if ok else 'FAIL'}")
    print(f"==========================")

    if not ok and exit_code == 0:
        exit_code = 1

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
