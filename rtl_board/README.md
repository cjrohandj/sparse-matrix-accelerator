# DE10-Lite USB-UART Wrapper

This folder contains a board-level UART path for sending one dense 4x4 matrix
from a computer to the FPGA and reading the 4x4 sparse matmul result back.

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
16 signed int16 values, row-major, little-endian
```

FPGA to host:

```text
0x55
16 signed int64 values, row-major, little-endian
```

The hardware core produces 33-bit signed results for the default 16-bit input
width. The UART wrapper sign-extends each result to 64 bits before sending it.

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

```text
LEDR[0]   reset released
LEDR[1]   packet/controller busy
LEDR[2]   received UART byte pulse
LEDR[3]   UART TX busy
LEDR[4]   sparse core busy
LEDR[8:5] controller state
LEDR[9]   UART framing error pulse
```

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

After programming the FPGA, use `host/send_matrix_uart.py` to send a matrix
from the computer and print the returned result. See `host/README.md` for
examples.
