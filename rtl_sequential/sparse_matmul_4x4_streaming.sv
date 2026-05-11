`timescale 1ns/1ps

// Sequential streaming 4x4 2:4 structured sparse matrix multiply.
//
// Input stream:
//   - 16 dense B matrix elements, row-major order.
//   - Element B[row][col] arrives at stream position (row * 4) + col.
//
// Output stream:
//   - 16 result C matrix elements, row-major order.
//   - Element C[row][col] leaves at stream position (row * 4) + col.
//
// The sparse A matrix is fixed at synthesis time using two weights and two
// column indices per output row.

module sparse_matmul_4x4_streaming #(
    parameter int DATA_WIDTH = 16,
    parameter int ACC_WIDTH = (2 * DATA_WIDTH) + 1,

    // Default sparse matrix is:
    //   [ 3,  0, 0, 2]
    //   [ 4,  5, 0, 0]
    //   [ 0, -7, 6, 0]
    //   [ 8,  0, 0, 4]
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
    input  logic clk,
    input  logic rst_n,

    input  logic signed [DATA_WIDTH-1:0] in_data,
    input  logic in_valid,
    output logic in_ready,

    output logic signed [ACC_WIDTH-1:0] out_data,
    output logic [1:0] out_row,
    output logic [1:0] out_col,
    output logic out_valid,
    input  logic out_ready,

    output logic busy
);

    typedef enum logic [1:0] {
        STATE_LOAD,
        STATE_OUTPUT
    } state_t;

    state_t state;
    logic [4:0] load_count;
    logic [4:0] output_count;
    logic signed [DATA_WIDTH-1:0] dense_b [0:3][0:3];

    assign in_ready = (state == STATE_LOAD);
    assign out_valid = (state == STATE_OUTPUT);
    assign busy = (state != STATE_LOAD) || (load_count != 5'd0);
    assign out_row = output_count[3:2];
    assign out_col = output_count[1:0];

    function automatic logic signed [DATA_WIDTH-1:0] row_weight0(input logic [1:0] row);
        case (row)
            2'd0: row_weight0 = ROW0_WEIGHT0;
            2'd1: row_weight0 = ROW1_WEIGHT0;
            2'd2: row_weight0 = ROW2_WEIGHT0;
            default: row_weight0 = ROW3_WEIGHT0;
        endcase
    endfunction

    function automatic logic signed [DATA_WIDTH-1:0] row_weight1(input logic [1:0] row);
        case (row)
            2'd0: row_weight1 = ROW0_WEIGHT1;
            2'd1: row_weight1 = ROW1_WEIGHT1;
            2'd2: row_weight1 = ROW2_WEIGHT1;
            default: row_weight1 = ROW3_WEIGHT1;
        endcase
    endfunction

    function automatic logic [1:0] row_index0(input logic [1:0] row);
        case (row)
            2'd0: row_index0 = ROW0_INDEX0;
            2'd1: row_index0 = ROW1_INDEX0;
            2'd2: row_index0 = ROW2_INDEX0;
            default: row_index0 = ROW3_INDEX0;
        endcase
    endfunction

    function automatic logic [1:0] row_index1(input logic [1:0] row);
        case (row)
            2'd0: row_index1 = ROW0_INDEX1;
            2'd1: row_index1 = ROW1_INDEX1;
            2'd2: row_index1 = ROW2_INDEX1;
            default: row_index1 = ROW3_INDEX1;
        endcase
    endfunction

    function automatic logic signed [ACC_WIDTH-1:0] compute_output(
        input logic [1:0] row,
        input logic [1:0] col
    );
        logic signed [(2*DATA_WIDTH)-1:0] product0;
        logic signed [(2*DATA_WIDTH)-1:0] product1;
        begin
            product0 = row_weight0(row) * dense_b[row_index0(row)][col];
            product1 = row_weight1(row) * dense_b[row_index1(row)][col];
            compute_output = product0 + product1;
        end
    endfunction

    always_comb begin
        out_data = compute_output(out_row, out_col);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_LOAD;
            load_count <= 5'd0;
            output_count <= 5'd0;
        end else begin
            case (state)
                STATE_LOAD: begin
                    if (in_valid && in_ready) begin
                        dense_b[load_count[3:2]][load_count[1:0]] <= in_data;
                        if (load_count == 5'd15) begin
                            load_count <= 5'd0;
                            output_count <= 5'd0;
                            state <= STATE_OUTPUT;
                        end else begin
                            load_count <= load_count + 5'd1;
                        end
                    end
                end

                STATE_OUTPUT: begin
                    if (out_valid && out_ready) begin
                        if (output_count == 5'd15) begin
                            output_count <= 5'd0;
                            state <= STATE_LOAD;
                        end else begin
                            output_count <= output_count + 5'd1;
                        end
                    end
                end

                default: begin
                    state <= STATE_LOAD;
                    load_count <= 5'd0;
                    output_count <= 5'd0;
                end
            endcase
        end
    end

endmodule
