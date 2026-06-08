`timescale 1ns/1ps

module tb_de10_lite_uart_echo_top;
    localparam int CLKS_PER_BIT = 8;
    localparam time CLK_PERIOD = 10ns;

    logic clk;
    logic [1:0] key;
    logic uart_rx;
    logic uart_tx;
    logic [9:0] ledr;
    logic [7:0] echoed_byte;

    de10_lite_uart_echo_top #(
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
        clk = 1'b0;
        key = 2'b00;
        uart_rx = 1'b1;
        echoed_byte = 8'h00;

        repeat (5) @(posedge clk);
        key = 2'b11;
        wait_bit_times(2);

        fork
            begin
                read_uart_byte(echoed_byte);
            end

            begin
                send_uart_byte(8'hA5);
            end
        join

        if (echoed_byte !== 8'hA5) begin
            $fatal(1, "expected echoed byte 0xA5, got 0x%02h", echoed_byte);
        end

        if (dut.last_rx_byte !== 8'hA5) begin
            $fatal(1, "expected last_rx_byte 0xA5, got 0x%02h", dut.last_rx_byte);
        end

        $display("PASS: DE10-Lite UART echo top loops received byte back to TX");
        $finish;
    end

endmodule
