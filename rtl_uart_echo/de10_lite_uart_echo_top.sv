`timescale 1ns/1ps

// Minimal DE10-Lite UART loopback top.
//
// Any UART byte received on uart_rx is echoed back on uart_tx. This is useful
// for checking the USB-UART bridge, FPGA pin assignments, and board wiring
// without involving the sparse-matmul datapath.

module de10_lite_uart_echo_top #(
    parameter int CLKS_PER_BIT = 434
) (
    input  logic       MAX10_CLK1_50,
    input  logic [1:0] KEY,
    input  logic       uart_rx,
    output logic       uart_tx,
    output logic [9:0] LEDR
);

    logic clk;
    logic rst_n;
    logic [1:0] reset_sync;

    logic [7:0] rx_data;
    logic rx_data_valid;
    logic rx_busy;
    logic rx_framing_error;

    logic [7:0] tx_data;
    logic tx_start;
    logic tx_busy;
    logic tx_done;

    logic [7:0] last_rx_byte;
    logic [7:0] pending_tx_byte;
    logic pending_tx_valid;

    assign clk = MAX10_CLK1_50;

    always_ff @(posedge clk or negedge KEY[0]) begin
        if (!KEY[0]) begin
            reset_sync <= 2'b00;
        end else begin
            reset_sync <= {reset_sync[0], 1'b1};
        end
    end

    assign rst_n = reset_sync[1];

    uart_rx #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) uart_rx_inst (
        .clk(clk),
        .rst_n(rst_n),
        .rx_serial(uart_rx),
        .rx_data(rx_data),
        .rx_data_valid(rx_data_valid),
        .rx_busy(rx_busy),
        .framing_error(rx_framing_error)
    );

    uart_tx #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) uart_tx_inst (
        .clk(clk),
        .rst_n(rst_n),
        .tx_data(tx_data),
        .tx_start(tx_start),
        .tx_serial(uart_tx),
        .tx_busy(tx_busy),
        .tx_done(tx_done)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_rx_byte <= 8'h00;
            pending_tx_byte <= 8'h00;
            pending_tx_valid <= 1'b0;
            tx_data <= 8'h00;
            tx_start <= 1'b0;
        end else begin
            tx_start <= 1'b0;

            if (rx_data_valid) begin
                last_rx_byte <= rx_data;
                pending_tx_byte <= rx_data;
                pending_tx_valid <= 1'b1;
            end

            if (pending_tx_valid && !tx_busy) begin
                tx_data <= pending_tx_byte;
                tx_start <= 1'b1;
                pending_tx_valid <= 1'b0;
            end
        end
    end

    assign LEDR[0] = rst_n;
    assign LEDR[1] = rx_data_valid;
    assign LEDR[2] = rx_busy;
    assign LEDR[3] = tx_start;
    assign LEDR[4] = tx_busy;
    assign LEDR[5] = tx_done;
    assign LEDR[6] = pending_tx_valid;
    assign LEDR[7] = rx_framing_error;
    assign LEDR[8] = last_rx_byte[0];
    assign LEDR[9] = last_rx_byte[1];

endmodule
