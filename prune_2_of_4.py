"""Prune dense weights into 2:4 structured sparsity format."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, List, Sequence

Number = int | float
Matrix = List[List[Number]]


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


def main() -> None:
    dense_weights = [
        [3, -1, 0, 2],
        [4, 5, -2, 1],
        [0, -7, 6, 2],
        [8, 1, -3, 4],
    ]

    sparse_weights, pruned_weights = prune_2_of_4(dense_weights)

    print("Sparse values:", sparse_weights.values)
    print("Sparse indices:", sparse_weights.indices)
    print("\nPruned weights:")
    print(format_matrix(pruned_weights))


if __name__ == "__main__":
    main()
