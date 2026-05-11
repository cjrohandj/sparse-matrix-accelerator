`timescale 1ns/1ps

// 4x4 2:4 structured sparse matrix multiply.
//
// Computes C = A_sparse * B_dense, where A is fixed at synthesis time as two
// selected weights per row and B is supplied as a dense 4x4 matrix. Matrix
// elements are packed row-major, with element [row][col] at:
//
//   bus[((row * 4) + col) * DATA_WIDTH +: DATA_WIDTH]
//
// Output elements use ACC_WIDTH bits and the same row-major packing.

module sparse_matmul_4x4 #(
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
    input  logic signed [(16*DATA_WIDTH)-1:0] dense_b,
    output logic signed [(16*ACC_WIDTH)-1:0] result_c
);

    function automatic logic signed [DATA_WIDTH-1:0] dense_element(
        input logic signed [(16*DATA_WIDTH)-1:0] matrix,
        input int row,
        input int col
    );
        dense_element = matrix[(((row * 4) + col) * DATA_WIDTH) +: DATA_WIDTH];
    endfunction

    function automatic logic signed [DATA_WIDTH-1:0] row_weight0(input int row);
        case (row)
            0: row_weight0 = ROW0_WEIGHT0;
            1: row_weight0 = ROW1_WEIGHT0;
            2: row_weight0 = ROW2_WEIGHT0;
            default: row_weight0 = ROW3_WEIGHT0;
        endcase
    endfunction

    function automatic logic signed [DATA_WIDTH-1:0] row_weight1(input int row);
        case (row)
            0: row_weight1 = ROW0_WEIGHT1;
            1: row_weight1 = ROW1_WEIGHT1;
            2: row_weight1 = ROW2_WEIGHT1;
            default: row_weight1 = ROW3_WEIGHT1;
        endcase
    endfunction

    function automatic logic [1:0] row_index0(input int row);
        case (row)
            0: row_index0 = ROW0_INDEX0;
            1: row_index0 = ROW1_INDEX0;
            2: row_index0 = ROW2_INDEX0;
            default: row_index0 = ROW3_INDEX0;
        endcase
    endfunction

    function automatic logic [1:0] row_index1(input int row);
        case (row)
            0: row_index1 = ROW0_INDEX1;
            1: row_index1 = ROW1_INDEX1;
            2: row_index1 = ROW2_INDEX1;
            default: row_index1 = ROW3_INDEX1;
        endcase
    endfunction

    always_comb begin
        for (int out_row = 0; out_row < 4; out_row++) begin
            for (int out_col = 0; out_col < 4; out_col++) begin
                result_c[(((out_row * 4) + out_col) * ACC_WIDTH) +: ACC_WIDTH] =
                    (row_weight0(out_row) * dense_element(dense_b, row_index0(out_row), out_col)) +
                    (row_weight1(out_row) * dense_element(dense_b, row_index1(out_row), out_col));
            end
        end
    end

endmodule
