import unittest

from reference_model import matmul


class ReferenceModelTest(unittest.TestCase):
    def test_matmul(self) -> None:
        lhs = [
            [3, 0, 0, 2],
            [4, 5, 0, 0],
            [0, -7, 6, 0],
            [8, 0, 0, 4],
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
                [29, 34, 39, 44],
                [29, 38, 47, 56],
                [19, 18, 17, 16],
                [60, 72, 84, 96],
            ],
        )

    def test_rejects_mismatched_dimensions(self) -> None:
        with self.assertRaises(ValueError):
            matmul([[1, 2]], [[1, 2]])


if __name__ == "__main__":
    unittest.main()
