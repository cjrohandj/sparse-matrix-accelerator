import unittest

from prune_2_of_4 import prune_2_of_4


class Prune2Of4Test(unittest.TestCase):
    def test_prunes_each_row_to_two_values_per_four(self) -> None:
        weights = [
            [3, -1, 0, 2],
            [4, 5, -2, 1],
            [0, -7, 6, 2],
            [8, 1, -3, 4],
        ]

        sparse, pruned = prune_2_of_4(weights)

        self.assertEqual(
            sparse.values,
            [
                [[3, 2]],
                [[4, 5]],
                [[-7, 6]],
                [[8, 4]],
            ],
        )
        self.assertEqual(
            sparse.indices,
            [
                [[0, 3]],
                [[0, 1]],
                [[1, 2]],
                [[0, 3]],
            ],
        )
        self.assertEqual(
            pruned,
            [
                [3, 0, 0, 2],
                [4, 5, 0, 0],
                [0, -7, 6, 0],
                [8, 0, 0, 4],
            ],
        )

    def test_ties_keep_lower_indices(self) -> None:
        sparse, pruned = prune_2_of_4([[1, -1, 1, -1]])

        self.assertEqual(sparse.indices, [[[0, 1]]])
        self.assertEqual(pruned, [[1, -1, 0, 0]])


if __name__ == "__main__":
    unittest.main()
