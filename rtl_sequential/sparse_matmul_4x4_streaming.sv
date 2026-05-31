`timescale 1ns/1ps

// Streaming MxK 2:4 structured sparse by KxN dense matmul.
//
// Dense B input is expected in column-major order:
//
//   for n in range(N):
//     for k in range(K):
//       send B[k][n]
//
// That lets the core start accumulating after the first 4-wide K group arrives
// and emit C[:, n] as soon as the complete B column n has been received.

module sparse_matmul_4x4_streaming #(
    parameter int DATA_WIDTH = 16,
    parameter int M_MAX = 4,
    parameter int MAX_K = 16,
    parameter int N_MAX = 4,
    parameter int M_TILE = 4,
    parameter int N_TILE = 4,
    parameter int SPARSE_GROUPS_PER_CYCLE = 1,
    parameter int ACC_WIDTH = (2 * DATA_WIDTH) + $clog2(2 * (MAX_K / 4)) + 1,

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

    input  logic                         config_valid,
    input  logic [7:0]                   config_m,
    input  logic [7:0]                   config_k,
    input  logic [7:0]                   config_n,
    input  logic [7:0]                   config_row,
    input  logic [7:0]                   config_group,
    input  logic signed [DATA_WIDTH-1:0] config_weight0,
    input  logic signed [DATA_WIDTH-1:0] config_weight1,
    input  logic [1:0]                   config_index0,
    input  logic [1:0]                   config_index1,

    output logic signed [ACC_WIDTH-1:0] out_data,
    output logic [7:0] out_row,
    output logic [7:0] out_col,
    output logic out_valid,
    input  logic out_ready,

    output logic busy
);

    localparam int MAX_GROUPS = MAX_K / 4;
    localparam int M_WIDTH = $clog2(M_MAX + 1);
    localparam int N_WIDTH = $clog2(N_MAX + 1);
    localparam int K_WIDTH = $clog2(MAX_K + 1);
    localparam int GROUP_WIDTH = (MAX_GROUPS <= 1) ? 1 : $clog2(MAX_GROUPS);
    localparam int GROUPS_PER_CYCLE =
        (SPARSE_GROUPS_PER_CYCLE < 1) ? 1 :
        ((SPARSE_GROUPS_PER_CYCLE > MAX_GROUPS) ? MAX_GROUPS : SPARSE_GROUPS_PER_CYCLE);

    logic signed [DATA_WIDTH-1:0] weight0 [0:M_MAX-1][0:MAX_GROUPS-1];
    logic signed [DATA_WIDTH-1:0] weight1 [0:M_MAX-1][0:MAX_GROUPS-1];
    logic [1:0] index0 [0:M_MAX-1][0:MAX_GROUPS-1];
    logic [1:0] index1 [0:M_MAX-1][0:MAX_GROUPS-1];

    logic [M_WIDTH-1:0] active_m;
    logic [K_WIDTH-1:0] active_k;
    logic [N_WIDTH-1:0] active_n;
    logic [GROUP_WIDTH:0] active_groups;

    logic [K_WIDTH-1:0] load_k;
    logic [N_WIDTH-1:0] load_col;
    logic signed [DATA_WIDTH-1:0] dense_column [0:MAX_K-1];
    logic signed [ACC_WIDTH-1:0] column_acc [0:M_MAX-1];
    logic compute_active;
    logic [GROUP_WIDTH:0] compute_group_base;

    logic output_active;
    logic [M_WIDTH-1:0] output_row_index;
    logic signed [ACC_WIDTH-1:0] output_data_reg;
    logic [7:0] output_row_reg;
    logic [7:0] output_col_reg;
    logic output_valid_reg;

    wire input_fire  = in_valid && in_ready;
    wire output_fire = out_valid && out_ready;
    wire at_last_output_row = (output_row_index == (active_m - M_WIDTH'(1)));
    wire at_last_output_col = (load_col == (active_n - N_WIDTH'(1)));

    assign in_ready = !compute_active && !output_active && !output_valid_reg;
    assign out_valid = output_valid_reg;
    assign out_data = output_data_reg;
    assign out_row = output_row_reg;
    assign out_col = output_col_reg;
    assign busy = (load_k != '0) || (load_col != '0) || compute_active || output_active || output_valid_reg;

    function automatic logic dims_valid(
        input logic [7:0] m_value,
        input logic [7:0] k_value,
        input logic [7:0] n_value
    );
        begin
            dims_valid =
                (m_value >= 8'd1) && (m_value <= 8'(M_MAX)) &&
                (k_value >= 8'd4) && (k_value <= 8'(MAX_K)) &&
                (k_value[1:0] == 2'b00) &&
                (n_value >= 8'd1) && (n_value <= 8'(N_MAX));
        end
    endfunction

    function automatic logic [GROUP_WIDTH:0] groups_from_k(input logic [7:0] k_value);
        begin
            groups_from_k = k_value[GROUP_WIDTH+1:2];
        end
    endfunction

    function automatic logic signed [DATA_WIDTH-1:0] select_group_value(
        input logic [1:0] lane,
        input logic signed [DATA_WIDTH-1:0] value0,
        input logic signed [DATA_WIDTH-1:0] value1,
        input logic signed [DATA_WIDTH-1:0] value2,
        input logic signed [DATA_WIDTH-1:0] value3
    );
        begin
            case (lane)
                2'd0: select_group_value = value0;
                2'd1: select_group_value = value1;
                2'd2: select_group_value = value2;
                default: select_group_value = value3;
            endcase
        end
    endfunction

    function automatic logic signed [ACC_WIDTH-1:0] group_contribution(
        input logic [M_WIDTH-1:0] row,
        input logic [GROUP_WIDTH-1:0] group_idx,
        input logic signed [DATA_WIDTH-1:0] value0,
        input logic signed [DATA_WIDTH-1:0] value1,
        input logic signed [DATA_WIDTH-1:0] value2,
        input logic signed [DATA_WIDTH-1:0] value3
    );
        logic signed [(2*DATA_WIDTH)-1:0] product0;
        logic signed [(2*DATA_WIDTH)-1:0] product1;
        begin
            product0 =
                weight0[row][group_idx] *
                select_group_value(index0[row][group_idx], value0, value1, value2, value3);
            product1 =
                weight1[row][group_idx] *
                select_group_value(index1[row][group_idx], value0, value1, value2, value3);

            group_contribution = product0 + product1;
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_m <= M_WIDTH'(4);
            active_k <= K_WIDTH'(4);
            active_n <= N_WIDTH'(4);
            active_groups <= {{GROUP_WIDTH{1'b0}}, 1'b1};

            load_k <= '0;
            load_col <= '0;
            compute_active <= 1'b0;
            compute_group_base <= '0;
            output_active <= 1'b0;
            output_row_index <= '0;
            output_data_reg <= '0;
            output_row_reg <= 8'd0;
            output_col_reg <= 8'd0;
            output_valid_reg <= 1'b0;

            for (int k_idx = 0; k_idx < MAX_K; k_idx++) begin
                dense_column[k_idx] <= '0;
            end

            for (int row = 0; row < M_MAX; row++) begin
                column_acc[row] <= '0;
                for (int group_idx = 0; group_idx < MAX_GROUPS; group_idx++) begin
                    weight0[row][group_idx] <= '0;
                    weight1[row][group_idx] <= '0;
                    index0[row][group_idx] <= 2'd0;
                    index1[row][group_idx] <= 2'd0;
                end
            end

            if (M_MAX > 0) begin
                weight0[0][0] <= ROW0_WEIGHT0;
                weight1[0][0] <= ROW0_WEIGHT1;
                index0[0][0] <= ROW0_INDEX0;
                index1[0][0] <= ROW0_INDEX1;
            end

            if (M_MAX > 1) begin
                weight0[1][0] <= ROW1_WEIGHT0;
                weight1[1][0] <= ROW1_WEIGHT1;
                index0[1][0] <= ROW1_INDEX0;
                index1[1][0] <= ROW1_INDEX1;
            end

            if (M_MAX > 2) begin
                weight0[2][0] <= ROW2_WEIGHT0;
                weight1[2][0] <= ROW2_WEIGHT1;
                index0[2][0] <= ROW2_INDEX0;
                index1[2][0] <= ROW2_INDEX1;
            end

            if (M_MAX > 3) begin
                weight0[3][0] <= ROW3_WEIGHT0;
                weight1[3][0] <= ROW3_WEIGHT1;
                index0[3][0] <= ROW3_INDEX0;
                index1[3][0] <= ROW3_INDEX1;
            end
        end else begin
            if (config_valid && !busy && dims_valid(config_m, config_k, config_n)) begin
                active_m <= config_m[M_WIDTH-1:0];
                active_k <= config_k[K_WIDTH-1:0];
                active_n <= config_n[N_WIDTH-1:0];
                active_groups <= groups_from_k(config_k);

                if ((config_row < config_m) && (config_group < 8'(groups_from_k(config_k)))) begin
                    weight0[config_row[M_WIDTH-1:0]][config_group[GROUP_WIDTH-1:0]] <= config_weight0;
                    weight1[config_row[M_WIDTH-1:0]][config_group[GROUP_WIDTH-1:0]] <= config_weight1;
                    index0[config_row[M_WIDTH-1:0]][config_group[GROUP_WIDTH-1:0]] <= config_index0;
                    index1[config_row[M_WIDTH-1:0]][config_group[GROUP_WIDTH-1:0]] <= config_index1;
                end
            end

            if (output_fire) begin
                if (at_last_output_row) begin
                    output_valid_reg <= 1'b0;
                    output_active <= 1'b0;
                    output_row_index <= '0;

                    for (int row = 0; row < M_MAX; row++) begin
                        column_acc[row] <= '0;
                    end

                    if (at_last_output_col) begin
                        load_col <= '0;
                    end else begin
                        load_col <= load_col + N_WIDTH'(1);
                    end
                end else begin
                    output_row_index <= output_row_index + M_WIDTH'(1);
                    output_data_reg <= column_acc[output_row_index + M_WIDTH'(1)];
                    output_row_reg <= {{(8-M_WIDTH){1'b0}}, output_row_index + M_WIDTH'(1)};
                    output_col_reg <= {{(8-N_WIDTH){1'b0}}, load_col};
                end
            end

            if (compute_active) begin
                logic signed [ACC_WIDTH-1:0] first_row_acc;
                first_row_acc = column_acc[0];

                for (int row = 0; row < M_MAX; row++) begin
                    logic signed [ACC_WIDTH-1:0] row_acc_next;
                    row_acc_next = column_acc[row];

                    if (row < active_m) begin
                        for (int lane = 0; lane < GROUPS_PER_CYCLE; lane++) begin
                            logic [GROUP_WIDTH:0] group_index_ext;
                            logic [GROUP_WIDTH-1:0] group_index;
                            group_index_ext = compute_group_base + (GROUP_WIDTH+1)'(lane);

                            if (group_index_ext < active_groups) begin
                                group_index = group_index_ext[GROUP_WIDTH-1:0];
                                row_acc_next =
                                    row_acc_next +
                                    group_contribution(
                                        M_WIDTH'(row),
                                        group_index,
                                        dense_column[{group_index, 2'd0}],
                                        dense_column[{group_index, 2'd1}],
                                        dense_column[{group_index, 2'd2}],
                                        dense_column[{group_index, 2'd3}]
                                    );
                            end
                        end
                    end

                    column_acc[row] <= row_acc_next;
                    if (row == 0) begin
                        first_row_acc = row_acc_next;
                    end
                end

                if ((compute_group_base + (GROUP_WIDTH+1)'(GROUPS_PER_CYCLE)) >= active_groups) begin
                    compute_active <= 1'b0;
                    compute_group_base <= '0;
                    output_active <= 1'b1;
                    output_valid_reg <= 1'b1;
                    output_row_index <= '0;
                    output_data_reg <= first_row_acc;
                    output_row_reg <= 8'd0;
                    output_col_reg <= {{(8-N_WIDTH){1'b0}}, load_col};
                end else begin
                    compute_group_base <= compute_group_base + (GROUP_WIDTH+1)'(GROUPS_PER_CYCLE);
                end
            end

            if (input_fire) begin
                dense_column[load_k] <= in_data;

                if (load_k == (active_k - K_WIDTH'(1))) begin
                    load_k <= '0;
                    compute_active <= 1'b1;
                    compute_group_base <= '0;
                    for (int row = 0; row < M_MAX; row++) begin
                        column_acc[row] <= '0;
                    end
                end else begin
                    load_k <= load_k + K_WIDTH'(1);
                end
            end
        end
    end
endmodule
