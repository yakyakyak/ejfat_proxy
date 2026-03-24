#!/usr/bin/env python3
"""
plot_fill.py — ASCII time-series plotter for ejfat_zmq_proxy fill levels.

Parses proxy log files produced by BackpressureMonitor and renders the
EventRingBuffer fill level (%) as an ASCII bar chart over time.

Queue monitoring points:

  E2SAR UDP → receiverThread ─push()→ [EventRingBuffer] ─pop()→ ZmqSender → ZMQ PUSH
                                             ↑
                                   BackpressureMonitor (samples every period_ms)

B2B mode log:  Monitor #N: fill=X%
LB mode log:   sendState #N: fill=X%, control=Y, ready=Z

Usage:
  python3 scripts/plot_fill.py runs/local_b2b_*/test3_proxy.log
  python3 scripts/plot_fill.py --run-dir runs/local_b2b_20260323_121412/
  python3 scripts/plot_fill.py --width 120 --height 30 --threshold 30 test2.log
"""

import re
import sys
import os
import glob
import argparse
import math
from dataclasses import dataclass, field
from typing import List, Optional

# ---------------------------------------------------------------------------
# Unicode vertical block characters (1/8 sub-row resolution)
# Index 0 = empty space, 1-7 = partial blocks, 8 = full block
# ---------------------------------------------------------------------------
BLOCKS = [' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█']


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class FillSample:
    sample_num: int             # The #N counter from the log
    time_s: float               # Derived: N * period_ms / 1000 (adjusted to 0-origin)
    fill_pct: float             # 0.0 – 100.0
    control: Optional[float] = None   # LB mode: PID control output
    ready: Optional[int] = None       # LB mode: 1=ready (fill<threshold), 0=not ready


@dataclass
class ProxyStats:
    events_received: int = 0
    events_dropped: int = 0
    zmq_sends: int = 0
    zmq_blocked: int = 0
    zmq_blocked_pct: float = 0.0
    buffer_capacity: int = 0


@dataclass
class LogData:
    filename: str
    mode: str = "b2b"                  # "b2b" or "lb"
    period_ms: int = 100               # From "period=Nms" startup line
    samples: List[FillSample] = field(default_factory=list)
    final_stats: Optional[ProxyStats] = None
    event_rate: Optional[float] = None


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

# Fill sample patterns
_RE_B2B    = re.compile(r'Monitor #(\d+): fill=([\d.]+)%')
_RE_LB     = re.compile(r'sendState #(\d+): fill=([\d.]+)%, control=([\d.]+), ready=(\d)')

# Startup line: period in ms
_RE_PERIOD = re.compile(r'period=(\d+)ms')

# Periodic stats block fields
_RE_RECV      = re.compile(r'Events received:\s*(\d+)')
_RE_DROP      = re.compile(r'Events dropped:\s*(\d+)')
_RE_ZMQ_BLK  = re.compile(r'ZMQ blocked:\s*(\d+) \(([\d.]+)%\)')
_RE_ZMQ_SND  = re.compile(r'ZMQ sends:\s*(\d+)')
_RE_BUFCAP   = re.compile(r'Buffer size:\s*\d+ / (\d+)')

# Timing diagnostics (shutdown)
_RE_EVT_RATE = re.compile(r'Event rate\s*:\s*([\d.]+)')


def parse_log(path: str) -> LogData:
    """Parse a proxy log file and return structured data."""
    data = LogData(filename=os.path.basename(path))

    try:
        with open(path, 'r', errors='replace') as f:
            lines = f.readlines()
    except IOError as e:
        print(f"  Error reading {path}: {e}", file=sys.stderr)
        return data

    in_stats = False
    current_stats: Optional[ProxyStats] = None

    for line in lines:
        # --- Period detection (must come before fill sample check) ---
        m = _RE_PERIOD.search(line)
        if m and 'Backpressure monitor started' in line:
            data.period_ms = int(m.group(1))
            continue

        # --- Stats block markers ---
        if '=== Proxy Statistics ===' in line:
            in_stats = True
            current_stats = ProxyStats()
            continue

        if in_stats and '========================' in line:
            in_stats = False
            if current_stats is not None:
                data.final_stats = current_stats  # last block wins (= Final statistics)
            current_stats = None
            continue

        # --- Stats block fields ---
        if in_stats and current_stats is not None:
            m = _RE_RECV.search(line)
            if m:
                current_stats.events_received = int(m.group(1))
                continue
            m = _RE_DROP.search(line)
            if m:
                current_stats.events_dropped = int(m.group(1))
                continue
            m = _RE_ZMQ_BLK.search(line)
            if m:
                current_stats.zmq_blocked     = int(m.group(1))
                current_stats.zmq_blocked_pct = float(m.group(2))
                continue
            m = _RE_ZMQ_SND.search(line)
            if m:
                current_stats.zmq_sends = int(m.group(1))
                continue
            m = _RE_BUFCAP.search(line)
            if m:
                current_stats.buffer_capacity = int(m.group(1))
                continue
            continue  # stay in stats block, don't try fill patterns

        # --- Event rate from timing diagnostics (shutdown) ---
        m = _RE_EVT_RATE.search(line)
        if m and 'Event rate' in line:
            data.event_rate = float(m.group(1))
            continue

        # --- Fill samples: try LB first (superset), then B2B ---
        # Garbled lines (e.g., "Monitor #All ...") naturally fail both regexes.
        m = _RE_LB.search(line)
        if m:
            data.mode = "lb"
            snum = int(m.group(1))
            data.samples.append(FillSample(
                sample_num=snum,
                time_s=snum * data.period_ms / 1000.0,
                fill_pct=float(m.group(2)),
                control=float(m.group(3)),
                ready=int(m.group(4)),
            ))
            continue

        m = _RE_B2B.search(line)
        if m:
            snum = int(m.group(1))
            data.samples.append(FillSample(
                sample_num=snum,
                time_s=snum * data.period_ms / 1000.0,
                fill_pct=float(m.group(2)),
            ))
            continue

    # Adjust times to be 0-origin (relative to first sample)
    if data.samples:
        t0 = data.samples[0].time_s
        for s in data.samples:
            s.time_s -= t0

    return data


# ---------------------------------------------------------------------------
# Chart rendering helpers
# ---------------------------------------------------------------------------

def _bin_samples(samples: List, n_cols: int, attr: str = 'fill_pct') -> List[Optional[float]]:
    """Bin samples into n_cols time buckets using max value within each bin.

    Max (not mean) is used because peak fill levels matter most for backpressure
    diagnosis — a mean would visually flatten the saturation events.
    """
    if not samples:
        return [None] * n_cols

    t_min = samples[0].time_s
    t_max = samples[-1].time_s
    duration = t_max - t_min or 1.0

    bins: List[List[float]] = [[] for _ in range(n_cols)]
    for s in samples:
        col = int((s.time_s - t_min) / duration * (n_cols - 1))
        col = max(0, min(n_cols - 1, col))
        val = getattr(s, attr)
        if val is not None:
            bins[col].append(val)

    return [max(b) if b else None for b in bins]


def _nice_tick_interval(duration_s: float, plot_width: int) -> float:
    """Choose a tick interval (seconds) that keeps labels readable."""
    candidates = [1, 2, 5, 10, 15, 20, 30, 60, 120, 300, 600]
    max_ticks = max(2, plot_width // 7)
    for c in candidates:
        if duration_s / c <= max_ticks:
            return float(c)
    return float(candidates[-1])


# ---------------------------------------------------------------------------
# Fill chart
# ---------------------------------------------------------------------------

Y_LABEL_W = 5  # width of " 100" y-axis label (4 chars + '│')


def render_fill_chart(
    samples: List[FillSample],
    width: int = 80,
    height: int = 20,
    threshold: float = 50.0,
    title: str = "",
) -> List[str]:
    """Render ring buffer fill level as an ASCII bar chart.

    Returns a list of strings (one per output line) ready to print.

    Each column represents a time window; the bar height encodes the
    maximum fill level within that window. Unicode block characters
    (▁▂▃▄▅▆▇█) provide 1/8-row sub-resolution.
    """
    if not samples:
        return [f"  ── {title}: no fill samples ──"]

    plot_w = max(width - Y_LABEL_W - 1, 10)

    # Bin into columns
    col_vals = _bin_samples(samples, plot_w)

    # Build 2D character grid: grid[row][col], row 0 = top (100%), row height-1 = bottom (0%)
    grid = [[' '] * plot_w for _ in range(height)]

    for col, val in enumerate(col_vals):
        if val is None:
            continue
        bar_f = val / 100.0 * height        # fractional rows to fill
        full  = int(bar_f)
        frac  = bar_f - full
        frac_idx = int(frac * 8)            # 0-7, index into BLOCKS[1..8]

        # Full rows from bottom upward
        for r in range(min(full, height)):
            grid[height - 1 - r][col] = '█'

        # Partial top row (only if there is a fractional part and room)
        if full < height and frac_idx > 0:
            grid[height - 1 - full][col] = BLOCKS[frac_idx]

    # Threshold dashed line (where bar doesn't reach, draw '─')
    thresh_row = height - 1 - int(threshold / 100.0 * height)
    thresh_row = max(0, min(height - 1, thresh_row))
    for col in range(plot_w):
        if grid[thresh_row][col] == ' ':
            grid[thresh_row][col] = '─'

    # --- Assemble output lines ---
    lines = []

    # Title banner
    if title:
        banner = f" {title} "
        pad = '═' * max(0, width - len(banner) - 2)
        lines.append(f"{'═' * 2}{banner}{pad}")
    lines.append("  Fill Level (%)")

    # Chart rows, top to bottom
    for row in range(height):
        # Y-axis label: linear mapping row→percent
        if height > 1:
            pct = (height - 1 - row) / (height - 1) * 100
        else:
            pct = 100.0
        label = f"{pct:4.0f}│"
        row_str = ''.join(grid[row])

        # Annotate threshold row on the right
        suffix = f" ── {threshold:.0f}%" if row == thresh_row else ""
        lines.append(label + row_str + suffix)

    # X-axis
    lines.append(f"    └{'─' * plot_w}")

    # Tick marks and labels
    t_min = samples[0].time_s   # always 0.0 after parse_log adjustment
    t_max = samples[-1].time_s
    duration = t_max - t_min or 1.0
    tick_iv = _nice_tick_interval(duration, plot_w)

    tick_row  = [' '] * plot_w
    label_row = [' '] * plot_w

    t = 0.0
    while t <= duration + tick_iv * 0.01:
        col = int((t - t_min) / duration * (plot_w - 1))
        col = max(0, min(plot_w - 1, col))
        tick_row[col] = '┬'
        lbl = f"{t:.0f}"
        for i, ch in enumerate(lbl):
            if col + i < plot_w:
                label_row[col + i] = ch
        t += tick_iv

    lines.append("    " + ''.join(tick_row))
    lines.append("    " + ''.join(label_row))
    lines.append(f"    {'Time (s)':^{plot_w}}")

    return lines


# ---------------------------------------------------------------------------
# Control signal chart (LB mode only)
# ---------------------------------------------------------------------------

def render_control_chart(
    samples: List[FillSample],
    width: int = 80,
    height: int = 10,
) -> List[str]:
    """Render PID control signal (0.0–1.0) for LB mode logs.

    Annotates columns where ready=0 with '!' below the x-axis.
    """
    ctrl_samples = [s for s in samples if s.control is not None]
    if not ctrl_samples:
        return []

    plot_w = max(width - Y_LABEL_W - 1, 10)
    col_ctrl  = _bin_samples(ctrl_samples, plot_w, attr='control')
    col_ready = _bin_samples(ctrl_samples, plot_w, attr='ready')

    ctrl_max = max((v for v in col_ctrl if v is not None), default=1.0) or 1.0

    grid = [[' '] * plot_w for _ in range(height)]

    for col, val in enumerate(col_ctrl):
        if val is None:
            continue
        bar_f    = val / ctrl_max * height
        full     = int(bar_f)
        frac_idx = int((bar_f - full) * 8)
        for r in range(min(full, height)):
            grid[height - 1 - r][col] = '█'
        if full < height and frac_idx > 0:
            grid[height - 1 - full][col] = BLOCKS[frac_idx]

    # Ready annotation row below chart
    ready_row = ['─'] * plot_w
    for col, val in enumerate(col_ready):
        if val is not None and val == 0:
            ready_row[col] = '!'

    lines = ["  Control Signal (PID output, 0.0–1.0)"]
    for row in range(height):
        if height > 1:
            fval = (height - 1 - row) / (height - 1) * ctrl_max
        else:
            fval = ctrl_max
        label = f"{fval:4.2f}│"
        lines.append(label + ''.join(grid[row]))

    lines.append(f"    └{''.join(ready_row)}")
    lines.append(f"    {'! = not ready (fill > threshold)':^{plot_w}}")
    return lines


# ---------------------------------------------------------------------------
# Summary stats
# ---------------------------------------------------------------------------

def print_summary(data: LogData, threshold: float) -> None:
    """Print one-line summary statistics below the chart."""
    if not data.samples:
        return

    fills = [s.fill_pct for s in data.samples]
    max_fill  = max(fills)
    mean_fill = sum(fills) / len(fills)

    # Estimate how much real time each logged sample represents.
    # The monitor logs every log_interval ticks of period_ms each.
    # We infer log_interval from consecutive sample number gaps.
    if len(data.samples) >= 2:
        gaps = [
            data.samples[i+1].sample_num - data.samples[i].sample_num
            for i in range(min(10, len(data.samples) - 1))
        ]
        log_interval = round(sum(gaps) / len(gaps))
    else:
        log_interval = 1
    sample_dur_s = data.period_ms * log_interval / 1000.0

    above_count = sum(1 for f in fills if f >= threshold)
    time_above  = above_count * sample_dur_s

    parts = [
        f"Max: {max_fill:.1f}%",
        f"Mean: {mean_fill:.1f}%",
        f"≥{threshold:.0f}%: {time_above:.1f}s ({above_count} samples)",
    ]

    if data.final_stats:
        s = data.final_stats
        parts.append(f"Recv: {s.events_received}  Drop: {s.events_dropped}")
        if s.zmq_blocked_pct > 0:
            parts.append(f"ZMQ blocked: {s.zmq_blocked_pct:.1f}%")

    if data.event_rate is not None:
        parts.append(f"Rate: {data.event_rate:.1f} evt/s")

    parts.append(f"period={data.period_ms}ms")

    print("  " + "  │  ".join(parts))


# ---------------------------------------------------------------------------
# File discovery
# ---------------------------------------------------------------------------

def find_logs_in_rundir(run_dir: str) -> List[str]:
    """Find test*_proxy.log files in a run directory, sorted by name."""
    pattern = os.path.join(run_dir, 'test*_proxy.log')
    return sorted(glob.glob(pattern))


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='ASCII time-series plotter for ejfat_zmq_proxy fill levels.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
examples:
  %(prog)s runs/local_b2b_20260323_121412/test3_proxy.log
  %(prog)s --run-dir runs/local_b2b_20260323_121412/
  %(prog)s --width 120 --height 30 runs/local_b2b_*/test2_proxy.log
  %(prog)s --threshold 30 test2_proxy.log test3_proxy.log
""",
    )
    parser.add_argument(
        'files', nargs='*',
        help='Proxy log files to plot',
    )
    parser.add_argument(
        '--run-dir', metavar='DIR',
        help='Auto-find test*_proxy.log files in DIR',
    )
    parser.add_argument(
        '--width', type=int, default=80,
        help='Chart width in columns (default: 80)',
    )
    parser.add_argument(
        '--height', type=int, default=20,
        help='Chart height in rows (default: 20)',
    )
    parser.add_argument(
        '--threshold', type=float, default=50.0,
        help='Fill %% threshold to mark with dashed line (default: 50)',
    )
    parser.add_argument(
        '--no-control', action='store_true',
        help='Suppress PID control signal chart (LB mode)',
    )
    parser.add_argument(
        '--period-ms', type=int, default=None,
        help='Override monitoring period in ms (auto-detected from log)',
    )
    args = parser.parse_args()

    # Collect files
    files: List[str] = list(args.files)
    if args.run_dir:
        found = find_logs_in_rundir(args.run_dir)
        if not found:
            print(f"No test*_proxy.log files found in: {args.run_dir}", file=sys.stderr)
            sys.exit(1)
        files = found + files

    if not files:
        parser.print_help()
        sys.exit(0)

    for path in files:
        if not os.path.exists(path):
            print(f"File not found: {path}", file=sys.stderr)
            continue

        data = parse_log(path)

        # Period override
        if args.period_ms is not None:
            data.period_ms = args.period_ms
            if data.samples:
                t0 = data.samples[0].sample_num * data.period_ms / 1000.0
                for s in data.samples:
                    s.time_s = s.sample_num * data.period_ms / 1000.0 - t0

        if not data.samples:
            print(f"\n  ── {data.filename}: no fill samples found ──\n")
            continue

        # Fill chart
        print()
        chart = render_fill_chart(
            data.samples,
            width=args.width,
            height=args.height,
            threshold=args.threshold,
            title=data.filename,
        )
        for line in chart:
            print(line)

        # Control signal chart (LB mode only)
        if data.mode == "lb" and not args.no_control:
            ctrl_lines = render_control_chart(
                data.samples,
                width=args.width,
                height=max(6, args.height // 3),
            )
            if ctrl_lines:
                print()
                for line in ctrl_lines:
                    print(line)

        print()
        print_summary(data, args.threshold)
        print()


if __name__ == '__main__':
    main()
