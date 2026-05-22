`timescale 1ns/1ps

// Simple 8N1 UART receiver.
//
// CLKS_PER_BIT should be the input clock frequency divided by the baud rate.
// For the DE10-Lite 50 MHz clock at 115200 baud, use 434.

module uart_rx #(
    parameter int CLKS_PER_BIT = 434
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       rx_serial,

    output logic [7:0] rx_data,
    output logic       rx_data_valid,
    output logic       rx_busy,
    output logic       framing_error
);

    localparam int COUNT_WIDTH = $clog2(CLKS_PER_BIT + 1);

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_START,
        STATE_DATA,
        STATE_STOP
    } state_t;

    state_t state;
    logic [COUNT_WIDTH-1:0] clk_count;
    logic [2:0] bit_index;
    logic [7:0] rx_shift;
    logic rx_meta;
    logic rx_sync;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= rx_serial;
            rx_sync <= rx_meta;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            clk_count <= '0;
            bit_index <= 3'd0;
            rx_shift <= 8'h00;
            rx_data <= 8'h00;
            rx_data_valid <= 1'b0;
            rx_busy <= 1'b0;
            framing_error <= 1'b0;
        end else begin
            rx_data_valid <= 1'b0;
            framing_error <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    rx_busy <= 1'b0;
                    clk_count <= '0;
                    bit_index <= 3'd0;

                    if (!rx_sync) begin
                        rx_busy <= 1'b1;
                        state <= STATE_START;
                    end
                end

                STATE_START: begin
                    rx_busy <= 1'b1;

                    if (clk_count == ((CLKS_PER_BIT - 1) / 2)) begin
                        clk_count <= '0;
                        if (!rx_sync) begin
                            state <= STATE_DATA;
                        end else begin
                            state <= STATE_IDLE;
                        end
                    end else begin
                        clk_count <= clk_count + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end
                end

                STATE_DATA: begin
                    rx_busy <= 1'b1;

                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= '0;
                        rx_shift[bit_index] <= rx_sync;

                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            state <= STATE_STOP;
                        end else begin
                            bit_index <= bit_index + 3'd1;
                        end
                    end else begin
                        clk_count <= clk_count + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end
                end

                STATE_STOP: begin
                    rx_busy <= 1'b1;

                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= '0;
                        rx_data <= rx_shift;
                        rx_data_valid <= rx_sync;
                        framing_error <= !rx_sync;
                        rx_busy <= 1'b0;
                        state <= STATE_IDLE;
                    end else begin
                        clk_count <= clk_count + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end
                end

                default: begin
                    state <= STATE_IDLE;
                    clk_count <= '0;
                    bit_index <= 3'd0;
                    rx_busy <= 1'b0;
                end
            endcase
        end
    end

endmodule
