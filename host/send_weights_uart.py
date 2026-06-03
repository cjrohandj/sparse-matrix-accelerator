#!/usr/bin/env python3
"""Configure the DE10-Lite dense A weights over UART.

The expected FPGA packet is implemented by rtl_board/matrix_uart_controller.sv:

Host -> FPGA:
    0xA0
    M uint8, inferred from the dense A row count
    K uint8, inferred from the dense A column count
    N uint8, provided by --n
    M * (K/4) dense row/group records, each encoded as:
        weight0 int16 little-endian
        weight1 int16 little-endian
        weight2 int16 little-endian
        weight3 int16 little-endian

FPGA -> Host:
    0x5A
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

CONFIG_START_BYTE = 0xA0
CONFIG_ACK_BYTE = 0x5A
GROUP_WIDTH = 4
INPUT_MIN = -(2**15)
INPUT_MAX = (2**15) - 1

Matrix = list[list[int]]


def format_matrix(matrix: Iterable[Iterable[int]]) -> str:
    return "\n".join(" ".join(f"{value:>8}" for value in row) for row in matrix)


def _coerce_int16(value: Any) -> int:
    if isinstance(value, bool):
        raise ValueError("weights must be integers, not booleans")
    if isinstance(value, int):
        number = value
    elif isinstance(value, float) and value.is_integer():
        number = int(value)
    elif isinstance(value, str):
        number = int(value.strip(), 0)
    else:
        raise ValueError(f"weight {value!r} is not an integer")

    if not INPUT_MIN <= number <= INPUT_MAX:
        raise ValueError(f"weight {number} is outside signed int16 range")
    return number


def normalize_weight_matrix(value: Any) -> Matrix:
    if isinstance(value, dict):
        for key in (
            "dense_a",
            "dense_A",
            "weight_matrix",
            "weights",
            "matrix",
            "A",
            "a",
            "dense_weights",
            "pruned_weights",
            "Pruned weights",
        ):
            if key in value:
                value = value[key]
                break
        else:
            raise ValueError("weight matrix dictionary must contain a matrix-like key such as 'dense_a' or 'matrix'")

    if not isinstance(value, Sequence) or isinstance(value, (str, bytes, bytearray)):
        raise ValueError("weight matrix must be a sequence of rows")

    rows = list(value)
    if not rows:
        raise ValueError("weight matrix must contain at least one row")
    if len(rows) > 255:
        raise ValueError("weight matrix cannot contain more than 255 rows")
    if not isinstance(rows[0], Sequence) or isinstance(rows[0], (str, bytes, bytearray)):
        raise ValueError("weight matrix row 0 must be a sequence")

    column_count = len(rows[0])
    if column_count < GROUP_WIDTH or (column_count % GROUP_WIDTH) != 0:
        raise ValueError("weight matrix must have K columns, where K is a multiple of 4")
    if column_count > 255:
        raise ValueError("weight matrix cannot contain more than 255 columns")

    matrix: Matrix = []
    for row_idx, row in enumerate(rows):
        if not isinstance(row, Sequence) or isinstance(row, (str, bytes, bytearray)):
            raise ValueError(f"weight matrix row {row_idx} must be a sequence")
        row_values = list(row)
        if len(row_values) != column_count:
            raise ValueError(f"weight matrix row {row_idx} must have exactly {column_count} columns")
        matrix.append([_coerce_int16(entry) for entry in row_values])

    return matrix


def _parse_literal_matrix(text: str) -> Matrix | None:
    stripped = text.strip()
    if not stripped:
        return None

    try:
        return normalize_weight_matrix(ast.literal_eval(stripped))
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
            if rows:
                return normalize_weight_matrix(rows)

    return None


def _parse_first_matrix_block(text: str) -> Matrix | None:
    rows: list[list[int]] = []

    for line in text.splitlines():
        row = _parse_numeric_row(line)
        if row is not None:
            rows.append(row)
        elif rows:
            try:
                return normalize_weight_matrix(rows)
            except ValueError:
                rows = []

    if rows:
        try:
            return normalize_weight_matrix(rows)
        except ValueError:
            pass

    return None


def parse_weight_matrix_text(text: str, label: str | None = None) -> Matrix:
    literal_matrix = _parse_literal_matrix(text)
    if literal_matrix is not None:
        return literal_matrix

    labels = [label] if label else [
        "Dense A",
        "Dense weights",
        "Weight matrix",
        "Matrix A",
        "Weights",
        "Pruned weights",
        "Pruned matrix",
        "Matrix",
    ]
    labeled_matrix = _parse_labeled_block(text, labels)
    if labeled_matrix is not None:
        return labeled_matrix

    block_matrix = _parse_first_matrix_block(text)
    if block_matrix is not None:
        return block_matrix

    raise ValueError(
        "could not find an MxK weight matrix. Use --matrix '[[1,2,3,4],...]', "
        "--file matrix.txt, or pipe rows of numbers into stdin."
    )


def infer_m(matrix: Sequence[Sequence[int]]) -> int:
    return len(normalize_weight_matrix(matrix))


def infer_k(matrix: Sequence[Sequence[int]]) -> int:
    return len(normalize_weight_matrix(matrix)[0])


def _coerce_uint8_dimension(value: Any, name: str) -> int:
    if isinstance(value, bool):
        raise ValueError(f"{name} must be an integer, not a boolean")
    number = int(value)
    if not 1 <= number <= 255:
        raise ValueError(f"{name} must be in the range 1..255")
    return number


def build_config_packet(matrix: Sequence[Sequence[int]], n_value: int = 4) -> bytes:
    normalized = normalize_weight_matrix(matrix)
    m_value = len(normalized)
    k_value = len(normalized[0])
    n_value = _coerce_uint8_dimension(n_value, "N")

    payload = bytearray()
    payload.append(m_value)
    payload.append(k_value)
    payload.append(n_value)
    for row in normalized:
        for group_start in range(0, k_value, GROUP_WIDTH):
            payload.extend(struct.pack("<hhhh", *row[group_start : group_start + GROUP_WIDTH]))

    return bytes([CONFIG_START_BYTE]) + bytes(payload)


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


def transact(
    port: str,
    baud: int,
    timeout: float,
    matrix: Sequence[Sequence[int]],
    n_value: int,
) -> None:
    try:
        import serial
    except ImportError as exc:
        raise SystemExit("pyserial is required: python3 -m pip install pyserial") from exc

    packet = build_config_packet(matrix, n_value=n_value)
    with serial.Serial(port, baudrate=baud, timeout=timeout, write_timeout=timeout) as ser:
        time.sleep(0.1)
        ser.reset_input_buffer()
        ser.write(packet)
        ser.flush()
        ack = read_exact(ser, 1)

    if ack[0] != CONFIG_ACK_BYTE:
        raise RuntimeError(f"expected config ack 0x5A, got 0x{ack[0]:02X}")


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


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send runtime dense A weights to the DE10-Lite UART top."
    )
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--file", type=Path, help="file containing dense-A or prune-style matrix output")
    source.add_argument("--text", help="literal text containing a dense-A matrix")

    parser.add_argument("--matrix", help="Dense A matrix literal, e.g. '[[3,-1,0,2],[4,5,-2,1]]'")
    parser.add_argument("--n", type=int, default=4, help="runtime dense/output column count N")
    parser.add_argument("--port", help="serial port, such as COM3 or /dev/tty.usbserial-XXXX")
    parser.add_argument("--baud", type=int, default=115200, help="UART baud rate")
    parser.add_argument("--timeout", type=float, default=2.0, help="serial read/write timeout in seconds")
    parser.add_argument("--dry-run", action="store_true", help="parse and encode without opening serial")
    parser.add_argument("--list-ports", action="store_true", help="print available serial ports and exit")

    return parser.parse_args(argv)


def _load_weight_matrix(args: argparse.Namespace) -> Matrix:
    if args.matrix is not None:
        return normalize_weight_matrix(ast.literal_eval(args.matrix))

    if args.file is not None:
        return parse_weight_matrix_text(args.file.read_text(encoding="utf-8"))

    if args.text is not None:
        return parse_weight_matrix_text(args.text)

    if not sys.stdin.isatty():
        return parse_weight_matrix_text(sys.stdin.read())

    raise SystemExit("provide --matrix, --file, --text, or pipe matrix text into stdin")


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)

    if args.list_ports:
        list_ports()
        return 0

    matrix = _load_weight_matrix(args)
    packet = build_config_packet(matrix, n_value=args.n)
    m_value = infer_m(matrix)
    k_value = infer_k(matrix)

    print("Dense A weights:")
    print(format_matrix(matrix))
    print(f"Inferred M: {m_value}")
    print(f"Inferred K: {k_value}")
    print(f"Runtime N: {args.n}")
    print(f"\nConfig packet: {len(packet)} bytes, starts with 0x{packet[0]:02X}")

    if args.dry_run:
        print(packet.hex(" "))
        return 0

    if not args.port:
        raise SystemExit("provide --port, or use --dry-run to only build the packet")

    transact(args.port, args.baud, args.timeout, matrix, args.n)
    print("Runtime dense weights configured.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
