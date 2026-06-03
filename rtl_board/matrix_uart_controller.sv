`timescale 1ns/1ps

// UART packet controller for runtime-shaped dense matmul.
//
// Host dense-B packet:
//   0xAA
//   active_k * active_n signed int16 values for dense B, column-major,
//   little-endian:
//     for n in range(N):
//       for k in range(K):
//         send B[k][n]
//
// FPGA dense-B queue response:
//   0xAC accepted into the waiting room
//   0xEE rejected because the waiting room was full when the packet started
//
// Host dense-A config packet:
//   0xA0
//   M uint8, K uint8, N uint8
//   M * (K/4) dense row/group records, each encoded as:
//     weight0 int16 little-endian
//     weight1 int16 little-endian
//     weight2 int16 little-endian
//     weight3 int16 little-endian
//
// FPGA weight-config response:
//   0x5A
//
// FPGA result packet:
//   0x55
//   M uint8, N uint8
//   M * N tagged entries, produced as soon as the core emits them:
//     row uint8
//     col uint8
//     value int64 little-endian

module matrix_uart_controller #(
    parameter int DATA_WIDTH = 16,
    parameter int M_MAX = 4,
    parameter int MAX_K = 16,
    parameter int N_MAX = 4,
    parameter int ACC_WIDTH = (2 * DATA_WIDTH) + $clog2(MAX_K) + 1,
    parameter int RESULT_WIDTH = 64,
    parameter int MATRIX_FIFO_DEPTH = 4,
    parameter int RESULT_START_IDLE_CYCLES = 1,
    parameter logic [7:0] REQUEST_START_BYTE = 8'hAA,
    parameter logic [7:0] CONFIG_START_BYTE = 8'hA0,
    parameter logic [7:0] CONFIG_ACK_BYTE = 8'h5A,
    parameter logic [7:0] MATRIX_ACK_BYTE = 8'hAC,
    parameter logic [7:0] MATRIX_NACK_BYTE = 8'hEE,
    parameter logic [7:0] RESPONSE_START_BYTE = 8'h55
) (
    input  logic clk,
    input  logic rst_n,

    input  logic [7:0] rx_data,
    input  logic       rx_data_valid,
    input  logic       rx_busy,

    output logic [7:0] tx_data,
    output logic       tx_start,
    input  logic       tx_busy,

    output logic signed [DATA_WIDTH-1:0] core_in_data,
    output logic                         core_in_valid,
    input  logic                         core_in_ready,

    output logic                         core_config_valid,
    output logic [7:0]                   core_config_m,
    output logic [7:0]                   core_config_k,
    output logic [7:0]                   core_config_n,
    output logic [7:0]                   core_config_row,
    output logic [7:0]                   core_config_group,
    output logic signed [DATA_WIDTH-1:0] core_config_weight0,
    output logic signed [DATA_WIDTH-1:0] core_config_weight1,
    output logic signed [DATA_WIDTH-1:0] core_config_weight2,
    output logic signed [DATA_WIDTH-1:0] core_config_weight3,

    input  logic signed [ACC_WIDTH-1:0]  core_out_data,
    input  logic [7:0]                   core_out_row,
    input  logic [7:0]                   core_out_col,
    input  logic                         core_out_valid,
    output logic                         core_out_ready,

    output logic                         busy,
    output logic                         matrix_loaded_pulse,
    output logic                         config_loaded_pulse,
    output logic                         result_sent_pulse,
    output logic [3:0]                   debug_state
);

    localparam int MAX_MATRIX_ELEMS = MAX_K * N_MAX;
    localparam int MAX_RESULT_ELEMS = M_MAX * N_MAX;
    localparam int VALUE_FIFO_DEPTH = MAX_MATRIX_ELEMS * MATRIX_FIFO_DEPTH;
    localparam int RESULT_FIFO_DEPTH = MAX_RESULT_ELEMS * MATRIX_FIFO_DEPTH;
    localparam int RESULT_BYTES = RESULT_WIDTH / 8;
    localparam int MAX_GROUPS = MAX_K / 4;
    localparam int MATRIX_COUNT_WIDTH = $clog2(MAX_MATRIX_ELEMS + 1);
    localparam int RESULT_COUNT_WIDTH = $clog2(MAX_RESULT_ELEMS + 1);
    localparam int VALUE_FIFO_INDEX_WIDTH = (VALUE_FIFO_DEPTH <= 1) ? 1 : $clog2(VALUE_FIFO_DEPTH);
    localparam int VALUE_FIFO_COUNT_WIDTH = $clog2(VALUE_FIFO_DEPTH + 1);
    localparam int RESULT_FIFO_INDEX_WIDTH = (RESULT_FIFO_DEPTH <= 1) ? 1 : $clog2(RESULT_FIFO_DEPTH);
    localparam int RESULT_FIFO_COUNT_WIDTH = $clog2(RESULT_FIFO_DEPTH + 1);
    localparam int FIFO_COUNT_WIDTH = $clog2(MATRIX_FIFO_DEPTH + 1);
    localparam int GROUP_WIDTH = (MAX_GROUPS <= 1) ? 1 : $clog2(MAX_GROUPS);
    localparam int PENDING_COUNT_WIDTH = 8;

    typedef enum logic [3:0] {
        RX_WAIT_START,
        RX_RECV_MATRIX_LOW,
        RX_RECV_MATRIX_HIGH,
        RX_RECV_CONFIG_M,
        RX_RECV_CONFIG_K,
        RX_RECV_CONFIG_N,
        RX_RECV_CONFIG
    } rx_state_t;

    typedef enum logic [3:0] {
        TX_IDLE,
        TX_SEND_SINGLE,
        TX_SEND_RESPONSE_START,
        TX_SEND_RESPONSE_M,
        TX_SEND_RESPONSE_N,
        TX_WAIT_RESULT,
        TX_SEND_RESULT_ROW,
        TX_SEND_RESULT_COL,
        TX_SEND_RESULT_VALUE
    } tx_state_t;

    rx_state_t rx_state;
    tx_state_t tx_state;

    logic signed [DATA_WIDTH-1:0] value_fifo [0:VALUE_FIFO_DEPTH-1];
    logic [VALUE_FIFO_INDEX_WIDTH-1:0] value_fifo_head;
    logic [VALUE_FIFO_INDEX_WIDTH-1:0] value_fifo_tail;
    logic [VALUE_FIFO_COUNT_WIDTH-1:0] value_fifo_count;
    logic signed [RESULT_WIDTH-1:0] result_fifo_data [0:RESULT_FIFO_DEPTH-1];
    logic [7:0] result_fifo_row [0:RESULT_FIFO_DEPTH-1];
    logic [7:0] result_fifo_col [0:RESULT_FIFO_DEPTH-1];
    logic [RESULT_FIFO_INDEX_WIDTH-1:0] result_fifo_head;
    logic [RESULT_FIFO_INDEX_WIDTH-1:0] result_fifo_tail;
    logic [RESULT_FIFO_COUNT_WIDTH-1:0] result_fifo_count;

    logic [MATRIX_COUNT_WIDTH-1:0] rx_value_index;
    logic [7:0] rx_low_byte;
    logic rx_drop_matrix;

    logic [7:0] active_m;
    logic [7:0] active_k;
    logic [7:0] active_n;
    logic [7:0] pending_config_m;
    logic [7:0] pending_config_k;
    logic [7:0] pending_config_n;
    logic [GROUP_WIDTH:0] pending_config_groups;
    logic [7:0] config_row_index;
    logic [7:0] config_group_index;
    logic [2:0] config_byte_index;
    logic [7:0] config_low_byte;
    logic signed [DATA_WIDTH-1:0] config_weight0_tmp;
    logic signed [DATA_WIDTH-1:0] config_weight1_tmp;
    logic signed [DATA_WIDTH-1:0] config_weight2_tmp;

    logic [FIFO_COUNT_WIDTH-1:0] accepted_matrix_count;
    logic [PENDING_COUNT_WIDTH-1:0] matrix_ack_pending;
    logic [PENDING_COUNT_WIDTH-1:0] matrix_nack_pending;
    logic [PENDING_COUNT_WIDTH-1:0] config_ack_pending;
    logic [PENDING_COUNT_WIDTH-1:0] result_pending_count;
    logic [7:0] single_tx_byte;

    logic [RESULT_COUNT_WIDTH-1:0] result_index;
    logic [3:0] result_byte_index;
    logic [7:0] result_row_reg;
    logic [7:0] result_col_reg;
    logic [RESULT_WIDTH-1:0] result_shift;
    logic signed [RESULT_WIDTH-1:0] result_extended;

    logic value_push_now;
    logic value_pop_now;
    logic result_push_now;
    logic result_pop_now;
    logic matrix_accept_now;
    logic result_done_now;
    logic matrix_ack_enqueue_now;
    logic matrix_ack_dequeue_now;
    logic matrix_nack_enqueue_now;
    logic matrix_nack_dequeue_now;
    logic config_ack_enqueue_now;
    logic config_ack_dequeue_now;

    wire value_fifo_empty = (value_fifo_count == '0);
    wire result_fifo_empty = (result_fifo_count == '0);
    wire result_fifo_full = (result_fifo_count == RESULT_FIFO_COUNT_WIDTH'(RESULT_FIFO_DEPTH));
    wire accepted_slots_full = (accepted_matrix_count == FIFO_COUNT_WIDTH'(MATRIX_FIFO_DEPTH));
    wire [MATRIX_COUNT_WIDTH-1:0] active_matrix_last =
        (MATRIX_COUNT_WIDTH'(active_k) * MATRIX_COUNT_WIDTH'(active_n)) - MATRIX_COUNT_WIDTH'(1);
    wire [RESULT_COUNT_WIDTH-1:0] active_result_last =
        (RESULT_COUNT_WIDTH'(active_m) * RESULT_COUNT_WIDTH'(active_n)) - RESULT_COUNT_WIDTH'(1);
    wire config_idle =
        (rx_state == RX_WAIT_START) &&
        (tx_state == TX_IDLE) &&
        value_fifo_empty &&
        (accepted_matrix_count == '0) &&
        (result_pending_count == '0) &&
        (matrix_ack_pending == '0) &&
        (matrix_nack_pending == '0) &&
        (config_ack_pending == '0);

    assign core_in_valid = !value_fifo_empty;
    assign core_in_data = value_fifo[value_fifo_head];
    assign core_out_ready = !result_fifo_full;

    assign tx_start =
        ((tx_state == TX_SEND_SINGLE) ||
         (tx_state == TX_SEND_RESPONSE_START) ||
         (tx_state == TX_SEND_RESPONSE_M) ||
         (tx_state == TX_SEND_RESPONSE_N) ||
         (tx_state == TX_SEND_RESULT_ROW) ||
         (tx_state == TX_SEND_RESULT_COL) ||
         (tx_state == TX_SEND_RESULT_VALUE)) && !tx_busy;

    assign tx_data =
        (tx_state == TX_SEND_SINGLE) ? single_tx_byte :
        (tx_state == TX_SEND_RESPONSE_START) ? RESPONSE_START_BYTE :
        (tx_state == TX_SEND_RESPONSE_M) ? active_m :
        (tx_state == TX_SEND_RESPONSE_N) ? active_n :
        (tx_state == TX_SEND_RESULT_ROW) ? result_row_reg :
        (tx_state == TX_SEND_RESULT_COL) ? result_col_reg :
        result_shift[7:0];

    assign busy =
        (rx_state != RX_WAIT_START) || (tx_state != TX_IDLE) ||
        !value_fifo_empty || (accepted_matrix_count != '0) ||
        (result_pending_count != '0) ||
        (matrix_ack_pending != '0) || (matrix_nack_pending != '0) ||
        (config_ack_pending != '0) || rx_busy;

    assign debug_state = rx_state;
    assign result_extended = {{(RESULT_WIDTH-ACC_WIDTH){core_out_data[ACC_WIDTH-1]}}, core_out_data};

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

    function automatic logic [VALUE_FIFO_INDEX_WIDTH-1:0] value_fifo_next(
        input logic [VALUE_FIFO_INDEX_WIDTH-1:0] index
    );
        begin
            if (index == (VALUE_FIFO_DEPTH - 1)) begin
                value_fifo_next = '0;
            end else begin
                value_fifo_next = index + VALUE_FIFO_INDEX_WIDTH'(1);
            end
        end
    endfunction

    function automatic logic [RESULT_FIFO_INDEX_WIDTH-1:0] result_fifo_next(
        input logic [RESULT_FIFO_INDEX_WIDTH-1:0] index
    );
        begin
            if (index == (RESULT_FIFO_DEPTH - 1)) begin
                result_fifo_next = '0;
            end else begin
                result_fifo_next = index + RESULT_FIFO_INDEX_WIDTH'(1);
            end
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state <= RX_WAIT_START;
            tx_state <= TX_IDLE;
            value_fifo_head <= '0;
            value_fifo_tail <= '0;
            value_fifo_count <= '0;
            result_fifo_head <= '0;
            result_fifo_tail <= '0;
            result_fifo_count <= '0;
            rx_value_index <= '0;
            rx_low_byte <= 8'h00;
            rx_drop_matrix <= 1'b0;

            active_m <= 8'd4;
            active_k <= 8'd4;
            active_n <= 8'd4;
            pending_config_m <= 8'd4;
            pending_config_k <= 8'd4;
            pending_config_n <= 8'd4;
            pending_config_groups <= {{GROUP_WIDTH{1'b0}}, 1'b1};
            config_row_index <= 8'd0;
            config_group_index <= 8'd0;
            config_byte_index <= 3'd0;
            config_low_byte <= 8'h00;
            config_weight0_tmp <= '0;
            config_weight1_tmp <= '0;
            config_weight2_tmp <= '0;

            core_config_valid <= 1'b0;
            core_config_m <= 8'd4;
            core_config_k <= 8'd4;
            core_config_n <= 8'd4;
            core_config_row <= 8'd0;
            core_config_group <= 8'd0;
            core_config_weight0 <= '0;
            core_config_weight1 <= '0;
            core_config_weight2 <= '0;
            core_config_weight3 <= '0;

            accepted_matrix_count <= '0;
            matrix_ack_pending <= '0;
            matrix_nack_pending <= '0;
            config_ack_pending <= '0;
            result_pending_count <= '0;
            single_tx_byte <= 8'h00;
            result_index <= '0;
            result_byte_index <= 4'd0;
            result_row_reg <= 8'd0;
            result_col_reg <= 8'd0;
            result_shift <= '0;

            matrix_loaded_pulse <= 1'b0;
            config_loaded_pulse <= 1'b0;
            result_sent_pulse <= 1'b0;
        end else begin
            value_push_now = 1'b0;
            value_pop_now = core_in_valid && core_in_ready;
            result_push_now = core_out_valid && core_out_ready;
            result_pop_now = 1'b0;
            matrix_accept_now = 1'b0;
            result_done_now = 1'b0;
            matrix_ack_enqueue_now = 1'b0;
            matrix_ack_dequeue_now = 1'b0;
            matrix_nack_enqueue_now = 1'b0;
            matrix_nack_dequeue_now = 1'b0;
            config_ack_enqueue_now = 1'b0;
            config_ack_dequeue_now = 1'b0;

            core_config_valid <= 1'b0;
            matrix_loaded_pulse <= 1'b0;
            config_loaded_pulse <= 1'b0;
            result_sent_pulse <= 1'b0;

            if (value_pop_now) begin
                value_fifo_head <= value_fifo_next(value_fifo_head);
            end

            if (result_push_now) begin
                result_fifo_data[result_fifo_tail] <= result_extended;
                result_fifo_row[result_fifo_tail] <= core_out_row;
                result_fifo_col[result_fifo_tail] <= core_out_col;
                result_fifo_tail <= result_fifo_next(result_fifo_tail);
            end

            case (rx_state)
                RX_WAIT_START: begin
                    rx_value_index <= '0;
                    if (rx_data_valid && (rx_data == REQUEST_START_BYTE)) begin
                        rx_drop_matrix <= accepted_slots_full;
                        if (accepted_slots_full) begin
                            matrix_nack_enqueue_now = 1'b1;
                        end else begin
                            matrix_accept_now = 1'b1;
                            matrix_ack_enqueue_now = 1'b1;
                        end
                        rx_state <= RX_RECV_MATRIX_LOW;
                    end else if (rx_data_valid && (rx_data == CONFIG_START_BYTE) && config_idle) begin
                        config_row_index <= 8'd0;
                        config_group_index <= 8'd0;
                        config_byte_index <= 3'd0;
                        rx_state <= RX_RECV_CONFIG_M;
                    end
                end

                RX_RECV_MATRIX_LOW: begin
                    if (rx_data_valid) begin
                        rx_low_byte <= rx_data;
                        rx_state <= RX_RECV_MATRIX_HIGH;
                    end
                end

                RX_RECV_MATRIX_HIGH: begin
                    if (rx_data_valid) begin
                        if (!rx_drop_matrix) begin
                            value_fifo[value_fifo_tail] <= {rx_data, rx_low_byte};
                            value_fifo_tail <= value_fifo_next(value_fifo_tail);
                            value_push_now = 1'b1;
                        end

                        if (rx_value_index == active_matrix_last) begin
                            rx_value_index <= '0;
                            rx_drop_matrix <= 1'b0;
                            rx_state <= RX_WAIT_START;
                            if (!rx_drop_matrix) begin
                                matrix_loaded_pulse <= 1'b1;
                            end
                        end else begin
                            rx_value_index <= rx_value_index + MATRIX_COUNT_WIDTH'(1);
                            rx_state <= RX_RECV_MATRIX_LOW;
                        end
                    end
                end

                RX_RECV_CONFIG_M: begin
                    if (rx_data_valid) begin
                        pending_config_m <= ((rx_data >= 8'd1) && (rx_data <= 8'(M_MAX))) ? rx_data : 8'd4;
                        rx_state <= RX_RECV_CONFIG_K;
                    end
                end

                RX_RECV_CONFIG_K: begin
                    if (rx_data_valid) begin
                        pending_config_k <= ((rx_data >= 8'd4) && (rx_data <= 8'(MAX_K)) && (rx_data[1:0] == 2'b00)) ?
                            rx_data : 8'd4;
                        pending_config_groups <= ((rx_data >= 8'd4) && (rx_data <= 8'(MAX_K)) && (rx_data[1:0] == 2'b00)) ?
                            groups_from_k(rx_data) :
                            {{GROUP_WIDTH{1'b0}}, 1'b1};
                        rx_state <= RX_RECV_CONFIG_N;
                    end
                end

                RX_RECV_CONFIG_N: begin
                    if (rx_data_valid) begin
                        pending_config_n <= ((rx_data >= 8'd1) && (rx_data <= 8'(N_MAX))) ? rx_data : 8'd4;
                        config_row_index <= 8'd0;
                        config_group_index <= 8'd0;
                        config_byte_index <= 3'd0;
                        rx_state <= RX_RECV_CONFIG;
                    end
                end

                RX_RECV_CONFIG: begin
                    if (rx_data_valid) begin
                        case (config_byte_index)
                            3'd0: begin
                                config_low_byte <= rx_data;
                                config_byte_index <= 3'd1;
                            end

                            3'd1: begin
                                config_weight0_tmp <= {rx_data, config_low_byte};
                                config_byte_index <= 3'd2;
                            end

                            3'd2: begin
                                config_low_byte <= rx_data;
                                config_byte_index <= 3'd3;
                            end

                            3'd3: begin
                                config_weight1_tmp <= {rx_data, config_low_byte};
                                config_byte_index <= 3'd4;
                            end

                            3'd4: begin
                                config_low_byte <= rx_data;
                                config_byte_index <= 3'd5;
                            end

                            3'd5: begin
                                config_weight2_tmp <= {rx_data, config_low_byte};
                                config_byte_index <= 3'd6;
                            end

                            3'd6: begin
                                config_low_byte <= rx_data;
                                config_byte_index <= 3'd7;
                            end

                            default: begin
                                core_config_valid <= 1'b1;
                                core_config_m <= pending_config_m;
                                core_config_k <= pending_config_k;
                                core_config_n <= pending_config_n;
                                core_config_row <= config_row_index;
                                core_config_group <= config_group_index;
                                core_config_weight0 <= config_weight0_tmp;
                                core_config_weight1 <= config_weight1_tmp;
                                core_config_weight2 <= config_weight2_tmp;
                                core_config_weight3 <= {rx_data, config_low_byte};
                                config_byte_index <= 3'd0;

                                if ((config_row_index == (pending_config_m - 8'd1)) &&
                                    (config_group_index == (8'(pending_config_groups) - 8'd1))) begin
                                    config_row_index <= 8'd0;
                                    config_group_index <= 8'd0;
                                    active_m <= pending_config_m;
                                    active_k <= pending_config_k;
                                    active_n <= pending_config_n;
                                    config_ack_enqueue_now = 1'b1;
                                    config_loaded_pulse <= 1'b1;
                                    rx_state <= RX_WAIT_START;
                                end else if (config_group_index == (8'(pending_config_groups) - 8'd1)) begin
                                    config_group_index <= 8'd0;
                                    config_row_index <= config_row_index + 8'd1;
                                end else begin
                                    config_group_index <= config_group_index + 8'd1;
                                end
                            end
                        endcase
                    end
                end

                default: begin
                    rx_state <= RX_WAIT_START;
                end
            endcase

            case (tx_state)
                TX_IDLE: begin
                    result_index <= '0;
                    result_byte_index <= 4'd0;

                    if (matrix_ack_pending != '0) begin
                        single_tx_byte <= MATRIX_ACK_BYTE;
                        matrix_ack_dequeue_now = 1'b1;
                        tx_state <= TX_SEND_SINGLE;
                    end else if (matrix_nack_pending != '0) begin
                        single_tx_byte <= MATRIX_NACK_BYTE;
                        matrix_nack_dequeue_now = 1'b1;
                        tx_state <= TX_SEND_SINGLE;
                    end else if (config_ack_pending != '0) begin
                        single_tx_byte <= CONFIG_ACK_BYTE;
                        config_ack_dequeue_now = 1'b1;
                        tx_state <= TX_SEND_SINGLE;
                    end else if (result_pending_count != '0) begin
                        tx_state <= TX_SEND_RESPONSE_START;
                    end
                end

                TX_SEND_SINGLE: begin
                    if (!tx_busy) begin
                        tx_state <= TX_IDLE;
                    end
                end

                TX_SEND_RESPONSE_START: begin
                    if (!tx_busy) begin
                        tx_state <= TX_SEND_RESPONSE_M;
                    end
                end

                TX_SEND_RESPONSE_M: begin
                    if (!tx_busy) begin
                        tx_state <= TX_SEND_RESPONSE_N;
                    end
                end

                TX_SEND_RESPONSE_N: begin
                    if (!tx_busy) begin
                        result_index <= '0;
                        result_byte_index <= 4'd0;
                        tx_state <= TX_WAIT_RESULT;
                    end
                end

                TX_WAIT_RESULT: begin
                    if (!result_fifo_empty) begin
                        result_shift <= result_fifo_data[result_fifo_head];
                        result_row_reg <= result_fifo_row[result_fifo_head];
                        result_col_reg <= result_fifo_col[result_fifo_head];
                        result_byte_index <= 4'd0;
                        result_pop_now = 1'b1;
                        tx_state <= TX_SEND_RESULT_ROW;
                    end
                end

                TX_SEND_RESULT_ROW: begin
                    if (!tx_busy) begin
                        tx_state <= TX_SEND_RESULT_COL;
                    end
                end

                TX_SEND_RESULT_COL: begin
                    if (!tx_busy) begin
                        tx_state <= TX_SEND_RESULT_VALUE;
                    end
                end

                TX_SEND_RESULT_VALUE: begin
                    if (!tx_busy) begin
                        if (result_byte_index == (RESULT_BYTES - 1)) begin
                            result_byte_index <= 4'd0;

                            if (result_index == active_result_last) begin
                                result_index <= '0;
                                result_done_now = 1'b1;
                                result_sent_pulse <= 1'b1;
                                tx_state <= TX_IDLE;
                            end else begin
                                result_index <= result_index + RESULT_COUNT_WIDTH'(1);
                                tx_state <= TX_WAIT_RESULT;
                            end
                        end else begin
                            result_shift <= {{8{1'b0}}, result_shift[RESULT_WIDTH-1:8]};
                            result_byte_index <= result_byte_index + 4'd1;
                        end
                    end
                end

                default: begin
                    tx_state <= TX_IDLE;
                end
            endcase

            if (result_pop_now) begin
                result_fifo_head <= result_fifo_next(result_fifo_head);
            end

            case ({value_push_now, value_pop_now})
                2'b10: value_fifo_count <= value_fifo_count + VALUE_FIFO_COUNT_WIDTH'(1);
                2'b01: value_fifo_count <= value_fifo_count - VALUE_FIFO_COUNT_WIDTH'(1);
                default: value_fifo_count <= value_fifo_count;
            endcase

            case ({result_push_now, result_pop_now})
                2'b10: result_fifo_count <= result_fifo_count + RESULT_FIFO_COUNT_WIDTH'(1);
                2'b01: result_fifo_count <= result_fifo_count - RESULT_FIFO_COUNT_WIDTH'(1);
                default: result_fifo_count <= result_fifo_count;
            endcase

            case ({matrix_accept_now, result_done_now})
                2'b10: accepted_matrix_count <= accepted_matrix_count + FIFO_COUNT_WIDTH'(1);
                2'b01: accepted_matrix_count <= accepted_matrix_count - FIFO_COUNT_WIDTH'(1);
                default: accepted_matrix_count <= accepted_matrix_count;
            endcase

            case ({matrix_accept_now, result_done_now})
                2'b10: result_pending_count <= result_pending_count + PENDING_COUNT_WIDTH'(1);
                2'b01: result_pending_count <= result_pending_count - PENDING_COUNT_WIDTH'(1);
                default: result_pending_count <= result_pending_count;
            endcase

            case ({matrix_ack_enqueue_now, matrix_ack_dequeue_now})
                2'b10: matrix_ack_pending <= matrix_ack_pending + PENDING_COUNT_WIDTH'(1);
                2'b01: matrix_ack_pending <= matrix_ack_pending - PENDING_COUNT_WIDTH'(1);
                default: matrix_ack_pending <= matrix_ack_pending;
            endcase

            case ({matrix_nack_enqueue_now, matrix_nack_dequeue_now})
                2'b10: matrix_nack_pending <= matrix_nack_pending + PENDING_COUNT_WIDTH'(1);
                2'b01: matrix_nack_pending <= matrix_nack_pending - PENDING_COUNT_WIDTH'(1);
                default: matrix_nack_pending <= matrix_nack_pending;
            endcase

            case ({config_ack_enqueue_now, config_ack_dequeue_now})
                2'b10: config_ack_pending <= config_ack_pending + PENDING_COUNT_WIDTH'(1);
                2'b01: config_ack_pending <= config_ack_pending - PENDING_COUNT_WIDTH'(1);
                default: config_ack_pending <= config_ack_pending;
            endcase
        end
    end

endmodule
