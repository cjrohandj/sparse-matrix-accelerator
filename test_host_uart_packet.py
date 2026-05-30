import struct
import unittest

from host.send_matrix_uart import (
    REQUEST_START_BYTE,
    RESPONSE_START_BYTE,
    build_request_packet,
    decode_response_packet,
    parse_matrix_text,
)


class HostUartPacketTest(unittest.TestCase):
    def test_builds_little_endian_int16_request(self) -> None:
        matrix = [
            [1, -2, 3, -4],
            [5, 6, 7, 8],
            [9, 10, 11, 12],
            [13, 14, 15, -16],
        ]

        packet = build_request_packet(matrix)

        self.assertEqual(packet[0], REQUEST_START_BYTE)
        self.assertEqual(len(packet), 33)
        self.assertEqual(packet[1:], struct.pack("<16h", *sum(matrix, [])))

    def test_decodes_little_endian_int64_response(self) -> None:
        values = list(range(-8, 8))
        packet = bytes([RESPONSE_START_BYTE]) + struct.pack("<16q", *values)

        self.assertEqual(
            decode_response_packet(packet),
            [
                [-8, -7, -6, -5],
                [-4, -3, -2, -1],
                [0, 1, 2, 3],
                [4, 5, 6, 7],
            ],
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
            parse_matrix_text(text, label="Pruned weights"),
            [
                [3, 0, 0, 2],
                [4, 5, 0, 0],
                [0, -7, 6, 0],
                [8, 0, 0, 4],
            ],
        )


if __name__ == "__main__":
    unittest.main()
