#!/usr/bin/env python3
"""Send one KxN dense matrix or a KxN matrix sequence to the DE10-Lite UART wrapper.

The FPGA-side protocol is implemented by rtl_board/matrix_uart_controller.sv:

Host -> FPGA:
    0xAA + K*N signed int16 values, column-major, little-endian

FPGA -> Host:
    0xAC if the matrix was accepted into the waiting room
    0xEE if the waiting room was full
    0x55 + M uint8 + N uint8 + M*N tagged results:
        row uint8 + col uint8 + value int64 little-endian
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
MATRIX_ACK_BYTE = 0xAC
MATRIX_NACK_BYTE = 0xEE
RESPONSE_START_BYTE = 0x55
INPUT_MIN = -(2**15)
INPUT_MAX = (2**15) - 1

Matrix = list[list[int]]
MatrixSequence = list[Matrix]

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
    """Validate and normalize an object into a KxN int16 matrix."""

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
    if len(rows) < 4 or (len(rows) % 4) != 0:
        raise ValueError("matrix must have K rows, where K is a multiple of 4")
    if not isinstance(rows[0], Sequence) or isinstance(rows[0], (str, bytes, bytearray)):
        raise ValueError("matrix row 0 must be a sequence")

    column_count = len(rows[0])
    if not 1 <= column_count <= 255:
        raise ValueError("matrix must have between 1 and 255 columns")

    matrix: Matrix = []
    for row_idx, row in enumerate(rows):
        if not isinstance(row, Sequence) or isinstance(row, (str, bytes, bytearray)):
            raise ValueError(f"matrix row {row_idx} must be a sequence")
        row_values = list(row)
        if len(row_values) != column_count:
            raise ValueError(
                f"matrix row {row_idx} must have exactly {column_count} columns"
            )
        matrix.append([_coerce_int16(entry) for entry in row_values])

    return matrix


def normalize_matrix_sequence(value: Any) -> MatrixSequence:
    if isinstance(value, dict):
        for key in ("matrices", "sequence", "activations", "activation_matrices", "B_sequence"):
            if key in value:
                value = value[key]
                break
        else:
            raise ValueError(
                "matrix-sequence dictionary must contain a key such as "
                "'matrices', 'sequence', or 'activations'"
            )

    if not isinstance(value, Sequence) or isinstance(value, (str, bytes, bytearray)):
        raise ValueError("matrix sequence must be a sequence of matrices")

    matrices = [normalize_matrix(matrix) for matrix in value]
    if not matrices:
        raise ValueError("matrix sequence must contain at least one matrix")

    k_value = len(matrices[0])
    n_value = len(matrices[0][0])
    for matrix_idx, matrix in enumerate(matrices):
        if len(matrix) != k_value or len(matrix[0]) != n_value:
            raise ValueError(
                f"matrix {matrix_idx} has shape {len(matrix)}x{len(matrix[0])}; "
                f"expected {k_value}x{n_value}"
            )

    return matrices


def _parse_literal_matrix(text: str) -> Matrix | None:
    stripped = text.strip()
    if not stripped:
        return None

    try:
        return normalize_matrix(ast.literal_eval(stripped))
    except (SyntaxError, ValueError):
        return None


def parse_matrix_sequence_text(text: str) -> MatrixSequence:
    try:
        return normalize_matrix_sequence(ast.literal_eval(text.strip()))
    except (SyntaxError, ValueError) as exc:
        raise ValueError(
            "could not parse activation matrix sequence. Use a literal like "
            "'[[[1,2,3,4],...], [[2,4,6,8],...]]'."
        ) from exc


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
                return normalize_matrix(rows)

    return None


def _parse_first_matrix_block(text: str) -> Matrix | None:
    rows: list[list[int]] = []

    for line in text.splitlines():
        row = _parse_numeric_row(line)
        if row is not None:
            rows.append(row)
        elif rows:
            if len(rows) >= 4 and (len(rows) % 4) == 0:
                try:
                    return normalize_matrix(rows)
                except ValueError:
                    pass
            rows = []

    if len(rows) >= 4 and (len(rows) % 4) == 0:
        try:
            return normalize_matrix(rows)
        except ValueError:
            pass

    return None


def parse_matrix_text(text: str, label: str | None = None) -> Matrix:
    """Parse a KxN matrix from literal, raw-row, or prune-style text."""

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
        "could not find a KxN matrix. Use --matrix '[[1,2,3,4],...]', "
        "--file matrix.txt, or pipe four rows of numbers into stdin."
    )


def flatten_column_major(matrix: Sequence[Sequence[int]]) -> list[int]:
    row_count = len(matrix)
    column_count = len(matrix[0])

    return [matrix[row][col] for col in range(column_count) for row in range(row_count)]


def build_request_packet(matrix: Sequence[Sequence[int]]) -> bytes:
    normalized = normalize_matrix(matrix)
    values = flatten_column_major(normalized)
    payload = struct.pack(f"<{len(values)}h", *values)
    return bytes([REQUEST_START_BYTE]) + payload


def build_request_packets(matrices: Sequence[Sequence[Sequence[int]]]) -> list[bytes]:
    return [build_request_packet(matrix) for matrix in normalize_matrix_sequence(matrices)]


def _empty_matrix(rows: int, cols: int) -> Matrix:
    return [[0 for _ in range(cols)] for _ in range(rows)]


def decode_response_packet(packet: bytes) -> Matrix:
    if len(packet) < 3:
        raise ValueError(f"response must contain at least 3 header bytes, got {len(packet)}")
    if packet[0] != RESPONSE_START_BYTE:
        raise ValueError(f"expected response start byte 0x55, got 0x{packet[0]:02X}")

    rows = packet[1]
    cols = packet[2]
    expected_len = 3 + (rows * cols * 10)
    if len(packet) != expected_len:
        raise ValueError(f"response must be {expected_len} bytes, got {len(packet)}")

    matrix = _empty_matrix(rows, cols)
    seen: set[tuple[int, int]] = set()
    offset = 3

    for _ in range(rows * cols):
        row = packet[offset]
        col = packet[offset + 1]
        value = struct.unpack("<q", packet[offset + 2 : offset + 10])[0]
        offset += 10

        if row >= rows or col >= cols:
            raise ValueError(f"response entry has out-of-range coordinate ({row}, {col})")
        if (row, col) in seen:
            raise ValueError(f"response entry repeats coordinate ({row}, {col})")

        matrix[row][col] = value
        seen.add((row, col))

    return matrix


def decode_matrix_ack(packet: bytes) -> None:
    if len(packet) != 1:
        raise ValueError(f"matrix acknowledgment must be 1 byte, got {len(packet)}")
    if packet[0] == MATRIX_ACK_BYTE:
        return
    if packet[0] == MATRIX_NACK_BYTE:
        raise RuntimeError("FPGA waiting room rejected the matrix because it was full")
    raise ValueError(
        f"expected matrix acknowledgment 0x{MATRIX_ACK_BYTE:02X}, "
        f"got 0x{packet[0]:02X}"
    )


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


def _read_next_uart_message(serial_port: Any) -> tuple[str, Matrix | None]:
    first = read_exact(serial_port, 1)

    if first[0] in (MATRIX_ACK_BYTE, MATRIX_NACK_BYTE):
        decode_matrix_ack(first)
        return ("ack", None)

    if first[0] != RESPONSE_START_BYTE:
        raise ValueError(
            f"expected ACK/NACK or response start byte 0x55, got 0x{first[0]:02X}"
        )

    header_tail = read_exact(serial_port, 2)
    rows = header_tail[0]
    cols = header_tail[1]
    payload = read_exact(serial_port, rows * cols * 10)
    return ("result", decode_response_packet(first + header_tail + payload))


def _read_acknowledged_results(serial_port: Any, expected_count: int) -> list[Matrix]:
    ack_count = 0
    results: list[Matrix] = []

    while ack_count < expected_count or len(results) < expected_count:
        message_type, matrix = _read_next_uart_message(serial_port)
        if message_type == "ack":
            ack_count += 1
        else:
            assert matrix is not None
            results.append(matrix)

    return results


def _load_serial_module() -> Any:
    try:
        import serial
    except ImportError as exc:
        raise SystemExit("pyserial is required: python3 -m pip install pyserial") from exc
    return serial


def _transact_open_port(serial_port: Any, request: bytes, response_len: int) -> Matrix:
    serial_port.write(request)
    serial_port.flush()
    return _read_acknowledged_results(serial_port, 1)[0]


def transact(port: str, baud: int, timeout: float, matrix: Sequence[Sequence[int]]) -> Matrix:
    serial = _load_serial_module()

    request = build_request_packet(matrix)

    with serial.Serial(port, baudrate=baud, timeout=timeout, write_timeout=timeout) as ser:
        time.sleep(0.1)
        ser.reset_input_buffer()
        return _transact_open_port(ser, request, 0)


def transact_queued(
    port: str,
    baud: int,
    timeout: float,
    matrix: Sequence[Sequence[int]],
    count: int,
) -> list[Matrix]:
    if count <= 0:
        raise ValueError("queued transaction count must be a positive integer")

    serial = _load_serial_module()
    request = build_request_packet(matrix)
    results: list[Matrix] = []

    with serial.Serial(port, baudrate=baud, timeout=timeout, write_timeout=timeout) as ser:
        time.sleep(0.1)
        ser.reset_input_buffer()

        for _ in range(count):
            ser.write(request)
        ser.flush()

        results = _read_acknowledged_results(ser, count)

    return results


def transact_sequence(
    port: str,
    baud: int,
    timeout: float,
    matrices: Sequence[Sequence[Sequence[int]]],
) -> list[Matrix]:
    normalized = normalize_matrix_sequence(matrices)
    serial = _load_serial_module()
    requests = [build_request_packet(matrix) for matrix in normalized]
    results: list[Matrix] = []

    with serial.Serial(port, baudrate=baud, timeout=timeout, write_timeout=timeout) as ser:
        time.sleep(0.1)
        ser.reset_input_buffer()

        for request in requests:
            ser.write(request)
        ser.flush()

        results = _read_acknowledged_results(ser, len(requests))

    return results


def benchmark(
    port: str,
    baud: int,
    timeout: float,
    matrix: Sequence[Sequence[int]],
    iterations: int,
) -> tuple[Matrix, list[float]]:
    if iterations <= 0:
        raise ValueError("benchmark iterations must be a positive integer")

    serial = _load_serial_module()
    request = build_request_packet(matrix)
    latencies_s: list[float] = []
    last_result: Matrix | None = None

    with serial.Serial(port, baudrate=baud, timeout=timeout, write_timeout=timeout) as ser:
        time.sleep(0.1)
        ser.reset_input_buffer()

        for _ in range(iterations):
            start_time = time.perf_counter()
            last_result = _transact_open_port(ser, request, 0)
            latencies_s.append(time.perf_counter() - start_time)

    assert last_result is not None
    return last_result, latencies_s


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
    if args.demo or args.matrices is not None or args.matrices_file is not None:
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
        description="Send a KxN int16 dense B matrix to the DE10-Lite dense matmul UART top."
    )
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--matrix", help="KxN matrix as a Python/JSON literal")
    source.add_argument("--file", type=Path, help="file containing a KxN matrix")
    source.add_argument("--demo", action="store_true", help="send the built-in [[1..16]] demo matrix")

    parser.add_argument("--matrices", help="sequence of KxN matrices as a Python/JSON literal")
    parser.add_argument("--matrices-file", type=Path, help="file containing a sequence of KxN matrices")
    parser.add_argument("--label", help="label to parse from a text file, for example 'Pruned weights'")
    parser.add_argument("--port", help="serial port, such as COM3 or /dev/tty.usbserial-XXXX")
    parser.add_argument("--baud", type=int, default=115200, help="UART baud rate")
    parser.add_argument("--timeout", type=float, default=2.0, help="serial read/write timeout in seconds")
    parser.add_argument(
        "--benchmark",
        type=int,
        metavar="N",
        help="run N timed request/response transactions and report latency and throughput",
    )
    parser.add_argument(
        "--queued",
        type=int,
        metavar="N",
        help="send N copies back-to-back, then read N ACKs and N result packets",
    )
    parser.add_argument("--dry-run", action="store_true", help="parse and encode without opening serial")
    parser.add_argument("--list-ports", action="store_true", help="print available serial ports and exit")

    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)

    if args.list_ports:
        list_ports()
        return 0

    sequence_text: str | None = None
    if args.matrices is not None:
        sequence_text = args.matrices
    elif args.matrices_file is not None:
        sequence_text = args.matrices_file.read_text(encoding="utf-8")

    if sequence_text is not None:
        matrices = parse_matrix_sequence_text(sequence_text)
        matrix = matrices[0]
    else:
        matrices = None

    source_text = _read_source_text(args)
    if matrices is not None:
        pass
    elif args.demo:
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
    print(f"Inferred K: {len(matrix)}")
    print(f"Inferred N: {len(matrix[0])}")
    print("Serialized B order: column-major")
    if matrices is not None:
        print(f"Activation matrices queued: {len(matrices)}")
    print(f"\nRequest packet: {len(request)} bytes, starts with 0x{request[0]:02X}")

    if args.dry_run:
        if matrices is None:
            print(request.hex(" "))
        else:
            for packet_index, packet in enumerate(build_request_packets(matrices)):
                print(f"packet[{packet_index}]: {packet.hex(' ')}")
        return 0

    if not args.port:
        raise SystemExit("provide --port, or use --dry-run to only build the packet")

    if args.benchmark is not None and (args.queued is not None or matrices is not None):
        raise SystemExit("use --benchmark only with a single matrix")
    if args.queued is not None and matrices is not None:
        raise SystemExit("use either --queued for repeated copies or --matrices for a sequence")

    if args.benchmark is not None:
        if args.benchmark <= 0:
            raise SystemExit("--benchmark N requires N >= 1")

        result, latencies_s = benchmark(
            args.port,
            args.baud,
            args.timeout,
            matrix,
            args.benchmark,
        )
        total_time_s = sum(latencies_s)
        avg_latency_s = total_time_s / len(latencies_s)
        min_latency_s = min(latencies_s)
        max_latency_s = max(latencies_s)
        throughput = len(latencies_s) / total_time_s if total_time_s > 0.0 else float("inf")

        print("\nBenchmark results:")
        print(
            f"  transactions: {len(latencies_s)} "
            "(serial open and initial 100 ms settle delay excluded)"
        )
        print(f"  total time:   {total_time_s * 1e3:.3f} ms")
        print(f"  avg latency:  {avg_latency_s * 1e3:.3f} ms")
        print(f"  min latency:  {min_latency_s * 1e3:.3f} ms")
        print(f"  max latency:  {max_latency_s * 1e3:.3f} ms")
        print(f"  throughput:   {throughput:.3f} matrices/s")
        results_to_print: MatrixSequence = [result]
    elif matrices is not None:
        queued_results = transact_sequence(
            args.port,
            args.baud,
            args.timeout,
            matrices,
        )
        print(f"\nQueued activation matrices accepted: {len(queued_results)}")
        results_to_print = queued_results
    elif args.queued is not None:
        if args.queued <= 0:
            raise SystemExit("--queued N requires N >= 1")

        queued_results = transact_queued(
            args.port,
            args.baud,
            args.timeout,
            matrix,
            args.queued,
        )
        print(f"\nQueued transactions accepted: {len(queued_results)}")
        results_to_print = queued_results
    else:
        results_to_print = [transact(args.port, args.baud, args.timeout, matrix)]

    if len(results_to_print) == 1:
        print("\nOutput matrix C:")
        print(format_matrix(results_to_print[0]))
    else:
        print("\nOutput matrices C:")
        for result_index, result_matrix in enumerate(results_to_print):
            print(f"\nC[{result_index}]:")
            print(format_matrix(result_matrix))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
