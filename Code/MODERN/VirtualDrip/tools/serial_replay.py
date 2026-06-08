#!/usr/bin/env python3
"""Replay Virtual Drip packet files through a serial or pseudo-terminal port.

The tool preserves packet bytes exactly as generated. It is not a VDP emulator:
it parses only enough framing to find packet boundaries and optionally sleep
after FRAME_MARK packets. This is useful with real serial adapters or
socat-created PTYs when the proxy is running on the other side.

Examples:
  python3 tools/serial_replay.py tests/sprite-moving.bin --port /dev/ttyUSB0 --baud 1000000 --frame-delay-ms 16.67 --verbose
  python3 tools/serial_replay.py tests/sprite-moving.bin --port /dev/pts/5 --baud 115200 --loop --read-back
  python3 tools/serial_replay.py tests/sprite-moving.bin --port /dev/pts/5 --baud 115200 --no-rtscts
  python3 tools/serial_replay.py tests/sprite-moving.bin --dry-run --verbose
"""

from __future__ import annotations

import argparse
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


SYNC0 = 0xA5
SYNC1 = 0x5A
FALLBACK_FRAME_MARK_TYPE = 0x08


class ReplayError(Exception):
    """Raised for user-facing replay errors."""


@dataclass(frozen=True)
class Packet:
    """One encoded packet with source offset metadata."""

    index: int
    offset: int
    packet_type: int
    payload_length: int
    data: bytes


@dataclass(frozen=True)
class ReplayStats:
    """Summary for a replay plan or one transmitted loop."""

    packet_count: int
    frame_mark_count: int
    total_bytes: int
    estimated_duration_s: float


def parse_int(text: str) -> int:
    try:
        return int(text, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid integer: {text}") from exc


def parse_non_negative_float(text: str) -> float:
    try:
        value = float(text)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid number: {text}") from exc
    if value < 0:
        raise argparse.ArgumentTypeError(f"value must be non-negative: {text}")
    return value


def discover_frame_mark_type() -> int:
    """Read PACKET_FRAME_MARK from protocol.h when available."""

    source_path = Path(__file__).resolve().parents[1] / "src" / "protocol.h"
    try:
        text = source_path.read_text(encoding="utf-8")
    except OSError:
        return FALLBACK_FRAME_MARK_TYPE

    match = re.search(r"\bPACKET_FRAME_MARK\s*=\s*(0x[0-9a-fA-F]+|\d+)", text)
    if match is None:
        return FALLBACK_FRAME_MARK_TYPE

    return int(match.group(1), 0)


def parse_packets(path: Path) -> list[Packet]:
    """Parse packet boundaries without modifying or recalculating packet bytes."""

    try:
        data = path.read_bytes()
    except OSError as exc:
        raise ReplayError(f"failed to read {path}: {exc}") from exc

    packets: list[Packet] = []
    offset = 0

    while offset < len(data):
        packet_offset = offset
        if data[offset] != SYNC0:
            raise ReplayError(
                f"bad first sync byte at offset {packet_offset}: "
                f"expected 0x{SYNC0:02X}, got 0x{data[offset]:02X}"
            )

        if len(data) - offset < 5:
            raise ReplayError(
                f"truncated packet header at offset {packet_offset}: "
                f"{len(data) - offset} byte(s) remain"
            )

        if data[offset + 1] != SYNC1:
            raise ReplayError(
                f"bad second sync byte at offset {packet_offset + 1}: "
                f"expected 0x{SYNC1:02X}, got 0x{data[offset + 1]:02X}"
            )

        wire_length = data[offset + 2]
        if wire_length < 3:
            raise ReplayError(
                f"invalid LEN at offset {packet_offset + 2}: "
                f"expected at least 3, got {wire_length}"
            )

        total_length = 2 + wire_length
        if len(data) - offset < total_length:
            raise ReplayError(
                f"truncated packet at offset {packet_offset}: "
                f"need {total_length} bytes, have {len(data) - offset}"
            )

        packet_data = data[offset : offset + total_length]
        packets.append(
            Packet(
                index=len(packets) + 1,
                offset=packet_offset,
                packet_type=packet_data[3],
                payload_length=wire_length - 3,
                data=packet_data,
            )
        )
        offset += total_length

    return packets


def summarize_packets(
    packets: Iterable[Packet],
    frame_mark_type: int,
    frame_delay_ms: float,
    inter_packet_delay_ms: float,
    max_frames: int | None,
    baud: int,
) -> ReplayStats:
    """Estimate packet count, frame count, bytes, and paced duration."""

    packet_count = 0
    frame_mark_count = 0
    total_bytes = 0

    for packet in packets:
        packet_count += 1
        total_bytes += len(packet.data)
        if packet.packet_type == frame_mark_type:
            frame_mark_count += 1
            if max_frames is not None and frame_mark_count >= max_frames:
                break

    delay_s = ((frame_mark_count * frame_delay_ms) + (packet_count * inter_packet_delay_ms)) / 1000.0
    wire_s = (total_bytes * 10.0 / baud) if baud > 0 else 0.0
    estimated_duration_s = delay_s + wire_s
    return ReplayStats(packet_count, frame_mark_count, total_bytes, estimated_duration_s)


def packets_for_replay(packets: Iterable[Packet], frame_mark_type: int, max_frames: int | None) -> Iterable[Packet]:
    """Yield packets up to an optional FRAME_MARK count limit."""

    frame_count = 0
    for packet in packets:
        yield packet
        if packet.packet_type == frame_mark_type:
            frame_count += 1
            if max_frames is not None and frame_count >= max_frames:
                return


def open_serial(port: str, baud: int, read_back: bool, rtscts: bool):
    """Open a pyserial endpoint; read-back uses nonblocking reads."""

    try:
        import serial
    except ImportError as exc:
        raise ReplayError(
            "pyserial is required for serial mode. Install it with: "
            "python3 -m pip install pyserial"
        ) from exc

    try:
        timeout = 0 if read_back else 1
        return serial.Serial(
            port=port,
            baudrate=baud,
            timeout=timeout,
            write_timeout=1,
            rtscts=rtscts,
        )
    except serial.SerialException as exc:
        raise ReplayError(f"failed to open serial port {port}: {exc}") from exc


def format_bytes(data: bytes) -> str:
    return " ".join(f"{value:02X}" for value in data)


def read_back_available(serial_port) -> int:
    """Print currently available bytes from the proxy side of the serial link."""

    try:
        waiting = serial_port.in_waiting
        if waiting <= 0:
            return 0
        data = serial_port.read(waiting)
    except Exception as exc:
        raise ReplayError(f"serial read-back failed: {exc}") from exc

    if not data:
        return 0

    print(f"read-back: {len(data)} byte(s): {format_bytes(data)}")
    return len(data)


def sleep_with_read_back(delay_s: float, serial_port, read_back: bool) -> None:
    """Sleep while periodically polling read-back bytes when requested."""

    if delay_s <= 0:
        if read_back and serial_port is not None:
            read_back_available(serial_port)
        return

    if not read_back or serial_port is None:
        time.sleep(delay_s)
        return

    deadline = time.monotonic() + delay_s
    while True:
        read_back_available(serial_port)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(remaining, 0.050))
    read_back_available(serial_port)


def replay_once(
    packets: list[Packet],
    serial_port,
    frame_mark_type: int,
    frame_delay_ms: float,
    inter_packet_delay_ms: float,
    max_frames: int | None,
    baud: int,
    verbose: bool,
    read_back: bool,
) -> ReplayStats:
    """Transmit one pass through the packet list, preserving packet boundaries."""

    frame_count = 0
    packet_count = 0
    total_bytes = 0

    for packet in packets_for_replay(packets, frame_mark_type, max_frames):
        packet_count += 1
        total_bytes += len(packet.data)

        if verbose:
            print(
                f"packet #{packet.index} offset={packet.offset} "
                f"type=0x{packet.packet_type:02X} len={packet.payload_length}"
            )

        if serial_port is not None:
            try:
                serial_port.write(packet.data)
                serial_port.flush()
            except Exception as exc:
                raise ReplayError(f"serial write failed at packet #{packet.index}: {exc}") from exc
            if read_back:
                read_back_available(serial_port)

        # Dry-run reports intended pacing without actually sleeping.
        should_sleep = serial_port is not None

        if inter_packet_delay_ms > 0:
            if verbose:
                action = "delay" if should_sleep else "would delay"
                print(f"  inter-packet {action} {inter_packet_delay_ms:.3f} ms")
            if should_sleep:
                sleep_with_read_back(inter_packet_delay_ms / 1000.0, serial_port, read_back)

        if packet.packet_type == frame_mark_type:
            frame_count += 1
            if verbose:
                action = "delay" if should_sleep else "would delay"
                print(f"  FRAME_MARK #{frame_count}; {action} {frame_delay_ms:.3f} ms")
            if should_sleep and frame_delay_ms > 0:
                sleep_with_read_back(frame_delay_ms / 1000.0, serial_port, read_back)

    delay_s = ((frame_count * frame_delay_ms) + (packet_count * inter_packet_delay_ms)) / 1000.0
    wire_s = (total_bytes * 10.0 / baud) if baud > 0 else 0.0
    estimated_duration_s = delay_s + wire_s
    return ReplayStats(packet_count, frame_count, total_bytes, estimated_duration_s)


def print_summary(prefix: str, stats: ReplayStats) -> None:
    print(
        f"{prefix}: packets={stats.packet_count}, "
        f"frame_marks={stats.frame_mark_count}, "
        f"bytes={stats.total_bytes}, "
        f"estimated_duration={stats.estimated_duration_s:.3f}s"
    )


def build_parser() -> argparse.ArgumentParser:
    discovered_frame_mark_type = discover_frame_mark_type()
    parser = argparse.ArgumentParser(
        description="Replay a Virtual Drip packet file over serial with FRAME_MARK pacing."
    )
    parser.add_argument("packet_file", type=Path, help="input Virtual Drip packet file")
    parser.add_argument("--port", help="serial device, for example /dev/ttyUSB0, /dev/pts/5, or COM3")
    parser.add_argument("--baud", type=int, default=115200, help="serial baud rate, default 115200")
    parser.add_argument("--frame-delay-ms", type=parse_non_negative_float, default=16.67, help="delay after FRAME_MARK packets")
    parser.add_argument(
        "--frame-mark-type",
        type=parse_int,
        default=discovered_frame_mark_type,
        help=(
            "FRAME_MARK packet type. Defaults to the project's discovered value "
            f"0x{discovered_frame_mark_type:02X}; use this option if the protocol changes."
        ),
    )
    parser.add_argument("--dry-run", action="store_true", help="parse and report packets without opening serial")
    parser.add_argument("--loop", action="store_true", help="continuously replay the file")
    parser.add_argument("--verbose", action="store_true", help="print packet and delay details")
    parser.add_argument("--read-back", action="store_true", help="print bytes received from the serial port while replaying")
    parser.add_argument(
        "--no-rtscts",
        action="store_false",
        dest="rtscts",
        help="disable hardware RTS/CTS flow control for adapters or PTYs that cannot support it",
    )
    parser.add_argument("--start-delay-ms", type=parse_non_negative_float, default=0.0, help="delay after opening serial before streaming")
    parser.add_argument("--inter-packet-delay-ms", type=parse_non_negative_float, default=0.0, help="debug delay after each packet")
    parser.add_argument("--max-frames", type=int, help="stop after N FRAME_MARK packets")
    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.frame_mark_type < 0 or args.frame_mark_type > 0xFF:
        parser.error("--frame-mark-type must be in range 0..255")
    if args.baud <= 0:
        parser.error("--baud must be positive")
    if args.max_frames is not None and args.max_frames <= 0:
        parser.error("--max-frames must be positive")
    if not args.dry_run and not args.port:
        parser.error("--port is required unless --dry-run is used")

    try:
        packets = parse_packets(args.packet_file)
        plan = summarize_packets(
            packets,
            args.frame_mark_type,
            args.frame_delay_ms,
            args.inter_packet_delay_ms,
            args.max_frames,
            args.baud,
        )
        print_summary("parsed", plan)

        if args.dry_run:
            replay_once(
                packets,
                None,
                args.frame_mark_type,
                args.frame_delay_ms,
                args.inter_packet_delay_ms,
                args.max_frames,
                args.baud,
                args.verbose,
                False,
            )
            return 0

        serial_port = open_serial(args.port, args.baud, args.read_back, args.rtscts)
        with serial_port:
            if args.start_delay_ms > 0:
                if args.verbose:
                    print(f"start delay {args.start_delay_ms:.3f} ms")
                sleep_with_read_back(args.start_delay_ms / 1000.0, serial_port, args.read_back)

            loop_index = 0
            while True:
                loop_index += 1
                stats = replay_once(
                    packets,
                    serial_port,
                    args.frame_mark_type,
                    args.frame_delay_ms,
                    args.inter_packet_delay_ms,
                    args.max_frames,
                    args.baud,
                    args.verbose,
                    args.read_back,
                )
                if args.read_back:
                    read_back_available(serial_port)
                print_summary(f"sent loop {loop_index}", stats)
                if not args.loop:
                    break

        return 0
    except ReplayError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
