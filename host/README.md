# Host UART Script

`send_matrix_uart.py` sends one KxN signed-int16 dense B matrix to the
DE10-Lite UART top, waits for the waiting-room acknowledgment, and prints the
returned MxN signed-int64 result.

`send_weights_uart.py` sends runtime sparse A weights and indices to the board.
It accepts the `Sparse values:` and `Sparse indices:` lines printed by
`prune_2_of_4.py`, infers M from the row count, infers K from the number of
4-column sparse groups, and includes runtime N from `--n` in the UART packet.

Hardware performance for larger K depends on the synthesis-time
`SPARSE_GROUPS_PER_CYCLE` parameter in `de10_lite_uart_top.sv`.

Install the serial dependency:

```sh
python3 -m pip install pyserial
```

List serial ports:

```sh
python3 host/send_matrix_uart.py --list-ports
```

Dry-run the built-in demo matrix without touching hardware:

```sh
python3 host/send_matrix_uart.py --demo --dry-run
```

Send the demo matrix to the FPGA:

```sh
python3 host/send_matrix_uart.py --demo --port /dev/tty.usbserial-XXXX
```

Send a matrix literal:

```sh
python3 host/send_matrix_uart.py \
  --port /dev/tty.usbserial-XXXX \
  --matrix '[[1,2,3,4],[5,6,7,8],[9,10,11,12],[13,14,15,16]]'
```

Benchmark board-level request/response latency and throughput over `N`
transactions:

```sh
python3 host/send_matrix_uart.py \
  --demo \
  --port /dev/tty.usbserial-XXXX \
  --benchmark 100
```

The benchmark reports:

- total time across all timed transactions
- average, minimum, and maximum per-transaction latency
- throughput in matrices per second

The reported statistics exclude the one-time serial-port open and initial
100 ms settle delay before the benchmark loop starts.

Exercise the FPGA waiting room by writing `N` copies back-to-back before
reading the result packets:

```sh
python3 host/send_matrix_uart.py \
  --demo \
  --port /dev/tty.usbserial-XXXX \
  --queued 2
```

Parse matrix text from a file or from output shaped like `prune_2_of_4.py`:

```sh
python3 host/send_matrix_uart.py \
  --port /dev/tty.usbserial-XXXX \
  --file matrix.txt \
  --label "Pruned weights"
```

Configure runtime sparse weights from `prune_2_of_4.py` output:

```sh
python3 prune_2_of_4.py | \
  python3 host/send_weights_uart.py --n 4 --port /dev/tty.usbserial-XXXX
```

Or let `prune_2_of_4.py` print a copy-paste command with your serial port:

```sh
python3 prune_2_of_4.py \
  --matrix '[[3,-1,0,2],[4,5,-2,1],[0,-7,6,2],[8,1,-3,4]]' \
  --n 4 \
  --serial-port /dev/tty.usbserial-XXXX
```

Build a copy-paste command for a sequence of activation matrices:

```sh
python3 host/make_activation_queue_command.py \
  --serial-port /dev/tty.usbserial-XXXX \
  --matrices '[[[1,2,3,4],[5,6,7,8],[9,10,11,12],[13,14,15,16]],[[2,4,6,8],[10,12,14,16],[18,20,22,24],[26,28,30,32]]]'
```

Dry-run the weight packet:

```sh
python3 prune_2_of_4.py | python3 host/send_weights_uart.py --dry-run
```

The dense B packet is serialized column-by-column so the FPGA can begin
accumulating the first output column before the full KxN activation matrix has
arrived. Result entries include row/column tags; `send_matrix_uart.py`
reconstructs the normal row-major MxN matrix after all tagged values arrive.
For queued activation matrices, ACK and result packets may be interleaved on
the UART stream; the script reads both message types until every queued matrix
has one ACK and one reconstructed result.

The FPGA protocol is:

```text
PC -> FPGA: 0xAA + K*N signed int16 values, column-major, little-endian
FPGA -> PC: 0xAC accepted into waiting room, or 0xEE waiting room full
FPGA -> PC: 0x55 + M uint8 + N uint8 + M*N tagged entries
             each entry is row uint8 + col uint8 + signed int64 value

PC -> FPGA: 0xA0 + M uint8 + K uint8 + N uint8 + M*(K/4) records
FPGA -> PC: 0x5A config acknowledgment
```
