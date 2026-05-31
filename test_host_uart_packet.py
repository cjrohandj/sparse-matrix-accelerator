import struct
import unittest

from host.send_matrix_uart import (
    MATRIX_ACK_BYTE,
    MATRIX_NACK_BYTE,
    REQUEST_START_BYTE,
    RESPONSE_START_BYTE,
    build_request_packet,
    build_request_packets,
    decode_matrix_ack,
    decode_response_packet,
    parse_matrix_sequence_text,
    parse_matrix_text,
    _read_acknowledged_results,
)


class FakeSerial:
    def __init__(self, data: bytes) -> None:
        self.data = bytearray(data)

    def read(self, byte_count: int) -> bytes:
        chunk = self.data[:byte_count]
        del self.data[:byte_count]
        return bytes(chunk)


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
        expected_values = [1, 5, 9, 13, -2, 6, 10, 14, 3, 7, 11, 15, -4, 8, 12, -16]
        self.assertEqual(packet[1:], struct.pack("<16h", *expected_values))

    def test_builds_k8_dense_matrix_request(self) -> None:
        matrix = [
            [1, 2, 3, 4],
            [5, 6, 7, 8],
            [9, 10, 11, 12],
            [13, 14, 15, 16],
            [17, 18, 19, 20],
            [21, 22, 23, 24],
            [25, 26, 27, 28],
            [29, 30, 31, 32],
        ]

        packet = build_request_packet(matrix)

        self.assertEqual(packet[0], REQUEST_START_BYTE)
        self.assertEqual(len(packet), 65)
        expected_values = [
            1, 5, 9, 13, 17, 21, 25, 29,
            2, 6, 10, 14, 18, 22, 26, 30,
            3, 7, 11, 15, 19, 23, 27, 31,
            4, 8, 12, 16, 20, 24, 28, 32,
        ]
        self.assertEqual(packet[1:], struct.pack("<32h", *expected_values))

    def test_builds_activation_sequence_packets(self) -> None:
        matrices = [
            [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12], [13, 14, 15, 16]],
            [[2, 4, 6, 8], [10, 12, 14, 16], [18, 20, 22, 24], [26, 28, 30, 32]],
        ]

        packets = build_request_packets(matrices)

        self.assertEqual(len(packets), 2)
        self.assertEqual(packets[0][0], REQUEST_START_BYTE)
        expected_values = [2, 10, 18, 26, 4, 12, 20, 28, 6, 14, 22, 30, 8, 16, 24, 32]
        self.assertEqual(packets[1][1:], struct.pack("<16h", *expected_values))

    def test_parses_activation_sequence_literal(self) -> None:
        text = "[[[1,2,3,4],[5,6,7,8],[9,10,11,12],[13,14,15,16]]]"

        self.assertEqual(
            parse_matrix_sequence_text(text),
            [[[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12], [13, 14, 15, 16]]],
        )

    def test_decodes_little_endian_int64_response(self) -> None:
        values = list(range(-8, 8))
        entries = b"".join(
            bytes([index // 4, index % 4]) + struct.pack("<q", value)
            for index, value in enumerate(values)
        )
        packet = bytes([RESPONSE_START_BYTE, 4, 4]) + entries

        self.assertEqual(
            decode_response_packet(packet),
            [
                [-8, -7, -6, -5],
                [-4, -3, -2, -1],
                [0, 1, 2, 3],
                [4, 5, 6, 7],
            ],
        )

    def test_decodes_tagged_mxn_response(self) -> None:
        entries = b"".join(
            bytes([row, col]) + struct.pack("<q", (row * 5) + col + 1)
            for col in range(5)
            for row in range(3)
        )
        packet = bytes([RESPONSE_START_BYTE, 3, 5]) + entries

        self.assertEqual(
            decode_response_packet(packet),
            [
                [1, 2, 3, 4, 5],
                [6, 7, 8, 9, 10],
                [11, 12, 13, 14, 15],
            ],
        )

    def test_reads_interleaved_ack_and_result_messages(self) -> None:
        def response(value: int) -> bytes:
            return (
                bytes([RESPONSE_START_BYTE, 1, 1])
                + bytes([0, 0])
                + struct.pack("<q", value)
            )

        serial = FakeSerial(
            bytes([MATRIX_ACK_BYTE])
            + response(7)
            + bytes([MATRIX_ACK_BYTE])
            + response(9)
        )

        self.assertEqual(_read_acknowledged_results(serial, 2), [[[7]], [[9]]])

    def test_decodes_waiting_room_ack(self) -> None:
        self.assertIsNone(decode_matrix_ack(bytes([MATRIX_ACK_BYTE])))

    def test_rejects_waiting_room_nack(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "waiting room rejected"):
            decode_matrix_ack(bytes([MATRIX_NACK_BYTE]))

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
