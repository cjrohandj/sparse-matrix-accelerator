import unittest

from reference_model import matmul


class ReferenceModelTest(unittest.TestCase):
    def test_matmul(self) -> None:
        lhs = [
            [3, -1, 0, 2],
            [4, 5, -2, 1],
            [0, -7, 6, 2],
            [8, 1, -3, 4],
        ]
        rhs = [
            [1, 2, 3, 4],
            [5, 6, 7, 8],
            [9, 10, 11, 12],
            [13, 14, 15, 16],
        ]

        self.assertEqual(
            matmul(lhs, rhs),
            [
                [24, 28, 32, 36],
                [24, 32, 40, 48],
                [45, 46, 47, 48],
                [38, 48, 58, 68],
            ],
        )

    def test_rejects_mismatched_dimensions(self) -> None:
        with self.assertRaises(ValueError):
            matmul([[1, 2]], [[1, 2]])


if __name__ == "__main__":
    unittest.main()
