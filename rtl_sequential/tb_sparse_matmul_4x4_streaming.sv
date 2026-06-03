`timescale 1ns/1ps

module tb_sparse_matmul_4x4_streaming;
    localparam int DATA_WIDTH = 16;
    localparam int MAX_K = 16;
    localparam int M_MAX = 4;
    localparam int N_MAX = 5;
    localparam int ACC_WIDTH = (2 * DATA_WIDTH) + $clog2(MAX_K) + 1;

    logic clk;
    logic rst_n;

    logic signed [DATA_WIDTH-1:0] in_data;
    logic in_valid;
    logic in_ready;

    logic config_valid;
    logic [7:0] config_row;
    logic signed [DATA_WIDTH-1:0] config_weight0;
    logic signed [DATA_WIDTH-1:0] config_weight1;
    logic signed [DATA_WIDTH-1:0] config_weight2;
    logic signed [DATA_WIDTH-1:0] config_weight3;

    logic signed [ACC_WIDTH-1:0] out_data;
    logic [7:0] out_row;
    logic [7:0] out_col;
    logic out_valid;
    logic out_ready;
    logic busy;

    logic signed [DATA_WIDTH-1:0] dense_input_0 [0:19];
    logic signed [DATA_WIDTH-1:0] dense_input_1 [0:19];

    logic signed [ACC_WIDTH-1:0] expected_output_0 [0:14];
    logic signed [ACC_WIDTH-1:0] expected_output_1 [0:14];
    int expected_row [0:14];
    int expected_col [0:14];

    int output_index;
    int input_count;

    sparse_matmul_4x4_streaming #(
        .DATA_WIDTH(DATA_WIDTH),
        .M_MAX(M_MAX),
        .N_MAX(N_MAX),
        .GROUPS_PER_CYCLE_CFG(2),
        .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),

        .in_data(in_data),
        .in_valid(in_valid),
        .in_ready(in_ready),

        .config_valid(config_valid),
        .config_m(8'd3),
        .config_k(8'd4),
        .config_n(8'd5),
        .config_row(config_row),
        .config_group(8'd0),
        .config_weight0(config_weight0),
        .config_weight1(config_weight1),
        .config_weight2(config_weight2),
        .config_weight3(config_weight3),

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

            input_count = input_count + 1;
            in_valid <= 1'b0;
            in_data  <= '0;
        end
    endtask

    task automatic configure_row(
        input logic [7:0] row,
        input logic signed [DATA_WIDTH-1:0] weight0,
        input logic signed [DATA_WIDTH-1:0] weight1,
        input logic signed [DATA_WIDTH-1:0] weight2,
        input logic signed [DATA_WIDTH-1:0] weight3
    );
        begin
            @(negedge clk);
            config_row = row;
            config_weight0 = weight0;
            config_weight1 = weight1;
            config_weight2 = weight2;
            config_weight3 = weight3;
            config_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            config_valid = 1'b0;
        end
    endtask

    task automatic send_matrix_0;
        begin
            for (int col = 0; col < 5; col++) begin
                for (int row = 0; row < 4; row++) begin
                    send_value(dense_input_0[(row * 5) + col]);
                end
            end
        end
    endtask

    task automatic send_matrix_1;
        begin
            for (int col = 0; col < 5; col++) begin
                for (int row = 0; row < 4; row++) begin
                    send_value(dense_input_1[(row * 5) + col]);
                end
            end
        end
    endtask

    initial begin
        dense_input_0[0]  = 16'sd1;
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
        dense_input_0[16] = 16'sd17;
        dense_input_0[17] = 16'sd18;
        dense_input_0[18] = 16'sd19;
        dense_input_0[19] = 16'sd20;

        expected_output_0[0]  = 37'sd13;
        expected_output_0[1]  = 37'sd39;
        expected_output_0[2]  = 37'sd75;
        expected_output_0[3]  = 37'sd16;
        expected_output_0[4]  = 37'sd43;
        expected_output_0[5]  = 37'sd80;
        expected_output_0[6]  = 37'sd19;
        expected_output_0[7]  = 37'sd47;
        expected_output_0[8]  = 37'sd85;
        expected_output_0[9]  = 37'sd22;
        expected_output_0[10] = 37'sd51;
        expected_output_0[11] = 37'sd90;
        expected_output_0[12] = 37'sd25;
        expected_output_0[13] = 37'sd55;
        expected_output_0[14] = 37'sd95;

        for (int col = 0; col < 5; col++) begin
            for (int row = 0; row < 3; row++) begin
                expected_row[(col * 3) + row] = row;
                expected_col[(col * 3) + row] = col;
            end
        end

        // Second matrix = first matrix * 2.
        // Since the multiply is linear, expected output also doubles.
        for (int i = 0; i < 20; i++) begin
            dense_input_1[i] = dense_input_0[i] * 2;
        end

        for (int i = 0; i < 15; i++) begin
            expected_output_1[i] = expected_output_0[i] * 2;
        end

        clk = 1'b0;
        rst_n = 1'b0;
        in_data = '0;
        in_valid = 1'b0;
        config_valid = 1'b0;
        config_row = 8'd0;
        config_weight0 = '0;
        config_weight1 = '0;
        config_weight2 = '0;
        config_weight3 = '0;
        out_ready = 1'b1;
        output_index = 0;
        input_count = 0;

        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        configure_row(8'd0, 16'sd1, 16'sd2, 16'sd0, 16'sd0);
        configure_row(8'd1, 16'sd0, 16'sd1, 16'sd3, 16'sd0);
        configure_row(8'd2, 16'sd0, 16'sd0, 16'sd1, 16'sd4);

        fork
            begin
                send_matrix_0();
                wait (output_index == 15);
                send_matrix_1();
                wait (output_index == 30);
            end

            begin
                repeat (2000) @(posedge clk);
                $fatal(
                    1,
                    "timeout output_index=%0d in_ready=%0b busy=%0b active_m=%0d active_k=%0d active_n=%0d load_k=%0d load_col=%0d",
                    output_index,
                    in_ready,
                    busy,
                    dut.active_m,
                    dut.active_k,
                    dut.active_n,
                    dut.load_k,
                    dut.load_col
                );
            end
        join_any
        disable fork;

        @(posedge clk);
        $display("PASS: runtime M/N dense matmul streams immediate output columns");
        $finish;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            output_index <= 0;
        end else if (out_valid && out_ready) begin
            if ((output_index == 0) && (input_count >= 20)) begin
                $error("first output waited for the full dense matrix; input_count=%0d", input_count);
            end

            if (output_index < 15) begin
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

                if (out_row !== expected_row[output_index] ||
                    out_col !== expected_col[output_index]) begin
                    $error(
                        "matrix0 output[%0d] expected coordinates [%0d][%0d], got [%0d][%0d]",
                        output_index,
                        expected_row[output_index],
                        expected_col[output_index],
                        out_row,
                        out_col
                    );
                end
            end else begin
                if (out_data !== expected_output_1[output_index - 15]) begin
                    $error(
                        "matrix1 output[%0d] C[%0d][%0d] expected %0d, got %0d",
                        output_index - 15,
                        out_row,
                        out_col,
                        expected_output_1[output_index - 15],
                        out_data
                    );
                end

                if (out_row !== expected_row[output_index - 15] ||
                    out_col !== expected_col[output_index - 15]) begin
                    $error(
                        "matrix1 output[%0d] expected coordinates [%0d][%0d], got [%0d][%0d]",
                        output_index - 15,
                        expected_row[output_index - 15],
                        expected_col[output_index - 15],
                        out_row,
                        out_col
                    );
                end
            end

            output_index <= output_index + 1;
        end
    end

endmodule
