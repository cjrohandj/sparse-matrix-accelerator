import struct
import unittest

from host.send_weights_uart import (
    CONFIG_START_BYTE,
    build_config_packet,
    parse_prune_text,
)


class HostWeightsUartPacketTest(unittest.TestCase):
    def test_builds_weight_config_packet(self) -> None:
        values = [[[3, 2]], [[4, 5]], [[-7, 6]], [[8, 4]]]
        indices = [[[0, 3]], [[0, 1]], [[1, 2]], [[0, 3]]]

        packet = build_config_packet(values, indices)

        self.assertEqual(packet[0], CONFIG_START_BYTE)
        self.assertEqual(len(packet), 28)
        self.assertEqual(packet[1:4], bytes([4, 4, 4]))
        self.assertEqual(
            packet[4:],
            b"".join(
                [
                    struct.pack("<hhBB", 3, 2, 0, 3),
                    struct.pack("<hhBB", 4, 5, 0, 1),
                    struct.pack("<hhBB", -7, 6, 1, 2),
                    struct.pack("<hhBB", 8, 4, 0, 3),
                ]
            ),
        )

    def test_parses_prune_script_output(self) -> None:
        text = """Sparse values: [[[3, 2]], [[4, 5]], [[-7, 6]], [[8, 4]]]
Sparse indices: [[[0, 3]], [[0, 1]], [[1, 2]], [[0, 3]]]

Pruned weights:
     3      0      0      2
     4      5      0      0
     0     -7      6      0
     8      0      0      4
"""

        self.assertEqual(
            parse_prune_text(text),
            (
                [[[3, 2]], [[4, 5]], [[-7, 6]], [[8, 4]]],
                [[[0, 3]], [[0, 1]], [[1, 2]], [[0, 3]]],
            ),
        )

    def test_infers_k8_from_two_sparse_groups(self) -> None:
        values = [
            [[1, 0], [2, 0]],
            [[3, 0], [4, 0]],
            [[5, 0], [6, 0]],
            [[7, 0], [8, 0]],
        ]
        indices = [
            [[0, 1], [0, 1]],
            [[1, 0], [1, 0]],
            [[2, 0], [2, 0]],
            [[3, 0], [3, 0]],
        ]

        packet = build_config_packet(values, indices)

        self.assertEqual(packet[0], CONFIG_START_BYTE)
        self.assertEqual(packet[1:4], bytes([4, 8, 4]))
        self.assertEqual(len(packet), 52)


if __name__ == "__main__":
    unittest.main()
