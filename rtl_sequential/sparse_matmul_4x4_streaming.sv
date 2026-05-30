`timescale 1ns/1ps

// Sequential streaming 4x4 2:4 structured sparse matrix multiply.
//
// Input stream:
//   - 16 dense B matrix elements, row-major order.
//   - Element B[row][col] arrives at stream position (row * 4) + col.
//
// Output stream:
//   - 16 result C matrix elements, row-major order.
//   - Element C[row][col] leaves at stream position (row * 4) + col.
//
// The sparse A matrix is fixed at synthesis time using two weights and two
// column indices per output row.

module sparse_matmul_4x4_streaming #(
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
    input  logic clk,
    input  logic rst_n,

    input  logic signed [DATA_WIDTH-1:0] in_data,
    input  logic in_valid,
    output logic in_ready,

    output logic signed [ACC_WIDTH-1:0] out_data,
    output logic [1:0] out_row,
    output logic [1:0] out_col,
    output logic out_valid,
    input  logic out_ready,

    output logic busy
);

    logic [4:0] load_count;
    logic [4:0] output_count;

    logic signed [DATA_WIDTH-1:0] dense_b_ping [0:3][0:3];
    logic signed [DATA_WIDTH-1:0] dense_b_pong [0:3][0:3];

    logic ping_full;
    logic pong_full;

    logic write_sel;  // 0 = write ping, 1 = write pong
    logic read_sel;   // 0 = read ping,  1 = read pong

    wire write_ping = (write_sel == 1'b0);
    wire read_ping  = (read_sel  == 1'b0);

    wire selected_write_full = write_ping ? ping_full : pong_full;
    wire selected_read_full  = read_ping  ? ping_full : pong_full;

    wire input_fire  = in_valid  && in_ready;
    wire output_fire = out_valid && out_ready;

    assign in_ready  = !selected_write_full;
    assign out_valid = selected_read_full;

    assign busy = ping_full || pong_full || (load_count != 5'd0);

    assign out_row = output_count[3:2];
    assign out_col = output_count[1:0];

    function automatic logic signed [DATA_WIDTH-1:0] row_weight0(input logic [1:0] row);
        case (row)
            2'd0: row_weight0 = ROW0_WEIGHT0;
            2'd1: row_weight0 = ROW1_WEIGHT0;
            2'd2: row_weight0 = ROW2_WEIGHT0;
            default: row_weight0 = ROW3_WEIGHT0;
        endcase
    endfunction

    function automatic logic signed [DATA_WIDTH-1:0] row_weight1(input logic [1:0] row);
        case (row)
            2'd0: row_weight1 = ROW0_WEIGHT1;
            2'd1: row_weight1 = ROW1_WEIGHT1;
            2'd2: row_weight1 = ROW2_WEIGHT1;
            default: row_weight1 = ROW3_WEIGHT1;
        endcase
    endfunction

    function automatic logic [1:0] row_index0(input logic [1:0] row);
        case (row)
            2'd0: row_index0 = ROW0_INDEX0;
            2'd1: row_index0 = ROW1_INDEX0;
            2'd2: row_index0 = ROW2_INDEX0;
            default: row_index0 = ROW3_INDEX0;
        endcase
    endfunction

    function automatic logic [1:0] row_index1(input logic [1:0] row);
        case (row)
            2'd0: row_index1 = ROW0_INDEX1;
            2'd1: row_index1 = ROW1_INDEX1;
            2'd2: row_index1 = ROW2_INDEX1;
            default: row_index1 = ROW3_INDEX1;
        endcase
    endfunction

    function automatic logic signed [ACC_WIDTH-1:0] compute_output(
        input logic [1:0] row,
        input logic [1:0] col,
        input logic       use_ping
    );
        logic signed [(2*DATA_WIDTH)-1:0] product0;
        logic signed [(2*DATA_WIDTH)-1:0] product1;
        begin
            if (use_ping) begin
                product0 = row_weight0(row) * dense_b_ping[row_index0(row)][col];
                product1 = row_weight1(row) * dense_b_ping[row_index1(row)][col];
            end else begin
                product0 = row_weight0(row) * dense_b_pong[row_index0(row)][col];
                product1 = row_weight1(row) * dense_b_pong[row_index1(row)][col];
            end

            compute_output = product0 + product1;
        end
    endfunction

    always_comb begin
        out_data = compute_output(out_row, out_col, read_ping);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_count   <= 5'd0;
            output_count <= 5'd0;

            ping_full <= 1'b0;
            pong_full <= 1'b0;

            write_sel <= 1'b0;  // start by loading ping
            read_sel  <= 1'b0;  // start by reading ping
        end else begin

            // -------------------------
            // Input side: fill ping/pong
            // -------------------------
            if (input_fire) begin
                if (write_ping) begin
                    dense_b_ping[load_count[3:2]][load_count[1:0]] <= in_data;
                end else begin
                    dense_b_pong[load_count[3:2]][load_count[1:0]] <= in_data;
                end

                if (load_count == 5'd15) begin
                    load_count <= 5'd0;

                    if (write_ping) begin
                        ping_full <= 1'b1;
                    end else begin
                        pong_full <= 1'b1;
                    end

                    write_sel <= ~write_sel;
                end else begin
                    load_count <= load_count + 5'd1;
                end
            end

            // -------------------------
            // Output side: drain ping/pong
            // -------------------------
            if (output_fire) begin
                if (output_count == 5'd15) begin
                    output_count <= 5'd0;

                    if (read_ping) begin
                        ping_full <= 1'b0;
                    end else begin
                        pong_full <= 1'b0;
                    end

                    read_sel <= ~read_sel;
                end else begin
                    output_count <= output_count + 5'd1;
                end
            end
        end
    end
endmodule
