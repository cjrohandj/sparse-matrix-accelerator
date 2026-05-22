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
    logic signed [63:0] expected [0:15];

    de10_lite_uart_top #(
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

    initial begin
        expected[0] = 64'sd29;
        expected[1] = 64'sd34;
        expected[2] = 64'sd39;
        expected[3] = 64'sd44;
        expected[4] = 64'sd29;
        expected[5] = 64'sd38;
        expected[6] = 64'sd47;
        expected[7] = 64'sd56;
        expected[8] = 64'sd19;
        expected[9] = 64'sd18;
        expected[10] = 64'sd17;
        expected[11] = 64'sd16;
        expected[12] = 64'sd60;
        expected[13] = 64'sd72;
        expected[14] = 64'sd84;
        expected[15] = 64'sd96;

        clk = 1'b0;
        key = 2'b00;
        uart_rx = 1'b1;

        repeat (5) @(posedge clk);
        key = 2'b11;
        wait_bit_times(2);

        send_uart_byte(8'hAA);
        for (int i = 1; i <= 16; i++) begin
            send_uart_byte(i[7:0]);
            send_uart_byte(8'h00);
        end

        read_uart_byte(rx_byte);
        if (rx_byte !== 8'h55) begin
            $error("expected response start byte 0x55, got 0x%02h", rx_byte);
        end

        for (int word_index = 0; word_index < 16; word_index++) begin
            result_word = 64'sd0;
            for (int byte_index = 0; byte_index < 8; byte_index++) begin
                read_uart_byte(rx_byte);
                result_word[(byte_index * 8) +: 8] = rx_byte;
            end

            if (result_word !== expected[word_index]) begin
                $error(
                    "result[%0d] expected %0d, got %0d",
                    word_index,
                    expected[word_index],
                    result_word
                );
            end
        end

        $display("PASS: DE10-Lite UART top streams one matrix through the accelerator");
        $finish;
    end

endmodule
