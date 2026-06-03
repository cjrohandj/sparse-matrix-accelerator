`timescale 1ns/1ps

module tb_sparse_matmul_4x4;
    localparam int DATA_WIDTH = 16;
    localparam int ACC_WIDTH = (2 * DATA_WIDTH) + $clog2(4) + 1;

    logic signed [(16*DATA_WIDTH)-1:0] dense_b;
    logic signed [(16*ACC_WIDTH)-1:0] result_c;

    sparse_matmul_4x4 #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .dense_b(dense_b),
        .result_c(result_c)
    );

    task automatic set_b(input int row, input int col, input logic signed [DATA_WIDTH-1:0] value);
        dense_b[(((row * 4) + col) * DATA_WIDTH) +: DATA_WIDTH] = value;
    endtask

    function automatic logic signed [ACC_WIDTH-1:0] get_c(input int row, input int col);
        get_c = result_c[(((row * 4) + col) * ACC_WIDTH) +: ACC_WIDTH];
    endfunction

    task automatic expect_c(input int row, input int col, input logic signed [ACC_WIDTH-1:0] expected);
        if (get_c(row, col) !== expected) begin
            $error(
                "C[%0d][%0d] expected %0d, got %0d",
                row,
                col,
                expected,
                get_c(row, col)
            );
        end
    endtask

    initial begin
        dense_b = '0;

        set_b(0, 0, 16'sd1);
        set_b(0, 1, 16'sd2);
        set_b(0, 2, 16'sd3);
        set_b(0, 3, 16'sd4);
        set_b(1, 0, 16'sd5);
        set_b(1, 1, 16'sd6);
        set_b(1, 2, 16'sd7);
        set_b(1, 3, 16'sd8);
        set_b(2, 0, 16'sd9);
        set_b(2, 1, 16'sd10);
        set_b(2, 2, 16'sd11);
        set_b(2, 3, 16'sd12);
        set_b(3, 0, 16'sd13);
        set_b(3, 1, 16'sd14);
        set_b(3, 2, 16'sd15);
        set_b(3, 3, 16'sd16);

        #1;

        expect_c(0, 0, 35'sd24);
        expect_c(0, 1, 35'sd28);
        expect_c(0, 2, 35'sd32);
        expect_c(0, 3, 35'sd36);

        expect_c(1, 0, 35'sd24);
        expect_c(1, 1, 35'sd32);
        expect_c(1, 2, 35'sd40);
        expect_c(1, 3, 35'sd48);

        expect_c(2, 0, 35'sd45);
        expect_c(2, 1, 35'sd46);
        expect_c(2, 2, 35'sd47);
        expect_c(2, 3, 35'sd48);

        expect_c(3, 0, 35'sd38);
        expect_c(3, 1, 35'sd48);
        expect_c(3, 2, 35'sd58);
        expect_c(3, 3, 35'sd68);

        $display("PASS: dense 4x4 matmul matches Python reference output");
        $finish;
    end
endmodule
