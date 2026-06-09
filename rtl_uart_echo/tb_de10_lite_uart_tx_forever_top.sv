`timescale 1ns/1ps

module tb_de10_lite_uart_tx_forever_top;
    localparam int CLKS_PER_BIT = 8;
    localparam time CLK_PERIOD = 10ns;

    logic clk;
    logic [1:0] key;
    logic uart_tx;
    logic [9:0] ledr;
    logic [7:0] first_byte;
    logic [7:0] second_byte;

    de10_lite_uart_tx_forever_top #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) dut (
        .MAX10_CLK1_50(clk),
        .KEY(key),
        .uart_tx(uart_tx),
        .LEDR(ledr)
    );

    always #(CLK_PERIOD / 2) clk = ~clk;

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
        first_byte = 8'h00;
        second_byte = 8'h00;

        repeat (5) @(posedge clk);
        key = 2'b11;

        read_uart_byte(first_byte);
        read_uart_byte(second_byte);

        if (first_byte !== 8'h55) begin
            $fatal(1, "expected first transmitted byte 0x55, got 0x%02h", first_byte);
        end

        if (second_byte !== 8'h55) begin
            $fatal(1, "expected second transmitted byte 0x55, got 0x%02h", second_byte);
        end

        $display("PASS: DE10-Lite UART TX-only top continuously transmits 0x55");
        $finish;
    end

endmodule
