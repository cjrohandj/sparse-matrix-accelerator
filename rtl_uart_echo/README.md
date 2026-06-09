# DE10-Lite UART Echo Test

This folder contains two minimal UART test designs for the DE10-Lite:

- `de10_lite_uart_echo_top`: any received byte is echoed back
- `de10_lite_uart_tx_forever_top`: continuously transmits `0x55` (`'U'`)

Use it to answer a very focused question:

```text
Does the USB-UART bridge + FPGA pin assignment + board wiring work at all?
```

## Files

```text
rtl_uart_echo/de10_lite_uart_echo_top.sv
rtl_uart_echo/de10_lite_uart_tx_forever_top.sv
rtl_uart_echo/uart_rx.sv
rtl_uart_echo/uart_tx.sv
rtl_uart_echo/tb_de10_lite_uart_echo_top.sv
rtl_uart_echo/tb_de10_lite_uart_tx_forever_top.sv
```

Set one of these as the Quartus top-level entity, depending on the test:

- `de10_lite_uart_echo_top`
- `de10_lite_uart_tx_forever_top`

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

TX-only simulation:

```sh
iverilog -g2012 -Wall -o /private/tmp/uart_tx_forever_tb.vvp \
  rtl_uart_echo/tb_de10_lite_uart_tx_forever_top.sv \
  rtl_uart_echo/de10_lite_uart_tx_forever_top.sv \
  rtl_uart_echo/uart_tx.sv

vvp /private/tmp/uart_tx_forever_tb.vvp
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

## TX-Only Receive Test

After programming `de10_lite_uart_tx_forever_top`, the FPGA continuously sends
`0x55`, which appears as `'U'` on a serial terminal.

Mac / Linux:

```sh
python3 -c "import serial; s=serial.Serial('/dev/ttyUSB0',115200,timeout=2); print(s.read(32)); s.close()"
```

Windows:

```powershell
python -c "import serial; s=serial.Serial('COM4',115200,timeout=2); print(s.read(32)); s.close()"
```

If the PC-side receive path is working, you should see repeated `U` bytes such
as `b'UUUUUUUU...'`.
