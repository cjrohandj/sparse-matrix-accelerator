`timescale 1ns/1ps

// Packet controller for the 4x4 sparse matrix accelerator UART demo.
//
// Host request packet:
//   0xAA
//   16 signed int16 values for dense B, row-major, little-endian
//
// FPGA response packet:
//   0x55
//   16 signed int64 values for C, row-major, little-endian
//
// The accelerator's native ACC_WIDTH result is sign-extended to 64 bits before
// serialization so host software can decode every result as a normal int64.

module matrix_uart_controller #(
    parameter int DATA_WIDTH = 16,
    parameter int ACC_WIDTH = (2 * DATA_WIDTH) + 1,
    parameter int RESULT_WIDTH = 64,
    parameter logic [7:0] REQUEST_START_BYTE = 8'hAA,
    parameter logic [7:0] RESPONSE_START_BYTE = 8'h55
) (
    input  logic clk,
    input  logic rst_n,

    input  logic [7:0] rx_data,
    input  logic       rx_data_valid,

    output logic [7:0] tx_data,
    output logic       tx_start,
    input  logic       tx_busy,

    output logic signed [DATA_WIDTH-1:0] core_in_data,
    output logic                         core_in_valid,
    input  logic                         core_in_ready,

    input  logic signed [ACC_WIDTH-1:0]  core_out_data,
    input  logic                         core_out_valid,
    output logic                         core_out_ready,

    output logic                         busy,
    output logic                         matrix_loaded_pulse,
    output logic                         result_sent_pulse,
    output logic [3:0]                   debug_state
);

    localparam int MATRIX_ELEMS = 16;
    localparam int RESULT_BYTES = RESULT_WIDTH / 8;

    typedef enum logic [3:0] {
        STATE_WAIT_START,
        STATE_RECV_LOW,
        STATE_RECV_HIGH,
        STATE_FEED_CORE,
        STATE_SEND_RESPONSE_START,
        STATE_WAIT_RESULT,
        STATE_SEND_RESULT
    } state_t;

    state_t state;
    logic signed [DATA_WIDTH-1:0] input_buffer [0:MATRIX_ELEMS-1];
    logic [7:0] rx_low_byte;
    logic [4:0] rx_value_index;
    logic [4:0] feed_index;
    logic [4:0] result_index;
    logic [3:0] result_byte_index;
    logic [RESULT_WIDTH-1:0] result_shift;
    logic signed [RESULT_WIDTH-1:0] result_extended;

    assign core_in_valid = (state == STATE_FEED_CORE);
    assign core_in_data = input_buffer[feed_index];
    assign core_out_ready = (state == STATE_WAIT_RESULT) && !tx_busy;

    assign tx_start = ((state == STATE_SEND_RESPONSE_START) ||
                       (state == STATE_SEND_RESULT)) && !tx_busy;
    assign tx_data = (state == STATE_SEND_RESPONSE_START) ?
        RESPONSE_START_BYTE :
        result_shift[7:0];

    assign busy = (state != STATE_WAIT_START);
    assign debug_state = state;

    assign result_extended = {{(RESULT_WIDTH-ACC_WIDTH){core_out_data[ACC_WIDTH-1]}}, core_out_data};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_WAIT_START;
            rx_low_byte <= 8'h00;
            rx_value_index <= 5'd0;
            feed_index <= 5'd0;
            result_index <= 5'd0;
            result_byte_index <= 4'd0;
            result_shift <= '0;
            matrix_loaded_pulse <= 1'b0;
            result_sent_pulse <= 1'b0;
        end else begin
            matrix_loaded_pulse <= 1'b0;
            result_sent_pulse <= 1'b0;

            case (state)
                STATE_WAIT_START: begin
                    rx_value_index <= 5'd0;
                    feed_index <= 5'd0;
                    result_index <= 5'd0;
                    result_byte_index <= 4'd0;

                    if (rx_data_valid && (rx_data == REQUEST_START_BYTE)) begin
                        state <= STATE_RECV_LOW;
                    end
                end

                STATE_RECV_LOW: begin
                    if (rx_data_valid) begin
                        rx_low_byte <= rx_data;
                        state <= STATE_RECV_HIGH;
                    end
                end

                STATE_RECV_HIGH: begin
                    if (rx_data_valid) begin
                        input_buffer[rx_value_index] <= {rx_data, rx_low_byte};

                        if (rx_value_index == 5'd15) begin
                            rx_value_index <= 5'd0;
                            feed_index <= 5'd0;
                            matrix_loaded_pulse <= 1'b1;
                            state <= STATE_FEED_CORE;
                        end else begin
                            rx_value_index <= rx_value_index + 5'd1;
                            state <= STATE_RECV_LOW;
                        end
                    end
                end

                STATE_FEED_CORE: begin
                    if (core_in_ready) begin
                        if (feed_index == 5'd15) begin
                            feed_index <= 5'd0;
                            result_index <= 5'd0;
                            state <= STATE_SEND_RESPONSE_START;
                        end else begin
                            feed_index <= feed_index + 5'd1;
                        end
                    end
                end

                STATE_SEND_RESPONSE_START: begin
                    if (!tx_busy) begin
                        result_index <= 5'd0;
                        result_byte_index <= 4'd0;
                        state <= STATE_WAIT_RESULT;
                    end
                end

                STATE_WAIT_RESULT: begin
                    if (core_out_valid && core_out_ready) begin
                        result_shift <= result_extended;
                        result_byte_index <= 4'd0;
                        state <= STATE_SEND_RESULT;
                    end
                end

                STATE_SEND_RESULT: begin
                    if (!tx_busy) begin
                        if (result_byte_index == (RESULT_BYTES - 1)) begin
                            result_byte_index <= 4'd0;

                            if (result_index == 5'd15) begin
                                result_index <= 5'd0;
                                result_sent_pulse <= 1'b1;
                                state <= STATE_WAIT_START;
                            end else begin
                                result_index <= result_index + 5'd1;
                                state <= STATE_WAIT_RESULT;
                            end
                        end else begin
                            result_shift <= {{8{1'b0}}, result_shift[RESULT_WIDTH-1:8]};
                            result_byte_index <= result_byte_index + 4'd1;
                        end
                    end
                end

                default: begin
                    state <= STATE_WAIT_START;
                    rx_value_index <= 5'd0;
                    feed_index <= 5'd0;
                    result_index <= 5'd0;
                    result_byte_index <= 4'd0;
                end
            endcase
        end
    end

endmodule
