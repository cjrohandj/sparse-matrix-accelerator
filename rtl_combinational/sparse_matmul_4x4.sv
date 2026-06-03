`timescale 1ns/1ps

// 4x4 dense matrix multiply.
//
// Computes C = A_dense * B_dense, where A is fixed at synthesis time and B is
// supplied as a dense 4x4 matrix. Matrix elements are packed row-major, with
// element [row][col] at:
//
//   bus[((row * 4) + col) * DATA_WIDTH +: DATA_WIDTH]
//
// Output elements use ACC_WIDTH bits and the same row-major packing.

module sparse_matmul_4x4 #(
    parameter int DATA_WIDTH = 16,
    parameter int ACC_WIDTH = (2 * DATA_WIDTH) + $clog2(4) + 1,

    // Default dense matrix is:
    //   [ 3, -1,  0, 2]
    //   [ 4,  5, -2, 1]
    //   [ 0, -7,  6, 2]
    //   [ 8,  1, -3, 4]
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

    function automatic logic signed [DATA_WIDTH-1:0] row_weight2(input int row);
        case (row)
            0: row_weight2 = ROW0_WEIGHT2;
            1: row_weight2 = ROW1_WEIGHT2;
            2: row_weight2 = ROW2_WEIGHT2;
            default: row_weight2 = ROW3_WEIGHT2;
        endcase
    endfunction

    function automatic logic signed [DATA_WIDTH-1:0] row_weight3(input int row);
        case (row)
            0: row_weight3 = ROW0_WEIGHT3;
            1: row_weight3 = ROW1_WEIGHT3;
            2: row_weight3 = ROW2_WEIGHT3;
            default: row_weight3 = ROW3_WEIGHT3;
        endcase
    endfunction

    always_comb begin
        for (int out_row = 0; out_row < 4; out_row++) begin
            for (int out_col = 0; out_col < 4; out_col++) begin
                result_c[(((out_row * 4) + out_col) * ACC_WIDTH) +: ACC_WIDTH] =
                    (row_weight0(out_row) * dense_element(dense_b, 0, out_col)) +
                    (row_weight1(out_row) * dense_element(dense_b, 1, out_col)) +
                    (row_weight2(out_row) * dense_element(dense_b, 2, out_col)) +
                    (row_weight3(out_row) * dense_element(dense_b, 3, out_col));
            end
        end
    end

endmodule
