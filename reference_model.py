"""Golden reference model for matrix multiplication.

This intentionally contains only plain matrix multiplication. Pruning and mask
generation live in a separate script so RTL outputs can be compared against the
mathematical result of multiplying the already-pruned matrix.
"""

from __future__ import annotations

from typing import Iterable, List, Sequence

Number = int | float
Matrix = List[List[Number]]


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


def matmul(lhs: Sequence[Sequence[Number]], rhs: Sequence[Sequence[Number]]) -> Matrix:
    """Return lhs * rhs using ordinary dense matrix multiplication."""

    left = _as_matrix(lhs, "lhs")
    right = _as_matrix(rhs, "rhs")
    if len(left[0]) != len(right):
        raise ValueError(f"lhs columns ({len(left[0])}) must match rhs rows ({len(right)})")

    result: Matrix = [[0 for _ in range(len(right[0]))] for _ in range(len(left))]
    for row in range(len(left)):
        for inner in range(len(right)):
            for col in range(len(right[0])):
                result[row][col] += left[row][inner] * right[inner][col]

    return result


def format_matrix(matrix: Iterable[Iterable[Number]]) -> str:
    return "\n".join(" ".join(f"{value:>6}" for value in row) for row in matrix)


def main() -> None:
    dense_weights = [
        [3, -1, 0, 2],
        [4, 5, -2, 1],
        [0, -7, 6, 2],
        [8, 1, -3, 4],
    ]
    dense_input = [
        [1, 2, 3, 4],
        [5, 6, 7, 8],
        [9, 10, 11, 12],
        [13, 14, 15, 16],
    ]

    print("Expected output:")
    print(format_matrix(matmul(dense_weights, dense_input)))


if __name__ == "__main__":
    main()
