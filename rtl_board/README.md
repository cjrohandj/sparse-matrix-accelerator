# DE10-Lite USB-UART Wrapper

This folder contains a board-level UART path for configuring an MxK 2:4 sparse
A matrix, queuing dense KxN B matrices from a computer to the FPGA, and
reading each MxN result back.

Data path:

```text
USB-UART RX pin
    -> uart_rx
    -> matrix_uart_controller
    -> sparse_matmul_4x4_streaming
    -> matrix_uart_controller
    -> uart_tx
    -> USB-UART TX pin
```

## Packet Format

Host to FPGA:

```text
0xAA
K*N signed int16 values, column-major, little-endian:
  for n in range(N):
    for k in range(K):
      send B[k][n]
```

Dense matrix acknowledgment from FPGA to host:

```text
0xAC accepted into the waiting room
0xEE rejected because the waiting room was full when the packet started
```

Runtime sparse A config from host to FPGA:

```text
0xA0
M uint8, where M <= M_MAX
K uint8, where K is a multiple of 4 and K <= MAX_K
N uint8, where N <= N_MAX
M*(K/4) sparse row/group records, each containing:
  weight0 int16, little-endian
  weight1 int16, little-endian
  index0 uint8
  index1 uint8
```

Config acknowledgment from FPGA to host:

```text
0x5A
```

FPGA to host:

```text
0x55
M uint8
N uint8
M*N tagged entries:
  row uint8
  col uint8
  value signed int64, little-endian
```

The default top-level capacity is `M_MAX=4`, `MAX_K=16`, and `N_MAX=4`.
The hardware core widens its accumulator for the configured maximum K, and the
UART wrapper sign-extends each result to 64 bits before sending it.

The dense matrix waiting room is a value FIFO in `matrix_uart_controller.sv`
with enough space for `MATRIX_FIFO_DEPTH` maximum-size KxN activation matrices.
The UART side ACKs a dense packet as soon as it reserves a waiting-room slot,
then pushes each int16 value toward `sparse_matmul_4x4_streaming` whenever the
core's `in_ready` signal is high. Runtime sparse weight config packets are only
accepted while the waiting room and result path are idle, so all queued dense
matrices use the currently configured K and weights.

Core outputs are buffered by a separate result FIFO in
`matrix_uart_controller.sv`, so the math core can hand off tagged results as
soon as queue space is available while `uart_tx` drains those entries in the
background.

The core accumulates one dense B column at a time. After each complete K-value
column arrives, it immediately emits that C column as tagged `(row, col, value)`
entries. Host software reconstructs the normal row-major MxN result from those
tags, so the packet no longer depends on an internal tile order.

`SPARSE_GROUPS_PER_CYCLE` is retained as a top-level compatibility parameter.
In this immediate-output core, B values arrive as 4-wide sparse groups within a
single output column, and the core updates the active column accumulators as
each group arrives:

```text
K=4   -> first C column can emit after 4 B values
K=8   -> first C column can emit after 8 B values
K=16  -> first C column can emit after 16 B values
```

The board-level latency is still usually dominated by UART byte time.

## Quartus Files

Add these RTL files to the Quartus project:

```text
rtl_board/de10_lite_uart_top.sv
rtl_board/matrix_uart_controller.sv
rtl_board/uart_rx.sv
rtl_board/uart_tx.sv
rtl_sequential/sparse_matmul_4x4_streaming.sv
```

Set `de10_lite_uart_top` as the top-level entity.

## Board Wiring

Use an external 3.3 V TTL USB-UART adapter:

```text
USB-UART TXD -> FPGA uart_rx pin
USB-UART RXD -> FPGA uart_tx pin
USB-UART GND -> DE10-Lite GND
```

Leave the adapter VCC unconnected. Power the DE10-Lite normally.

Assign `uart_rx` and `uart_tx` to whichever GPIO or Arduino header pins you
wire to, and use the `3.3-V LVTTL` I/O standard.

The default UART baud is 115200 when the top receives the DE10-Lite 50 MHz
clock:

```systemverilog
parameter int CLKS_PER_BIT = 434
```

## LED Status

With `KEY[1]` released/high, LEDs show the normal live UART status:

```text
LEDR[0]   reset released
LEDR[1]   packet/controller busy
LEDR[2]   received UART byte pulse
LEDR[3]   UART TX busy
LEDR[4]   sparse core busy
LEDR[8:5] controller state
LEDR[9]   UART framing error pulse
```

Hold `KEY[1]` low for the debug view:

```text
LEDR[7:0] last received UART byte
LEDR[8]   latched core_config_valid pulse seen
LEDR[9]   latched config_loaded_pulse seen
```

The two debug latch bits clear on reset (`KEY[0]`).

## Simulation

From the repo root:

```sh
iverilog -g2012 -Wall -o /private/tmp/de10_uart_tb.vvp \
  rtl_board/tb_de10_lite_uart_top.sv \
  rtl_board/de10_lite_uart_top.sv \
  rtl_board/matrix_uart_controller.sv \
  rtl_board/uart_rx.sv \
  rtl_board/uart_tx.sv \
  rtl_sequential/sparse_matmul_4x4_streaming.sv

vvp /private/tmp/de10_uart_tb.vvp
```

## Host Script

After programming the FPGA, use `host/send_weights_uart.py` to configure
runtime sparse A weights and `host/send_matrix_uart.py` to send dense B
matrices. See `host/README.md` for examples.
