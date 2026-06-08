# Sparse Matrix Accelerator Project Report

## Project Function

The goal of this project was to demonstrate fixed-size, non-systolic matrix
multiplication on the DE10-Lite FPGA board using a sparse multiplier core. The
original target was a fixed 4x4 design in which the sparse weight matrix was
known at synthesis time. The final implementation exceeded that goal by
supporting runtime-configurable sparse matrix multiplication over a UART link
between a laptop and the FPGA board.

The implemented accelerator computes:

```text
C[M x N] = A_sparse[M x K] * B_dense[K x N]
```

The sparse matrix `A` uses 2:4 structured sparsity, meaning that every group of
four columns contains two stored nonzero weights and two stored column indices.
The dense input matrix `B` is streamed from the host computer. The output matrix
`C` is returned to the host as tagged row/column/value entries.

The design is non-systolic. It does not use a grid of processing elements that
wave data through the array. Instead, it uses a streaming column-at-a-time
datapath: the FPGA receives one dense `B` column, accumulates one output `C`
column across all active sparse rows, and streams the resulting values back
through the UART controller.

## Main Components

The project has two main hardware components:

1. The UART board controller, which manages communication between the laptop
   and the DE10-Lite FPGA board.
2. The sparse multiplication core, which performs the actual matrix
   multiplication using the runtime-configured 2:4 sparse weights.

The board-level top module connects the UART receiver, UART transmitter, packet
controller, and sparse matrix core. The data path is:

```text
Laptop
  -> USB-UART adapter
  -> uart_rx
  -> matrix_uart_controller
  -> sparse_matmul_4x4_streaming
  -> matrix_uart_controller
  -> uart_tx
  -> USB-UART adapter
  -> Laptop
```

The software side includes Python host scripts that serialize sparse weight
configuration packets, serialize dense activation matrices, read FPGA
acknowledgments, decode tagged result packets, and reconstruct the final output
matrix.

## UART Controller

The UART controller is responsible for turning a byte stream into meaningful
matrix operations. Each byte is transported with standard 8N1 UART framing: one
start bit, eight data bits, and one stop bit. The baud rate is determined by the
board clock frequency divided by the `CLKS_PER_BIT` parameter. With the DE10-Lite
50 MHz clock and `CLKS_PER_BIT = 434`, the design operates at approximately
115200 baud.

The controller recognizes two host-to-FPGA packet types:

```text
0xA0  sparse weight configuration packet
0xAA  dense B matrix packet
```

It can return three single-byte control messages:

```text
0x5A  sparse weight configuration accepted
0xAC  dense matrix accepted into the waiting room
0xEE  dense matrix rejected because the waiting room was full
```

It also returns result packets beginning with:

```text
0x55
```

### Sparse Weight Configuration Packet

The sparse weight configuration packet initializes or updates the sparse matrix
`A`. Its format is:

```text
0xA0
M uint8
K uint8
N uint8
M * (K/4) sparse records
```

Each sparse record describes one row and one 4-column group of the sparse
matrix. Each record contains:

```text
weight0 int16, little-endian
weight1 int16, little-endian
index0  uint8, low two bits used
index1  uint8, low two bits used
```

Records are sent in row-major group order:

```text
for row in 0..M-1:
  for group in 0..(K/4)-1:
    send sparse record(row, group)
```

The FPGA only accepts configuration packets while the controller is idle. This
prevents a queued dense matrix from being multiplied using one set of weights
for part of the computation and a different set of weights for another part.
After the final sparse record is received, the FPGA updates the active
dimensions and returns `0x5A`.

### Dense Matrix Packet

The dense matrix packet sends the runtime dense input matrix `B`. Its format is:

```text
0xAA
K * N signed int16 values, little-endian
```

The packet does not contain `K` or `N`; those dimensions come from the active
configuration. Therefore, the host and FPGA must agree on the active dimensions
before the matrix packet is sent.

Dense matrix values are sent column-major:

```text
for col in 0..N-1:
  for k in 0..K-1:
    send B[k][col]
```

This ordering is important because it allows the core to start computing
`C[:, col]` as soon as one full dense input column is available. The FPGA does
not need to buffer the entire dense matrix before beginning computation.

When a dense matrix packet begins, the controller checks whether the waiting
room is full. If space is available, the controller reserves a slot and returns
`0xAC`. If the waiting room is full, it returns `0xEE`. Even rejected matrices
are fully consumed from the UART stream so that the next packet remains aligned.

### Result Packet

After the core produces output values, the controller returns a result packet:

```text
0x55
M uint8
N uint8
M * N tagged result entries
```

Each tagged result entry contains:

```text
row   uint8
col   uint8
value signed int64, little-endian
```

The row and column tags allow the host to reconstruct the result matrix without
depending on an implicit output order. The core accumulator is narrower than 64
bits, but the UART controller sign-extends each result to a signed 64-bit value
before transmission.

## Sparse Matrix Core

The matrix core is parameterized by maximum dimensions:

```text
M_MAX = 4
MAX_K = 16
N_MAX = 4
```

The active dimensions `M`, `K`, and `N` are set by the runtime configuration
packet. The default reset configuration is `M=4`, `K=4`, and `N=4`.

Because of the 2:4 structured sparsity requirement, `K` must be a multiple of
four. Internally, the core treats every four adjacent `K` entries as one sparse
group. For each active row and group, the core stores two weights and two 2-bit
indices. The default sparse weight matrix is:

```text
[ 3,  0, 0, 2]
[ 4,  5, 0, 0]
[ 0, -7, 6, 0]
[ 8,  0, 0, 4]
```

This representation stores only the nonzero values and their positions inside
each 4-wide group. For example, the first row stores weights `3` and `2` with
indices `0` and `3`.

## Internal Computation

The dense matrix `B` is received one column at a time. For one output column,
the core performs three phases:

1. Load `K` dense input values into the `dense_column` buffer.
2. Accumulate sparse products into one accumulator per active output row.
3. Stream out one tagged result per active row.

For each sparse group, the core selects two of the four dense input values using
the stored indices:

```text
product0 = weight0[row][group] * dense_column[group*4 + index0[row][group]]
product1 = weight1[row][group] * dense_column[group*4 + index1[row][group]]
```

The two products are added into the row accumulator. After all active groups
have been processed, the accumulator for each active row contains one output
element:

```text
C[row][col]
```

The effective loop ordering is:

```text
for col in 0..N-1:
  receive B[0..K-1][col]

  for group_base in 0..K/4 step SPARSE_GROUPS_PER_CYCLE:
    for row in 0..M-1:
      for lane in 0..SPARSE_GROUPS_PER_CYCLE-1:
        group = group_base + lane
        accumulate sparse group contribution

  for row in 0..M-1:
    emit C[row][col]
```

`SPARSE_GROUPS_PER_CYCLE` controls how many 4-wide sparse groups are processed
per clock cycle. Increasing this parameter increases parallelism and reduces
compute cycles, but it also increases multiplier and mux resource usage.

`M_TILE` and `N_TILE` are exposed as parameters in the current top-level design,
but the present core does not use them to drive a separate tiling schedule. The
actual implemented schedule is one full dense input column at a time, across
all active rows up to `M_MAX`.

## Buffering and Waiting Room

The UART controller contains a value FIFO sized to hold multiple maximum-size
dense matrix packets. This FIFO allows the host to send matrices faster than
the core consumes them for short bursts. The controller tracks how many matrices
have been accepted but not fully returned to the host. This count implements
the waiting room.

The current design also includes result buffering in the controller. This
allows the sparse core to hand off results to a FIFO while the UART transmitter
slowly drains result bytes back to the host. This improves decoupling between
the fast FPGA compute clock and the much slower UART byte stream.

The main throughput bottleneck is UART result transmission. For a 4x4 output,
the result packet contains:

```text
3 header bytes + 16 entries * 10 bytes/entry = 163 bytes
```

At approximately 115200 baud, the UART link is much slower than the internal
matrix computation. The accelerator core completes computation in microseconds,
while UART transfer time is measured in milliseconds.

## Verification

The project includes several testbenches and software tests:

```text
rtl_combinational/tb_sparse_matmul_4x4.sv
rtl_sequential/tb_sparse_matmul_4x4_streaming.sv
rtl_board/tb_de10_lite_uart_top.sv
test_reference_model.py
test_prune_2_of_4.py
test_host_uart_packet.py
test_host_weights_uart_packet.py
```

The Python tests verify matrix multiplication reference behavior, 2:4 pruning,
host packet construction, packet decoding, and sparse weight packet formatting.
The SystemVerilog testbenches verify the combinational proof-of-concept core,
the streaming sparse matrix core, and the DE10-Lite UART wrapper.

## Conclusion

The final design demonstrates a complete sparse matrix acceleration flow on the
DE10-Lite FPGA board. The original goal was a fixed 4x4 sparse multiplication
demo with synthesis-time weights. The completed system goes beyond that by
supporting runtime sparse weight configuration, runtime matrix dimensions up to
the configured hardware limits, queued dense matrix transfers, tagged output
packets, and host-side reconstruction of results.

The most important design decision was streaming dense input columns in
column-major order. This reduced buffering requirements and allowed the core to
begin producing output columns before the entire dense matrix had arrived. The
main limitation is UART bandwidth, especially the size of the result packet.
Future improvements could reduce result packet size, increase UART baud rate,
or replace UART with a faster communication interface.
