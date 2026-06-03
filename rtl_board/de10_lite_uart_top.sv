`timescale 1ns/1ps

// DE10-Lite board top for streaming dense matrix B to the dense matmul core
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
    parameter int M_MAX = 4,
    parameter int MAX_K = 16,
    parameter int N_MAX = 4,
    parameter int M_TILE = 4,
    parameter int N_TILE = 4,
    parameter int GROUPS_PER_CYCLE_CFG = 1,
    parameter int ACC_WIDTH = (2 * DATA_WIDTH) + $clog2(MAX_K) + 1,
    parameter int CLKS_PER_BIT = 434,
    parameter int RESULT_START_IDLE_CYCLES = 1,

    parameter logic signed [DATA_WIDTH-1:0] ROW0_WEIGHT0 = 16'sd3,
    parameter logic signed [DATA_WIDTH-1:0] ROW0_WEIGHT1 = -16'sd1,
    parameter logic signed [DATA_WIDTH-1:0] ROW0_WEIGHT2 = 16'sd0,
    parameter logic signed [DATA_WIDTH-1:0] ROW0_WEIGHT3 = 16'sd2,

    parameter logic signed [DATA_WIDTH-1:0] ROW1_WEIGHT0 = 16'sd4,
    parameter logic signed [DATA_WIDTH-1:0] ROW1_WEIGHT1 = 16'sd5,
    parameter logic signed [DATA_WIDTH-1:0] ROW1_WEIGHT2 = -16'sd2,
    parameter logic signed [DATA_WIDTH-1:0] ROW1_WEIGHT3 = 16'sd1,

    parameter logic signed [DATA_WIDTH-1:0] ROW2_WEIGHT0 = 16'sd0,
    parameter logic signed [DATA_WIDTH-1:0] ROW2_WEIGHT1 = -16'sd7,
    parameter logic signed [DATA_WIDTH-1:0] ROW2_WEIGHT2 = 16'sd6,
    parameter logic signed [DATA_WIDTH-1:0] ROW2_WEIGHT3 = 16'sd2,

    parameter logic signed [DATA_WIDTH-1:0] ROW3_WEIGHT0 = 16'sd8,
    parameter logic signed [DATA_WIDTH-1:0] ROW3_WEIGHT1 = 16'sd1,
    parameter logic signed [DATA_WIDTH-1:0] ROW3_WEIGHT2 = -16'sd3,
    parameter logic signed [DATA_WIDTH-1:0] ROW3_WEIGHT3 = 16'sd4
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
    logic core_config_valid;
    logic [7:0] core_config_m;
    logic [7:0] core_config_k;
    logic [7:0] core_config_n;
    logic [7:0] core_config_row;
    logic [7:0] core_config_group;
    logic signed [DATA_WIDTH-1:0] core_config_weight0;
    logic signed [DATA_WIDTH-1:0] core_config_weight1;
    logic signed [DATA_WIDTH-1:0] core_config_weight2;
    logic signed [DATA_WIDTH-1:0] core_config_weight3;
    logic signed [ACC_WIDTH-1:0] core_out_data;
    logic [7:0] core_out_row;
    logic [7:0] core_out_col;
    logic core_out_valid;
    logic core_out_ready;
    logic core_busy;

    logic controller_busy;
    logic matrix_loaded_pulse;
    logic config_loaded_pulse;
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
        .M_MAX(M_MAX),
        .MAX_K(MAX_K),
        .N_MAX(N_MAX),
        .ACC_WIDTH(ACC_WIDTH),
        .RESULT_START_IDLE_CYCLES(RESULT_START_IDLE_CYCLES)
    ) controller_inst (
        .clk(clk),
        .rst_n(rst_n),
        .rx_data(rx_data),
        .rx_data_valid(rx_data_valid),
        .rx_busy(rx_busy),
        .tx_data(tx_data),
        .tx_start(tx_start),
        .tx_busy(tx_busy),
        .core_in_data(core_in_data),
        .core_in_valid(core_in_valid),
        .core_in_ready(core_in_ready),
        .core_config_valid(core_config_valid),
        .core_config_m(core_config_m),
        .core_config_k(core_config_k),
        .core_config_n(core_config_n),
        .core_config_row(core_config_row),
        .core_config_group(core_config_group),
        .core_config_weight0(core_config_weight0),
        .core_config_weight1(core_config_weight1),
        .core_config_weight2(core_config_weight2),
        .core_config_weight3(core_config_weight3),
        .core_out_data(core_out_data),
        .core_out_row(core_out_row),
        .core_out_col(core_out_col),
        .core_out_valid(core_out_valid),
        .core_out_ready(core_out_ready),
        .busy(controller_busy),
        .matrix_loaded_pulse(matrix_loaded_pulse),
        .config_loaded_pulse(config_loaded_pulse),
        .result_sent_pulse(result_sent_pulse),
        .debug_state(controller_state)
    );

    sparse_matmul_4x4_streaming #(
        .DATA_WIDTH(DATA_WIDTH),
        .M_MAX(M_MAX),
        .MAX_K(MAX_K),
        .N_MAX(N_MAX),
        .M_TILE(M_TILE),
        .N_TILE(N_TILE),
        .GROUPS_PER_CYCLE_CFG(GROUPS_PER_CYCLE_CFG),
        .ACC_WIDTH(ACC_WIDTH),
        .ROW0_WEIGHT0(ROW0_WEIGHT0),
        .ROW0_WEIGHT1(ROW0_WEIGHT1),
        .ROW0_WEIGHT2(ROW0_WEIGHT2),
        .ROW0_WEIGHT3(ROW0_WEIGHT3),
        .ROW1_WEIGHT0(ROW1_WEIGHT0),
        .ROW1_WEIGHT1(ROW1_WEIGHT1),
        .ROW1_WEIGHT2(ROW1_WEIGHT2),
        .ROW1_WEIGHT3(ROW1_WEIGHT3),
        .ROW2_WEIGHT0(ROW2_WEIGHT0),
        .ROW2_WEIGHT1(ROW2_WEIGHT1),
        .ROW2_WEIGHT2(ROW2_WEIGHT2),
        .ROW2_WEIGHT3(ROW2_WEIGHT3),
        .ROW3_WEIGHT0(ROW3_WEIGHT0),
        .ROW3_WEIGHT1(ROW3_WEIGHT1),
        .ROW3_WEIGHT2(ROW3_WEIGHT2),
        .ROW3_WEIGHT3(ROW3_WEIGHT3)
    ) sparse_core_inst (
        .clk(clk),
        .rst_n(rst_n),
        .in_data(core_in_data),
        .in_valid(core_in_valid),
        .in_ready(core_in_ready),
        .config_valid(core_config_valid),
        .config_m(core_config_m),
        .config_k(core_config_k),
        .config_n(core_config_n),
        .config_row(core_config_row),
        .config_group(core_config_group),
        .config_weight0(core_config_weight0),
        .config_weight1(core_config_weight1),
        .config_weight2(core_config_weight2),
        .config_weight3(core_config_weight3),
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
