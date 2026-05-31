"""Prune dense weights into 2:4 structured sparsity format."""

from __future__ import annotations

import argparse
import ast
import shlex
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Sequence

Number = int | float
Matrix = List[List[Number]]

DEFAULT_SERIAL_PORT = "/dev/tty.usbserial-XXXX"
DEFAULT_N = 4


@dataclass(frozen=True)
class Sparse2Of4:
    """Compressed 2:4 sparse matrix metadata.

    values[row][group][lane] holds the selected non-zero weight.
    indices[row][group][lane] holds the selected column index inside that group.
    """

    rows: int
    cols: int
    values: List[List[List[Number]]]
    indices: List[List[List[int]]]


def _as_matrix(matrix: Sequence[Sequence[Number]], name: str) -> Matrix:
    if not matrix:
        raise ValueError(f"{name} must have at least one row")

    rows = [list(row) for row in matrix]
    cols = len(rows[0])
    if cols == 0:
        raise ValueError(f"{name} must have at least one column")
    if any(len(row) != cols for row in rows):
        raise ValueError(f"{name} must be rectangular")

    return rows


def prune_2_of_4(weights: Sequence[Sequence[Number]]) -> tuple[Sparse2Of4, Matrix]:
    """Keep two largest-magnitude values in every four-column group."""

    dense = _as_matrix(weights, "weights")
    rows = len(dense)
    cols = len(dense[0])
    if cols % 4 != 0:
        raise ValueError("weights column count must be a multiple of 4")

    sparse_values: List[List[List[Number]]] = []
    sparse_indices: List[List[List[int]]] = []
    pruned: Matrix = [[0 for _ in range(cols)] for _ in range(rows)]

    for row_idx, row in enumerate(dense):
        row_values: List[List[Number]] = []
        row_indices: List[List[int]] = []

        for group_start in range(0, cols, 4):
            group = row[group_start : group_start + 4]
            kept = sorted(range(4), key=lambda idx: (-abs(group[idx]), idx))[:2]
            kept.sort()

            row_values.append([group[idx] for idx in kept])
            row_indices.append(kept)
            for local_col in kept:
                pruned[row_idx][group_start + local_col] = group[local_col]

        sparse_values.append(row_values)
        sparse_indices.append(row_indices)

    return Sparse2Of4(rows, cols, sparse_values, sparse_indices), pruned


def format_matrix(matrix: Iterable[Iterable[Number]]) -> str:
    return "\n".join(" ".join(f"{value:>6}" for value in row) for row in matrix)


def _parse_matrix_text(text: str) -> Matrix:
    try:
        return _as_matrix(ast.literal_eval(text.strip()), "weights")
    except (SyntaxError, ValueError) as literal_error:
        rows: Matrix = []
        for line in text.splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            try:
                rows.append([ast.literal_eval(part) for part in stripped.replace(",", " ").split()])
            except (SyntaxError, ValueError) as row_error:
                raise ValueError(
                    "weights must be a Python-style matrix literal or whitespace-separated rows"
                ) from row_error

        if rows:
            return _as_matrix(rows, "weights")
        raise ValueError("weights input is empty") from literal_error


def _load_weights(args: argparse.Namespace) -> Matrix:
    if args.matrix is not None:
        return _parse_matrix_text(args.matrix)
    if args.file is not None:
        return _parse_matrix_text(args.file.read_text(encoding="utf-8"))
    if not sys.stdin.isatty():
        stdin_text = sys.stdin.read()
        if stdin_text.strip():
            return _parse_matrix_text(stdin_text)

    return [
        [3, -1, 0, 2],
        [4, 5, -2, 1],
        [0, -7, 6, 2],
        [8, 1, -3, 4],
    ]


def build_send_weights_command(
    sparse_weights: Sparse2Of4,
    n_value: int,
    serial_port: str,
) -> str:
    values_arg = shlex.quote(repr(sparse_weights.values))
    indices_arg = shlex.quote(repr(sparse_weights.indices))
    port_arg = shlex.quote(serial_port)

    return (
        f"SERIAL_PORT={port_arg}\n"
        "python3 host/send_weights_uart.py "
        '--port "$SERIAL_PORT" '
        f"--n {n_value} "
        f"--values {values_arg} "
        f"--indices {indices_arg}"
    )


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Prune an MxK dense weight matrix into 2:4 format and print a UART upload command."
    )
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--matrix", help="MxK matrix as a Python/JSON literal")
    source.add_argument("--file", type=Path, help="file containing an MxK matrix")

    parser.add_argument("--n", type=int, default=DEFAULT_N, help="runtime dense/output column count N")
    parser.add_argument(
        "--serial-port",
        default=DEFAULT_SERIAL_PORT,
        help="serial port path to bake into the printed copy-paste command",
    )
    parser.add_argument(
        "--no-command",
        action="store_true",
        help="print only sparse/pruned data, without the copy-paste UART command",
    )

    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> None:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    dense_weights = _load_weights(args)

    sparse_weights, pruned_weights = prune_2_of_4(dense_weights)

    print("Sparse values:", sparse_weights.values)
    print("Sparse indices:", sparse_weights.indices)
    print("\nPruned weights:")
    print(format_matrix(pruned_weights))
    if not args.no_command:
        print("\nCopy-paste command to configure FPGA weights:")
        print(build_send_weights_command(sparse_weights, args.n, args.serial_port))


if __name__ == "__main__":
    main()
