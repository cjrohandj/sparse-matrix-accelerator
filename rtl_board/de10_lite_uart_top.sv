`timescale 1ns/1ps

// DE10-Lite board top for streaming dense matrix B to the sparse matmul core
// over an external 3.3 V USB-UART adapter.
//
// Suggested wiring:
//   USB-UART TXD -> FPGA uart_rx pin
//   USB-UART RXD -> FPGA uart_tx pin
//   USB-UART GND -> DE10-Lite GND
//
// Suggested Quartus setup:
//   - Set this module as the top-level entity.
//   - Assign MAX10_CLK1_50 to the DE10-Lite 50 MHz clock pin.
//   - Assign KEY[0] to pushbutton KEY0; it is used as active-low reset.
//   - Assign uart_rx and uart_tx to the GPIO/Arduino pins you wire to.
//   - Use 3.3-V LVTTL for uart_rx and uart_tx.

module de10_lite_uart_top #(
    parameter int DATA_WIDTH = 16,
    parameter int ACC_WIDTH = (2 * DATA_WIDTH) + 1,
    parameter int CLKS_PER_BIT = 434,

    parameter logic signed [DATA_WIDTH-1:0] ROW0_WEIGHT0 = 16'sd3,
    parameter logic signed [DATA_WIDTH-1:0] ROW0_WEIGHT1 = 16'sd2,
    parameter logic [1:0] ROW0_INDEX0 = 2'd0,
    parameter logic [1:0] ROW0_INDEX1 = 2'd3,

    parameter logic signed [DATA_WIDTH-1:0] ROW1_WEIGHT0 = 16'sd4,
    parameter logic signed [DATA_WIDTH-1:0] ROW1_WEIGHT1 = 16'sd5,
    parameter logic [1:0] ROW1_INDEX0 = 2'd0,
    parameter logic [1:0] ROW1_INDEX1 = 2'd1,

    parameter logic signed [DATA_WIDTH-1:0] ROW2_WEIGHT0 = -16'sd7,
    parameter logic signed [DATA_WIDTH-1:0] ROW2_WEIGHT1 = 16'sd6,
    parameter logic [1:0] ROW2_INDEX0 = 2'd1,
    parameter logic [1:0] ROW2_INDEX1 = 2'd2,

    parameter logic signed [DATA_WIDTH-1:0] ROW3_WEIGHT0 = 16'sd8,
    parameter logic signed [DATA_WIDTH-1:0] ROW3_WEIGHT1 = 16'sd4,
    parameter logic [1:0] ROW3_INDEX0 = 2'd0,
    parameter logic [1:0] ROW3_INDEX1 = 2'd3
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

    logic signed [DATA_WIDTH-1:0] core_in_data;
    logic core_in_valid;
    logic core_in_ready;
    logic signed [ACC_WIDTH-1:0] core_out_data;
    logic [1:0] core_out_row;
    logic [1:0] core_out_col;
    logic core_out_valid;
    logic core_out_ready;
    logic core_busy;

    logic controller_busy;
    logic matrix_loaded_pulse;
    logic result_sent_pulse;
    logic [3:0] controller_state;

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

    matrix_uart_controller #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) controller_inst (
        .clk(clk),
        .rst_n(rst_n),
        .rx_data(rx_data),
        .rx_data_valid(rx_data_valid),
        .tx_data(tx_data),
        .tx_start(tx_start),
        .tx_busy(tx_busy),
        .core_in_data(core_in_data),
        .core_in_valid(core_in_valid),
        .core_in_ready(core_in_ready),
        .core_out_data(core_out_data),
        .core_out_valid(core_out_valid),
        .core_out_ready(core_out_ready),
        .busy(controller_busy),
        .matrix_loaded_pulse(matrix_loaded_pulse),
        .result_sent_pulse(result_sent_pulse),
        .debug_state(controller_state)
    );

    sparse_matmul_4x4_streaming #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .ROW0_WEIGHT0(ROW0_WEIGHT0),
        .ROW0_WEIGHT1(ROW0_WEIGHT1),
        .ROW0_INDEX0(ROW0_INDEX0),
        .ROW0_INDEX1(ROW0_INDEX1),
        .ROW1_WEIGHT0(ROW1_WEIGHT0),
        .ROW1_WEIGHT1(ROW1_WEIGHT1),
        .ROW1_INDEX0(ROW1_INDEX0),
        .ROW1_INDEX1(ROW1_INDEX1),
        .ROW2_WEIGHT0(ROW2_WEIGHT0),
        .ROW2_WEIGHT1(ROW2_WEIGHT1),
        .ROW2_INDEX0(ROW2_INDEX0),
        .ROW2_INDEX1(ROW2_INDEX1),
        .ROW3_WEIGHT0(ROW3_WEIGHT0),
        .ROW3_WEIGHT1(ROW3_WEIGHT1),
        .ROW3_INDEX0(ROW3_INDEX0),
        .ROW3_INDEX1(ROW3_INDEX1)
    ) sparse_core_inst (
        .clk(clk),
        .rst_n(rst_n),
        .in_data(core_in_data),
        .in_valid(core_in_valid),
        .in_ready(core_in_ready),
        .out_data(core_out_data),
        .out_row(core_out_row),
        .out_col(core_out_col),
        .out_valid(core_out_valid),
        .out_ready(core_out_ready),
        .busy(core_busy)
    );

    assign LEDR[0] = rst_n;
    assign LEDR[1] = controller_busy;
    assign LEDR[2] = rx_data_valid;
    assign LEDR[3] = tx_busy;
    assign LEDR[4] = core_busy;
    assign LEDR[8:5] = controller_state;
    assign LEDR[9] = rx_framing_error;

endmodule
