#!/usr/bin/env python3
"""Print a copy-paste command for sending activation matrices to the UART queue."""

from __future__ import annotations

import argparse
import ast
import shlex
import sys
from pathlib import Path
from typing import Sequence

from send_matrix_uart import normalize_matrix_sequence

DEFAULT_SERIAL_PORT = "/dev/tty.usbserial-XXXX"


def _load_sequence(args: argparse.Namespace) -> list[list[list[int]]]:
    if args.matrices is not None:
        text = args.matrices
    elif args.file is not None:
        text = args.file.read_text(encoding="utf-8")
    elif not sys.stdin.isatty():
        text = sys.stdin.read()
        if not text.strip():
            text = ""
    else:
        text = ""

    if not text:
        text = repr(
            [
                [
                    [1, 2, 3, 4],
                    [5, 6, 7, 8],
                    [9, 10, 11, 12],
                    [13, 14, 15, 16],
                ],
                [
                    [2, 4, 6, 8],
                    [10, 12, 14, 16],
                    [18, 20, 22, 24],
                    [26, 28, 30, 32],
                ],
            ]
        )

    try:
        return normalize_matrix_sequence(ast.literal_eval(text.strip()))
    except (SyntaxError, ValueError) as exc:
        raise SystemExit(
            "provide a literal sequence of KxN matrices, for example "
            "'[[[1,2,3,4],...], [[2,4,6,8],...]]'"
        ) from exc


def build_activation_command(
    matrices: Sequence[Sequence[Sequence[int]]],
    serial_port: str,
) -> str:
    normalized = normalize_matrix_sequence(matrices)
    matrices_arg = shlex.quote(repr(normalized))
    port_arg = shlex.quote(serial_port)

    return (
        f"SERIAL_PORT={port_arg}\n"
        "python3 host/send_matrix_uart.py "
        '--port "$SERIAL_PORT" '
        f"--matrices {matrices_arg}"
    )


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a copy-paste UART command for a sequence of dense activation matrices."
    )
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--matrices", help="sequence of KxN matrices as a Python/JSON literal")
    source.add_argument("--file", type=Path, help="file containing a sequence of KxN matrices")
    parser.add_argument(
        "--serial-port",
        default=DEFAULT_SERIAL_PORT,
        help="serial port path to bake into the printed copy-paste command",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    matrices = _load_sequence(args)

    print(f"Activation matrices: {len(matrices)}")
    print(f"Shape per matrix: K={len(matrices[0])}, N={len(matrices[0][0])}")
    print("\nCopy-paste command to queue FPGA activations:")
    print(build_activation_command(matrices, args.serial_port))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
