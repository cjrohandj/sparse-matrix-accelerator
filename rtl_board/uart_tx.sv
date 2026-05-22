`timescale 1ns/1ps

// Simple 8N1 UART transmitter.
//
// tx_start is sampled when tx_busy is low. Data is transmitted LSB first.

module uart_tx #(
    parameter int CLKS_PER_BIT = 434
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [7:0] tx_data,
    input  logic       tx_start,

    output logic       tx_serial,
    output logic       tx_busy,
    output logic       tx_done
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
    logic [7:0] tx_shift;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
            clk_count <= '0;
            bit_index <= 3'd0;
            tx_shift <= 8'h00;
            tx_serial <= 1'b1;
            tx_busy <= 1'b0;
            tx_done <= 1'b0;
        end else begin
            tx_done <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    tx_serial <= 1'b1;
                    tx_busy <= 1'b0;
                    clk_count <= '0;
                    bit_index <= 3'd0;

                    if (tx_start) begin
                        tx_shift <= tx_data;
                        tx_busy <= 1'b1;
                        state <= STATE_START;
                    end
                end

                STATE_START: begin
                    tx_serial <= 1'b0;
                    tx_busy <= 1'b1;

                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= '0;
                        state <= STATE_DATA;
                    end else begin
                        clk_count <= clk_count + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end
                end

                STATE_DATA: begin
                    tx_serial <= tx_shift[bit_index];
                    tx_busy <= 1'b1;

                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= '0;
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
                    tx_serial <= 1'b1;
                    tx_busy <= 1'b1;

                    if (clk_count == (CLKS_PER_BIT - 1)) begin
                        clk_count <= '0;
                        tx_busy <= 1'b0;
                        tx_done <= 1'b1;
                        state <= STATE_IDLE;
                    end else begin
                        clk_count <= clk_count + {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end
                end

                default: begin
                    state <= STATE_IDLE;
                    clk_count <= '0;
                    bit_index <= 3'd0;
                    tx_serial <= 1'b1;
                    tx_busy <= 1'b0;
                end
            endcase
        end
    end

endmodule
