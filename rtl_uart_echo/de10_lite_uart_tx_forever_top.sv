`timescale 1ns/1ps

// Minimal DE10-Lite UART TX-only top.
//
// Continuously transmits ASCII 'U' (0x55) forever. This isolates the FPGA-to-PC
// UART direction so you can verify the uart_tx pin assignment and adapter RXD
// wiring without depending on any receive-side logic.

module de10_lite_uart_tx_forever_top #(
    parameter int CLKS_PER_BIT = 434,
    parameter logic [7:0] TX_BYTE = 8'h55
) (
    input  logic       MAX10_CLK1_50,
    input  logic [1:0] KEY,
    output logic       uart_tx,
    output logic [9:0] LEDR
);

    logic clk;
    logic rst_n;
    logic [1:0] reset_sync;

    logic [7:0] tx_data;
    logic tx_start;
    logic tx_busy;
    logic tx_done;

    assign clk = MAX10_CLK1_50;

    always_ff @(posedge clk or negedge KEY[0]) begin
        if (!KEY[0]) begin
            reset_sync <= 2'b00;
        end else begin
            reset_sync <= {reset_sync[0], 1'b1};
        end
    end

    assign rst_n = reset_sync[1];

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
            tx_data <= TX_BYTE;
            tx_start <= 1'b0;
        end else begin
            tx_data <= TX_BYTE;
            tx_start <= !tx_busy;
        end
    end

    assign LEDR[0] = rst_n;
    assign LEDR[1] = tx_start;
    assign LEDR[2] = tx_busy;
    assign LEDR[3] = tx_done;
    assign LEDR[9:4] = 6'b000000;

endmodule
