# DE10-Lite UART Echo Test

This folder contains a minimal UART echo design for the DE10-Lite. Any byte
received on `uart_rx` is sent straight back out on `uart_tx`.

Use it to answer a very focused question:

```text
Does the USB-UART bridge + FPGA pin assignment + board wiring work at all?
```

## Files

```text
rtl_uart_echo/de10_lite_uart_echo_top.sv
rtl_uart_echo/uart_rx.sv
rtl_uart_echo/uart_tx.sv
rtl_uart_echo/tb_de10_lite_uart_echo_top.sv
```

Set `de10_lite_uart_echo_top` as the Quartus top-level entity for this test.

## Board Wiring

Use an external 3.3 V TTL USB-UART adapter:

```text
USB-UART TXD -> FPGA uart_rx pin
USB-UART RXD -> FPGA uart_tx pin
USB-UART GND -> DE10-Lite GND
```

Leave adapter `VCC` unconnected.

## Suggested Assignments

If you are using the same pins as the matrix/UART design:

```tcl
set_location_assignment PIN_V10 -to uart_rx
set_location_assignment PIN_W10 -to uart_tx
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to uart_rx
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to uart_tx
```

## LED Meaning

```text
LEDR[0]   reset released
LEDR[1]   rx_data_valid pulse
LEDR[2]   UART RX busy
LEDR[3]   tx_start pulse
LEDR[4]   UART TX busy
LEDR[5]   UART TX done pulse
LEDR[6]   a received byte is waiting to be echoed
LEDR[7]   UART framing error
LEDR[8]   last_rx_byte bit 0
LEDR[9]   last_rx_byte bit 1
```

## Simulation

From the repo root:

```sh
iverilog -g2012 -Wall -o /private/tmp/uart_echo_tb.vvp \
  rtl_uart_echo/tb_de10_lite_uart_echo_top.sv \
  rtl_uart_echo/de10_lite_uart_echo_top.sv \
  rtl_uart_echo/uart_rx.sv \
  rtl_uart_echo/uart_tx.sv

vvp /private/tmp/uart_echo_tb.vvp
```

## Windows Loopback Check

After programming the FPGA, you can test from PowerShell:

```powershell
python -c "import serial; s=serial.Serial('COM7',115200,timeout=2,write_timeout=2); s.write(b'ABC'); print(s.read(3)); s.close()"
```

Expected output:

```text
b'ABC'
```
