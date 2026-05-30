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

    logic signed [DATA_WIDTH-1:0] dense_input_0 [0:15];
    logic signed [DATA_WIDTH-1:0] dense_input_1 [0:15];

    logic signed [ACC_WIDTH-1:0] expected_output_0 [0:15];
    logic signed [ACC_WIDTH-1:0] expected_output_1 [0:15];

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
            in_data  <= value;
            in_valid <= 1'b1;

            do begin
                @(posedge clk);
            end while (!in_ready);

            in_valid <= 1'b0;
            in_data  <= '0;
        end
    endtask

    task automatic send_matrix_0;
        begin
            for (int i = 0; i < 16; i++) begin
                send_value(dense_input_0[i]);
            end
        end
    endtask

    task automatic send_matrix_1;
        begin
            for (int i = 0; i < 16; i++) begin
                send_value(dense_input_1[i]);
            end
        end
    endtask

    initial begin
        dense_input_0[0]  = 16'sd2;
        dense_input_0[1]  = 16'sd2;
        dense_input_0[2]  = 16'sd3;
        dense_input_0[3]  = 16'sd4;
        dense_input_0[4]  = 16'sd5;
        dense_input_0[5]  = 16'sd6;
        dense_input_0[6]  = 16'sd7;
        dense_input_0[7]  = 16'sd8;
        dense_input_0[8]  = 16'sd9;
        dense_input_0[9]  = 16'sd10;
        dense_input_0[10] = 16'sd11;
        dense_input_0[11] = 16'sd12;
        dense_input_0[12] = 16'sd13;
        dense_input_0[13] = 16'sd14;
        dense_input_0[14] = 16'sd15;
        dense_input_0[15] = 16'sd16;

        expected_output_0[0]  = 33'sd32;
        expected_output_0[1]  = 33'sd34;
        expected_output_0[2]  = 33'sd39;
        expected_output_0[3]  = 33'sd44;
        expected_output_0[4]  = 33'sd33;
        expected_output_0[5]  = 33'sd38;
        expected_output_0[6]  = 33'sd47;
        expected_output_0[7]  = 33'sd56;
        expected_output_0[8]  = 33'sd19;
        expected_output_0[9]  = 33'sd18;
        expected_output_0[10] = 33'sd17;
        expected_output_0[11] = 33'sd16;
        expected_output_0[12] = 33'sd68;
        expected_output_0[13] = 33'sd72;
        expected_output_0[14] = 33'sd84;
        expected_output_0[15] = 33'sd96;

        // Second matrix = first matrix * 2.
        // Since the multiply is linear, expected output also doubles.
        for (int i = 0; i < 16; i++) begin
            dense_input_1[i] = dense_input_0[i] * 2;
            expected_output_1[i] = expected_output_0[i] * 2;
        end

        clk = 1'b0;
        rst_n = 1'b0;
        in_data = '0;
        in_valid = 1'b0;
        out_ready = 1'b1;
        output_index = 0;

        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        fork
            begin
                // Important ping-pong test:
                // send matrix 1 immediately after matrix 0.
                send_matrix_0();
                send_matrix_1();
            end

            begin
                wait (output_index == 32);
            end
        join

        @(posedge clk);
        $display("PASS: ping-pong streaming sparse_matmul_4x4 accepts back-to-back matrices");
        $finish;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            output_index <= 0;
        end else if (out_valid && out_ready) begin
            if (output_index < 16) begin
                if (out_data !== expected_output_0[output_index]) begin
                    $error(
                        "matrix0 output[%0d] C[%0d][%0d] expected %0d, got %0d",
                        output_index,
                        out_row,
                        out_col,
                        expected_output_0[output_index],
                        out_data
                    );
                end

                if (out_row !== (output_index / 4) ||
                    out_col !== (output_index % 4)) begin
                    $error(
                        "matrix0 output[%0d] expected coordinates [%0d][%0d], got [%0d][%0d]",
                        output_index,
                        output_index / 4,
                        output_index % 4,
                        out_row,
                        out_col
                    );
                end
            end else begin
                if (out_data !== expected_output_1[output_index - 16]) begin
                    $error(
                        "matrix1 output[%0d] C[%0d][%0d] expected %0d, got %0d",
                        output_index - 16,
                        out_row,
                        out_col,
                        expected_output_1[output_index - 16],
                        out_data
                    );
                end

                if (out_row !== ((output_index - 16) / 4) ||
                    out_col !== ((output_index - 16) % 4)) begin
                    $error(
                        "matrix1 output[%0d] expected coordinates [%0d][%0d], got [%0d][%0d]",
                        output_index - 16,
                        (output_index - 16) / 4,
                        (output_index - 16) % 4,
                        out_row,
                        out_col
                    );
                end
            end

            output_index <= output_index + 1;
        end
    end

endmodule
