# Host UART Script

`send_matrix_uart.py` sends one 4x4 signed-int16 matrix to the DE10-Lite UART
top and prints the returned 4x4 signed-int64 result.

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

Parse matrix text from a file or from output shaped like `prune_2_of_4.py`:

```sh
python3 host/send_matrix_uart.py \
  --port /dev/tty.usbserial-XXXX \
  --file matrix.txt \
  --label "Pruned weights"
```

The FPGA protocol is:

```text
PC -> FPGA: 0xAA + 16 signed int16 values, row-major, little-endian
FPGA -> PC: 0x55 + 16 signed int64 values, row-major, little-endian
```
