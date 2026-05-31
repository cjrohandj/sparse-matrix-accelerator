#!/usr/bin/env python3
"""Configure the DE10-Lite sparse weights over UART.

The expected FPGA packet is implemented by rtl_board/matrix_uart_controller.sv:

Host -> FPGA:
    0xA0
    M uint8, inferred from the sparse row count
    K uint8, inferred from the sparse group count
    N uint8, provided by --n
    M * (K/4) sparse row/group records, each encoded as:
        weight0 int16 little-endian
        weight1 int16 little-endian
        index0  uint8
        index1  uint8

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
from typing import Any, Sequence

CONFIG_START_BYTE = 0xA0
CONFIG_ACK_BYTE = 0x5A
ROWS = 4
LANES = 2
GROUP_WIDTH = 4
INPUT_MIN = -(2**15)
INPUT_MAX = (2**15) - 1

SparseValues = list[list[list[int]]]
SparseIndices = list[list[list[int]]]


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


def _coerce_index(value: Any) -> int:
    if isinstance(value, bool):
        raise ValueError("indices must be integers, not booleans")
    if isinstance(value, int):
        number = value
    elif isinstance(value, str):
        number = int(value.strip(), 0)
    else:
        raise ValueError(f"index {value!r} is not an integer")

    if not 0 <= number <= 3:
        raise ValueError(f"index {number} is outside the 2-bit range 0..3")
    return number


def _normalize_grouped_rows(value: Any, name: str) -> list[list[list[Any]]]:
    if not isinstance(value, Sequence) or isinstance(value, (str, bytes, bytearray)):
        raise ValueError(f"{name} must be a sequence of rows")

    rows = list(value)
    if not rows:
        raise ValueError(f"{name} must contain at least one row")
    if len(rows) > 255:
        raise ValueError(f"{name} cannot contain more than 255 rows")

    normalized: list[list[list[Any]]] = []
    for row_idx, row in enumerate(rows):
        if not isinstance(row, Sequence) or isinstance(row, (str, bytes, bytearray)):
            raise ValueError(f"{name} row {row_idx} must be a sequence")

        row_groups = list(row)
        if not row_groups:
            raise ValueError(f"{name} row {row_idx} must contain at least one 4-column group")

        normalized_groups: list[list[Any]] = []
        for group_idx, group in enumerate(row_groups):
            if not isinstance(group, Sequence) or isinstance(group, (str, bytes, bytearray)):
                raise ValueError(f"{name} row {row_idx} group {group_idx} must be a sequence")

            group_values = list(group)
            if len(group_values) != LANES:
                raise ValueError(
                    f"{name} row {row_idx} group {group_idx} must contain exactly {LANES} entries"
                )
            normalized_groups.append(group_values)

        normalized.append(normalized_groups)

    group_count = len(normalized[0])
    if any(len(row) != group_count for row in normalized):
        raise ValueError(f"{name} must contain the same number of groups in every row")

    return normalized


def normalize_sparse_values(value: Any) -> SparseValues:
    return [
        [[_coerce_int16(entry) for entry in group] for group in row]
        for row in _normalize_grouped_rows(value, "values")
    ]


def normalize_sparse_indices(value: Any) -> SparseIndices:
    return [
        [[_coerce_index(entry) for entry in group] for group in row]
        for row in _normalize_grouped_rows(value, "indices")
    ]


def _extract_literal_after_label(text: str, label: str) -> Any:
    pattern = re.compile(rf"^{re.escape(label)}\s*:\s*(.+)$", re.IGNORECASE | re.MULTILINE)
    match = pattern.search(text)
    if not match:
        raise ValueError(f"could not find '{label}:' in input")
    return ast.literal_eval(match.group(1).strip())


def parse_prune_text(text: str) -> tuple[SparseValues, SparseIndices]:
    values = normalize_sparse_values(_extract_literal_after_label(text, "Sparse values"))
    indices = normalize_sparse_indices(_extract_literal_after_label(text, "Sparse indices"))
    return values, indices


def infer_k(values: Sequence[Sequence[Sequence[int]]], indices: Sequence[Sequence[Sequence[int]]]) -> int:
    normalized_values = normalize_sparse_values(values)
    normalized_indices = normalize_sparse_indices(indices)
    value_groups = len(normalized_values[0])
    index_groups = len(normalized_indices[0])
    if value_groups != index_groups:
        raise ValueError("values and indices must have the same number of groups")

    return value_groups * GROUP_WIDTH


def infer_m(values: Sequence[Sequence[Sequence[int]]], indices: Sequence[Sequence[Sequence[int]]]) -> int:
    normalized_values = normalize_sparse_values(values)
    normalized_indices = normalize_sparse_indices(indices)
    if len(normalized_values) != len(normalized_indices):
        raise ValueError("values and indices must have the same number of rows")

    return len(normalized_values)


def _coerce_uint8_dimension(value: Any, name: str) -> int:
    if isinstance(value, bool):
        raise ValueError(f"{name} must be an integer, not a boolean")
    number = int(value)
    if not 1 <= number <= 255:
        raise ValueError(f"{name} must be in the range 1..255")
    return number


def build_config_packet(
    values: Sequence[Sequence[Sequence[int]]],
    indices: Sequence[Sequence[Sequence[int]]],
    n_value: int = 4,
) -> bytes:
    normalized_values = normalize_sparse_values(values)
    normalized_indices = normalize_sparse_indices(indices)
    m_value = infer_m(normalized_values, normalized_indices)
    k_value = infer_k(normalized_values, normalized_indices)
    n_value = _coerce_uint8_dimension(n_value, "N")

    payload = bytearray()
    payload.append(m_value)
    payload.append(k_value)
    payload.append(n_value)
    groups = k_value // GROUP_WIDTH
    for row in range(m_value):
        for group in range(groups):
            weight0, weight1 = normalized_values[row][group]
            index0, index1 = normalized_indices[row][group]
            payload.extend(struct.pack("<hhBB", weight0, weight1, index0, index1))

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
    values: Sequence[Sequence[Sequence[int]]],
    indices: Sequence[Sequence[Sequence[int]]],
    n_value: int,
) -> None:
    try:
        import serial
    except ImportError as exc:
        raise SystemExit("pyserial is required: python3 -m pip install pyserial") from exc

    packet = build_config_packet(values, indices, n_value=n_value)
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
        description="Send runtime sparse A weights/indices to the DE10-Lite UART top."
    )
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--file", type=Path, help="file containing prune_2_of_4.py-style output")
    source.add_argument("--text", help="literal text containing Sparse values and Sparse indices lines")

    parser.add_argument("--values", help="Sparse values literal, e.g. '[[[3,2]],[[4,5]],...]'")
    parser.add_argument("--indices", help="Sparse indices literal, e.g. '[[[0,3]],[[0,1]],...]'")
    parser.add_argument("--n", type=int, default=4, help="runtime dense/output column count N")
    parser.add_argument("--port", help="serial port, such as COM3 or /dev/tty.usbserial-XXXX")
    parser.add_argument("--baud", type=int, default=115200, help="UART baud rate")
    parser.add_argument("--timeout", type=float, default=2.0, help="serial read/write timeout in seconds")
    parser.add_argument("--dry-run", action="store_true", help="parse and encode without opening serial")
    parser.add_argument("--list-ports", action="store_true", help="print available serial ports and exit")

    return parser.parse_args(argv)


def _load_values_and_indices(args: argparse.Namespace) -> tuple[SparseValues, SparseIndices]:
    if args.values is not None or args.indices is not None:
        if args.values is None or args.indices is None:
            raise SystemExit("--values and --indices must be provided together")
        return (
            normalize_sparse_values(ast.literal_eval(args.values)),
            normalize_sparse_indices(ast.literal_eval(args.indices)),
        )

    if args.file is not None:
        return parse_prune_text(args.file.read_text(encoding="utf-8"))

    if args.text is not None:
        return parse_prune_text(args.text)

    if not sys.stdin.isatty():
        return parse_prune_text(sys.stdin.read())

    raise SystemExit("provide --file, --text, --values/--indices, or pipe prune output into stdin")


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)

    if args.list_ports:
        list_ports()
        return 0

    values, indices = _load_values_and_indices(args)
    packet = build_config_packet(values, indices, n_value=args.n)
    m_value = infer_m(values, indices)
    k_value = infer_k(values, indices)

    print("Sparse values:")
    print(values)
    print("Sparse indices:")
    print(indices)
    print(f"Inferred M: {m_value}")
    print(f"Inferred K: {k_value}")
    print(f"Runtime N: {args.n}")
    print(f"\nConfig packet: {len(packet)} bytes, starts with 0x{packet[0]:02X}")

    if args.dry_run:
        print(packet.hex(" "))
        return 0

    if not args.port:
        raise SystemExit("provide --port, or use --dry-run to only build the packet")

    transact(args.port, args.baud, args.timeout, values, indices, args.n)
    print("Runtime sparse weights configured.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
