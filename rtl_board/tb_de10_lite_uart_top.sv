`timescale 1ns/1ps

module tb_de10_lite_uart_top;
    localparam int CLKS_PER_BIT = 8;
    localparam time CLK_PERIOD = 10ns;

    logic clk;
    logic [1:0] key;
    logic uart_rx;
    logic uart_tx;
    logic [9:0] ledr;

    logic [7:0] rx_byte;
    logic signed [63:0] result_word;
    int max_result_fifo_count;

    de10_lite_uart_top #(
        .M_MAX(4),
        .N_MAX(5),
        .N_TILE(4),
        .SPARSE_GROUPS_PER_CYCLE(2),
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) dut (
        .MAX10_CLK1_50(clk),
        .KEY(key),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .LEDR(ledr)
    );

    always #(CLK_PERIOD / 2) clk = ~clk;

    task automatic wait_bit_times(input int bit_times);
        begin
            repeat (bit_times * CLKS_PER_BIT) @(posedge clk);
        end
    endtask

    task automatic send_uart_byte(input logic [7:0] value);
        begin
            uart_rx <= 1'b0;
            wait_bit_times(1);

            for (int i = 0; i < 8; i++) begin
                uart_rx <= value[i];
                wait_bit_times(1);
            end

            uart_rx <= 1'b1;
            wait_bit_times(1);
        end
    endtask

    task automatic read_uart_byte(output logic [7:0] value);
        begin
            @(negedge uart_tx);
            repeat (CLKS_PER_BIT / 2) @(posedge clk);

            if (uart_tx !== 1'b0) begin
                $error("UART TX start bit was not low");
            end

            for (int i = 0; i < 8; i++) begin
                repeat (CLKS_PER_BIT) @(posedge clk);
                value[i] = uart_tx;
            end

            repeat (CLKS_PER_BIT) @(posedge clk);
            if (uart_tx !== 1'b1) begin
                $error("UART TX stop bit was not high");
            end
        end
    endtask

    task automatic send_i16(input logic signed [15:0] value);
        begin
            send_uart_byte(value[7:0]);
            send_uart_byte(value[15:8]);
        end
    endtask

    task automatic send_sparse_row(
        input logic signed [15:0] weight0,
        input logic signed [15:0] weight1,
        input logic [1:0] index0,
        input logic [1:0] index1
    );
        begin
            send_i16(weight0);
            send_i16(weight1);
            send_uart_byte({6'd0, index0});
            send_uart_byte({6'd0, index1});
        end
    endtask

    task automatic send_dense_packet_one;
        begin
            send_uart_byte(8'hAA);
            for (int col = 0; col < 5; col++) begin
                for (int row = 0; row < 4; row++) begin
                    send_i16((row * 5) + col + 1);
                end
            end
        end
    endtask

    task automatic send_dense_packet_two;
        logic signed [15:0] value;
        begin
            send_uart_byte(8'hAA);
            for (int col = 0; col < 5; col++) begin
                for (int row = 0; row < 4; row++) begin
                    value = ((row * 5) + col + 1) * 2;
                    send_i16(value);
                end
            end
        end
    endtask

    task automatic expect_single_byte(
        input logic [7:0] expected_byte,
        input string label
    );
        begin
            read_uart_byte(rx_byte);
            if (rx_byte !== expected_byte) begin
                $error("expected %s byte 0x%02h, got 0x%02h", label, expected_byte, rx_byte);
            end
        end
    endtask

    task automatic expect_one_result(input int result_scale);
        int expected_value;
        begin
            expect_single_byte(8'h55, "response start");
            expect_single_byte(8'd3, "response M");
            expect_single_byte(8'd5, "response N");

            for (int col = 0; col < 5; col++) begin
                for (int row = 0; row < 3; row++) begin
                    read_uart_byte(rx_byte);
                    if (rx_byte !== row[7:0]) begin
                        $error("result scale %0d expected row %0d, got %0d", result_scale, row, rx_byte);
                    end

                    read_uart_byte(rx_byte);
                    if (rx_byte !== col[7:0]) begin
                        $error("result scale %0d expected col %0d, got %0d", result_scale, col, rx_byte);
                    end

                    result_word = 64'sd0;
                    for (int byte_index = 0; byte_index < 8; byte_index++) begin
                        read_uart_byte(rx_byte);
                        result_word[(byte_index * 8) +: 8] = rx_byte;
                    end

                    expected_value = ((row * 5) + col + 1) * result_scale;
                    if (result_word !== expected_value) begin
                        $error(
                            "result scale %0d [%0d][%0d] expected %0d, got %0d",
                            result_scale,
                            row,
                            col,
                            expected_value,
                            result_word
                        );
                    end
                end
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        key = 2'b00;
        uart_rx = 1'b1;
        max_result_fifo_count = 0;

        repeat (5) @(posedge clk);
        key = 2'b11;
        wait_bit_times(2);

        // Configure sparse A as 3x4. It selects B rows 0, 1, and 2, while N=5
        // makes the core step across two internal N tiles.
        send_uart_byte(8'hA0);
        send_uart_byte(8'd3);
        send_uart_byte(8'd4);
        send_uart_byte(8'd5);
        send_sparse_row(16'sd1, 16'sd0, 2'd0, 2'd1);
        send_sparse_row(16'sd1, 16'sd0, 2'd1, 2'd0);
        send_sparse_row(16'sd1, 16'sd0, 2'd2, 2'd0);

        expect_single_byte(8'h5A, "config ack");

        // Send two Kx5 dense matrices while the receiver watches the TX line.
        // A real host UART buffers received bytes even while the PC is writing,
        // so the testbench must model that full-duplex behavior explicitly.
        fork
            begin
                expect_single_byte(8'hAC, "matrix queue ack");
                expect_one_result(1);
                expect_single_byte(8'hAC, "matrix queue ack");
                expect_one_result(2);
            end

            begin
                send_dense_packet_one();
                send_dense_packet_two();
            end
        join

        if (max_result_fifo_count <= 1) begin
            $error("expected controller result FIFO to buffer ahead of UART, max depth=%0d", max_result_fifo_count);
        end

        $display("PASS: DE10-Lite UART top streams immediate tagged MxN results");
        $finish;
    end

    always @(posedge clk) begin
        if (dut.controller_inst.result_fifo_count > max_result_fifo_count) begin
            max_result_fifo_count <= dut.controller_inst.result_fifo_count;
        end
    end

endmodule
