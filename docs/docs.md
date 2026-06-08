Add these RTL files to the Quartus project:
## Quartus Files

Add these RTL files to the Quartus project:

```files
rtl_board/de10_lite_uart_top.sv
rtl_board/matrix_uart_controller.sv
rtl_board/uart_rx.sv
rtl_board/uart_tx.sv
rtl_sequential/sparse_matmul_4x4_streaming.sv
```
Set `de10_lite_uart_top` as the top-level entity.

On Quartus navigate to assignments, import assignments, select /quartus/de10_lite_uart_assignments.qsf 

Compile and program onto board.  


## Board Wiring

Use an external 3.3 V TTL USB-UART adapter:

```wiring
USB-UART TXD -> FPGA uart_rx pin
USB-UART RXD -> FPGA uart_tx pin
USB-UART GND -> DE10-Lite GND
```

Leave the adapter VCC unconnected. Power the DE10-Lite normally.


