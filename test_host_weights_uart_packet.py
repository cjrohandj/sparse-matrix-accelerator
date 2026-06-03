import struct
import unittest

from host.send_weights_uart import (
    CONFIG_START_BYTE,
    build_config_packet,
    parse_weight_matrix_text,
)


class HostWeightsUartPacketTest(unittest.TestCase):
    def test_builds_dense_weight_config_packet(self) -> None:
        matrix = [
            [3, -1, 0, 2],
            [4, 5, -2, 1],
            [0, -7, 6, 2],
            [8, 1, -3, 4],
        ]

        packet = build_config_packet(matrix)

        self.assertEqual(packet[0], CONFIG_START_BYTE)
        self.assertEqual(len(packet), 36)
        self.assertEqual(packet[1:4], bytes([4, 4, 4]))
        self.assertEqual(
            packet[4:],
            b"".join(
                [
                    struct.pack("<hhhh", 3, -1, 0, 2),
                    struct.pack("<hhhh", 4, 5, -2, 1),
                    struct.pack("<hhhh", 0, -7, 6, 2),
                    struct.pack("<hhhh", 8, 1, -3, 4),
                ]
            ),
        )

    def test_parses_prune_style_matrix_block(self) -> None:
        text = """Sparse values: [[[3, 2]], [[4, 5]], [[-7, 6]], [[8, 4]]]
Sparse indices: [[[0, 3]], [[0, 1]], [[1, 2]], [[0, 3]]]

Pruned weights:
     3      0      0      2
     4      5      0      0
     0     -7      6      0
     8      0      0      4
"""

        self.assertEqual(
            parse_weight_matrix_text(text),
            [
                [3, 0, 0, 2],
                [4, 5, 0, 0],
                [0, -7, 6, 0],
                [8, 0, 0, 4],
            ],
        )

    def test_builds_k8_dense_weight_packet(self) -> None:
        matrix = [
            [1, 2, 3, 4, 5, 6, 7, 8],
            [9, 10, 11, 12, 13, 14, 15, 16],
            [17, 18, 19, 20, 21, 22, 23, 24],
            [25, 26, 27, 28, 29, 30, 31, 32],
        ]

        packet = build_config_packet(matrix)

        self.assertEqual(packet[0], CONFIG_START_BYTE)
        self.assertEqual(packet[1:4], bytes([4, 8, 4]))
        self.assertEqual(len(packet), 68)


if __name__ == "__main__":
    unittest.main()
