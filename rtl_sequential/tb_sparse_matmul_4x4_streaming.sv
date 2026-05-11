`timescale 1ns/1ps

module tb_sparse_matmul_4x4_streaming;
    localparam int DATA_WIDTH = 16;
    localparam int ACC_WIDTH = (2 * DATA_WIDTH) + 1;

    logic clk;
    logic rst_n;
    logic signed [DATA_WIDTH-1:0] in_data;
    logic in_valid;
    logic in_ready;
    logic signed [ACC_WIDTH-1:0] out_data;
    logic [1:0] out_row;
    logic [1:0] out_col;
    logic out_valid;
    logic out_ready;
    logic busy;

    logic signed [DATA_WIDTH-1:0] dense_input [0:15];
    logic signed [ACC_WIDTH-1:0] expected_output [0:15];
    int output_index;

    sparse_matmul_4x4_streaming #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .in_data(in_data),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .out_data(out_data),
        .out_row(out_row),
        .out_col(out_col),
        .out_valid(out_valid),
        .out_ready(out_ready),
        .busy(busy)
    );

    always #5 clk = ~clk;

    task automatic send_value(input logic signed [DATA_WIDTH-1:0] value);
        begin
            @(posedge clk);
            while (!in_ready) begin
                @(posedge clk);
            end
            in_data <= value;
            in_valid <= 1'b1;
            @(posedge clk);
            in_valid <= 1'b0;
            in_data <= '0;
        end
    endtask

    initial begin
        dense_input[0] = 16'sd1;
        dense_input[1] = 16'sd2;
        dense_input[2] = 16'sd3;
        dense_input[3] = 16'sd4;
        dense_input[4] = 16'sd5;
        dense_input[5] = 16'sd6;
        dense_input[6] = 16'sd7;
        dense_input[7] = 16'sd8;
        dense_input[8] = 16'sd9;
        dense_input[9] = 16'sd10;
        dense_input[10] = 16'sd11;
        dense_input[11] = 16'sd12;
        dense_input[12] = 16'sd13;
        dense_input[13] = 16'sd14;
        dense_input[14] = 16'sd15;
        dense_input[15] = 16'sd16;

        expected_output[0] = 33'sd29;
        expected_output[1] = 33'sd34;
        expected_output[2] = 33'sd39;
        expected_output[3] = 33'sd44;
        expected_output[4] = 33'sd29;
        expected_output[5] = 33'sd38;
        expected_output[6] = 33'sd47;
        expected_output[7] = 33'sd56;
        expected_output[8] = 33'sd19;
        expected_output[9] = 33'sd18;
        expected_output[10] = 33'sd17;
        expected_output[11] = 33'sd16;
        expected_output[12] = 33'sd60;
        expected_output[13] = 33'sd72;
        expected_output[14] = 33'sd84;
        expected_output[15] = 33'sd96;

        clk = 1'b0;
        rst_n = 1'b0;
        in_data = '0;
        in_valid = 1'b0;
        out_ready = 1'b1;
        output_index = 0;

        repeat (3) @(posedge clk);
        rst_n <= 1'b1;

        for (int i = 0; i < 16; i++) begin
            send_value(dense_input[i]);
        end

        wait (output_index == 16);
        @(posedge clk);
        $display("PASS: streaming sparse_matmul_4x4 matches Python reference output");
        $finish;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            output_index <= 0;
        end else if (out_valid && out_ready) begin
            if (out_data !== expected_output[output_index]) begin
                $error(
                    "output[%0d] C[%0d][%0d] expected %0d, got %0d",
                    output_index,
                    out_row,
                    out_col,
                    expected_output[output_index],
                    out_data
                );
            end
            if (out_row !== (output_index / 4) || out_col !== (output_index % 4)) begin
                $error(
                    "output[%0d] expected coordinates [%0d][%0d], got [%0d][%0d]",
                    output_index,
                    output_index / 4,
                    output_index % 4,
                    out_row,
                    out_col
                );
            end
            output_index <= output_index + 1;
        end
    end
endmodule
