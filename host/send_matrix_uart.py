#!/usr/bin/env python3
"""Send one 4x4 dense matrix to the DE10-Lite UART wrapper.

The FPGA-side protocol is implemented by rtl_board/matrix_uart_controller.sv:

Host -> FPGA:
    0xAA + 16 signed int16 values, row-major, little-endian

FPGA -> Host:
    0x55 + 16 signed int64 values, row-major, little-endian
"""

from __future__ import annotations

import argparse
import ast
import re
import struct
import sys
import time
from pathlib import Path
from typing import Any, Iterable, Sequence

REQUEST_START_BYTE = 0xAA
RESPONSE_START_BYTE = 0x55
MATRIX_ROWS = 4
MATRIX_COLS = 4
INPUT_MIN = -(2**15)
INPUT_MAX = (2**15) - 1

Matrix = list[list[int]]

DEMO_MATRIX: Matrix = [
    [1, 2, 3, 4],
    [5, 6, 7, 8],
    [9, 10, 11, 12],
    [13, 14, 15, 16],
]


def format_matrix(matrix: Iterable[Iterable[int]]) -> str:
    """Return a compact aligned matrix string."""

    return "\n".join(" ".join(f"{value:>8}" for value in row) for row in matrix)


def _coerce_int16(value: Any) -> int:
    if isinstance(value, bool):
        raise ValueError("matrix entries must be integers, not booleans")

    if isinstance(value, int):
        number = value
    elif isinstance(value, float) and value.is_integer():
        number = int(value)
    elif isinstance(value, str):
        number = int(value.strip(), 0)
    else:
        raise ValueError(f"matrix entry {value!r} is not an integer")

    if not INPUT_MIN <= number <= INPUT_MAX:
        raise ValueError(f"matrix entry {number} is outside signed int16 range")

    return number


def normalize_matrix(value: Any) -> Matrix:
    """Validate and normalize an object into a 4x4 int16 matrix."""

    if isinstance(value, dict):
        for key in (
            "dense_b",
            "dense_B",
            "dense_input",
            "input",
            "matrix",
            "B",
            "b",
            "pruned_weights",
            "Pruned weights",
        ):
            if key in value:
                value = value[key]
                break
        else:
            raise ValueError(
                "matrix dictionary must contain a matrix-like key such as "
                "'dense_input', 'matrix', 'B', or 'pruned_weights'"
            )

    if not isinstance(value, Sequence) or isinstance(value, (str, bytes, bytearray)):
        raise ValueError("matrix must be a sequence of rows")

    rows = list(value)
    if len(rows) != MATRIX_ROWS:
        raise ValueError(f"matrix must have exactly {MATRIX_ROWS} rows")

    matrix: Matrix = []
    for row_idx, row in enumerate(rows):
        if not isinstance(row, Sequence) or isinstance(row, (str, bytes, bytearray)):
            raise ValueError(f"matrix row {row_idx} must be a sequence")
        row_values = list(row)
        if len(row_values) != MATRIX_COLS:
            raise ValueError(f"matrix row {row_idx} must have exactly {MATRIX_COLS} columns")
        matrix.append([_coerce_int16(entry) for entry in row_values])

    return matrix


def _parse_literal_matrix(text: str) -> Matrix | None:
    stripped = text.strip()
    if not stripped:
        return None

    try:
        return normalize_matrix(ast.literal_eval(stripped))
    except (SyntaxError, ValueError):
        return None


def _parse_numeric_row(line: str) -> list[int] | None:
    stripped = line.strip()
    if not stripped or re.search(r"[A-Za-z:]", stripped):
        return None

    numbers = re.findall(r"[-+]?(?:0x[0-9A-Fa-f]+|\d+)", stripped)
    if not numbers:
        return None

    remainder = re.sub(r"[-+]?(?:0x[0-9A-Fa-f]+|\d+)", "", stripped)
    if re.search(r"[^\s,\[\]\(\)]", remainder):
        return None

    return [_coerce_int16(number) for number in numbers]


def _label_matches(line: str, label: str) -> bool:
    normalized_line = line.strip().lower()
    normalized_label = label.strip().lower()

    return (
        normalized_line == normalized_label
        or normalized_line == f"{normalized_label}:"
        or normalized_line.startswith(f"{normalized_label}:")
    )


def _parse_labeled_block(text: str, labels: Sequence[str]) -> Matrix | None:
    lines = text.splitlines()

    for label in labels:
        for line_index, line in enumerate(lines):
            if not _label_matches(line, label):
                continue

            rows: list[list[int]] = []
            for candidate in lines[line_index + 1 :]:
                row = _parse_numeric_row(candidate)
                if row is None:
                    if rows:
                        break
                    continue
                rows.append(row)
                if len(rows) == MATRIX_ROWS:
                    return normalize_matrix(rows)

    return None


def _parse_first_matrix_block(text: str) -> Matrix | None:
    rows: list[list[int]] = []

    for line in text.splitlines():
        row = _parse_numeric_row(line)
        if row is not None and len(row) == MATRIX_COLS:
            rows.append(row)
            if len(rows) == MATRIX_ROWS:
                return normalize_matrix(rows)
        elif rows:
            rows = []

    return None


def parse_matrix_text(text: str, label: str | None = None) -> Matrix:
    """Parse a 4x4 matrix from literal, raw-row, or prune-style text."""

    literal_matrix = _parse_literal_matrix(text)
    if literal_matrix is not None:
        return literal_matrix

    labels = [label] if label else [
        "Dense input B",
        "Dense input",
        "Input B",
        "Matrix B",
        "Matrix",
        "Pruned weights",
        "Pruned matrix",
    ]
    labeled_matrix = _parse_labeled_block(text, labels)
    if labeled_matrix is not None:
        return labeled_matrix

    block_matrix = _parse_first_matrix_block(text)
    if block_matrix is not None:
        return block_matrix

    raise ValueError(
        "could not find a 4x4 matrix. Use --matrix '[[1,2,3,4],...]', "
        "--file matrix.txt, or pipe four rows of numbers into stdin."
    )


def flatten_row_major(matrix: Sequence[Sequence[int]]) -> list[int]:
    return [matrix[row][col] for row in range(MATRIX_ROWS) for col in range(MATRIX_COLS)]


def build_request_packet(matrix: Sequence[Sequence[int]]) -> bytes:
    normalized = normalize_matrix(matrix)
    payload = struct.pack("<16h", *flatten_row_major(normalized))
    return bytes([REQUEST_START_BYTE]) + payload


def decode_response_packet(packet: bytes) -> Matrix:
    expected_len = 1 + (MATRIX_ROWS * MATRIX_COLS * 8)
    if len(packet) != expected_len:
        raise ValueError(f"response must be {expected_len} bytes, got {len(packet)}")
    if packet[0] != RESPONSE_START_BYTE:
        raise ValueError(f"expected response start byte 0x55, got 0x{packet[0]:02X}")

    values = struct.unpack("<16q", packet[1:])
    return [
        list(values[row * MATRIX_COLS : (row + 1) * MATRIX_COLS])
        for row in range(MATRIX_ROWS)
    ]


def read_exact(serial_port: Any, byte_count: int) -> bytes:
    chunks: list[bytes] = []
    remaining = byte_count

    while remaining:
        chunk = serial_port.read(remaining)
        if not chunk:
            received = byte_count - remaining
            raise TimeoutError(f"timed out after receiving {received}/{byte_count} bytes")
        chunks.append(chunk)
        remaining -= len(chunk)

    return b"".join(chunks)


def transact(port: str, baud: int, timeout: float, matrix: Sequence[Sequence[int]]) -> Matrix:
    try:
        import serial
    except ImportError as exc:
        raise SystemExit("pyserial is required: python3 -m pip install pyserial") from exc

    request = build_request_packet(matrix)
    response_len = 1 + (MATRIX_ROWS * MATRIX_COLS * 8)

    with serial.Serial(port, baudrate=baud, timeout=timeout, write_timeout=timeout) as ser:
        time.sleep(0.1)
        ser.reset_input_buffer()
        ser.write(request)
        ser.flush()
        return decode_response_packet(read_exact(ser, response_len))


def list_ports() -> None:
    try:
        from serial.tools import list_ports as serial_list_ports
    except ImportError as exc:
        raise SystemExit("pyserial is required: python3 -m pip install pyserial") from exc

    ports = list(serial_list_ports.comports())
    if not ports:
        print("No serial ports found.")
        return

    for port in ports:
        print(f"{port.device}\t{port.description}")


def _read_source_text(args: argparse.Namespace) -> str | None:
    if args.demo:
        return None
    if args.matrix is not None:
        return args.matrix
    if args.file is not None:
        return args.file.read_text(encoding="utf-8")
    if not sys.stdin.isatty():
        return sys.stdin.read()
    return None


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send a 4x4 int16 matrix to the DE10-Lite sparse matmul UART top."
    )
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--matrix", help="4x4 matrix as a Python/JSON literal")
    source.add_argument("--file", type=Path, help="file containing a 4x4 matrix or prune-style output")
    source.add_argument("--demo", action="store_true", help="send the built-in [[1..16]] demo matrix")

    parser.add_argument("--label", help="label to parse from a text file, for example 'Pruned weights'")
    parser.add_argument("--port", help="serial port, such as COM3 or /dev/tty.usbserial-XXXX")
    parser.add_argument("--baud", type=int, default=115200, help="UART baud rate")
    parser.add_argument("--timeout", type=float, default=2.0, help="serial read/write timeout in seconds")
    parser.add_argument("--dry-run", action="store_true", help="parse and encode without opening serial")
    parser.add_argument("--list-ports", action="store_true", help="print available serial ports and exit")

    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)

    if args.list_ports:
        list_ports()
        return 0

    source_text = _read_source_text(args)
    if args.demo:
        matrix = DEMO_MATRIX
    elif source_text is not None:
        matrix = parse_matrix_text(source_text, label=args.label)
    else:
        raise SystemExit(
            "provide --matrix, --file, --demo, or pipe matrix text into stdin"
        )

    request = build_request_packet(matrix)
    print("Input matrix B:")
    print(format_matrix(matrix))
    print(f"\nRequest packet: {len(request)} bytes, starts with 0x{request[0]:02X}")

    if args.dry_run:
        print(request.hex(" "))
        return 0

    if not args.port:
        raise SystemExit("provide --port, or use --dry-run to only build the packet")

    result = transact(args.port, args.baud, args.timeout, matrix)
    print("\nOutput matrix C:")
    print(format_matrix(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
