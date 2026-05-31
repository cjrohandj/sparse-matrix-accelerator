import unittest

from prune_2_of_4 import build_send_weights_command, prune_2_of_4


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

    def test_builds_copy_paste_weight_command(self) -> None:
        sparse, _ = prune_2_of_4([[3, -1, 0, 2], [4, 5, -2, 1]])
        command = build_send_weights_command(
            sparse,
            n_value=5,
            serial_port="/dev/cu.usbserial-BG03U9T3",
        )

        self.assertIn("SERIAL_PORT=/dev/cu.usbserial-BG03U9T3", command)
        self.assertIn("python3 host/send_weights_uart.py", command)
        self.assertIn("--n 5", command)
        self.assertIn("--values '[[[3, 2]], [[4, 5]]]'", command)
        self.assertIn("--indices '[[[0, 3]], [[0, 1]]]'", command)


if __name__ == "__main__":
    unittest.main()
