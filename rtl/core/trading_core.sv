module trading_core #(
    parameter int unsigned DEPTH = trading_types_pkg::MAX_ORDERS
) (
    input logic clk,
    input logic rst,

    input logic event_valid,
    output logic event_ready,
    input trading_types_pkg::market_event_t event_data,

    output logic result_valid,
    input logic result_ready,
    output logic result_success,

    output trading_types_pkg::book_error_t result_error,
    output trading_types_pkg::order_id_t result_order_id,
    output trading_types_pkg::order_record_t result_before,
    output trading_types_pkg::order_record_t result_after,

    output trading_types_pkg::bbo_t result_bbo,
    output logic result_bbo_valid,

    output logic faulted
);

    import trading_types_pkg::*;

    typedef enum logic [1:0] {
        IDLE,
        WAIT_BOOK,
        WAIT_BBO,
        RESPOND
    } state_t;

    state_t state;

    logic book_event_valid;
    logic book_event_ready;

    logic book_valid;
    logic book_ready;
    logic book_success;
    logic book_faulted;

    book_error_t book_error;
    order_id_t book_id;
    order_record_t book_before;
    order_record_t book_after;

    logic bbo_update_valid;
    logic bbo_update_ready;
    logic bbo_valid;
    logic bbo_ready;
    logic bbo_error;
    bbo_t bbo_data;

    logic fault_q;
    book_error_t error_q;
    order_id_t id_q;
    order_record_t before_q;
    order_record_t after_q;
    bbo_t snapshot_q;
    bbo_t last_bbo_q;

    order_book #(
        .DEPTH(DEPTH)
    ) book_inst (
        .clk,
        .rst,

        .event_valid(book_event_valid),
        .event_ready(book_event_ready),
        .event_data(event_data),

        .result_valid(book_valid),
        .result_ready(book_ready),
        .result_success(book_success),
        .result_error(book_error),
        .result_order_id(book_id),
        .result_before(book_before),
        .result_after(book_after),

        .faulted(book_faulted)
    );

    bbo_tracker bbo_inst (
        .clk,
        .rst,

        .update_valid(bbo_update_valid),
        .update_ready(bbo_update_ready),
        .update_before(book_before),
        .update_after(book_after),

        .result_valid(bbo_valid),
        .result_ready(bbo_ready),
        .result_error(bbo_error),
        .result_bbo(bbo_data)
    );

    assign faulted = fault_q || book_faulted;

    assign event_ready =
        !rst &&
        !faulted &&
        state == IDLE &&
        book_event_ready;

    assign book_event_valid =
        !rst &&
        !faulted &&
        state == IDLE &&
        event_valid;

    // Transfer successful book updates to BBO exactly once.
    assign bbo_update_valid =
        !rst &&
        state == WAIT_BOOK &&
        book_valid &&
        book_success &&
        !book_faulted;

    // Rejected events bypass BBO.
    assign book_ready =
        !rst &&
        state == WAIT_BOOK &&
        ((!book_success || book_faulted) || bbo_update_ready);

    assign bbo_ready = !rst && state == WAIT_BBO;

    assign result_valid = !rst && state == RESPOND;

    assign result_success =
        result_valid && !faulted && error_q == BOOK_OK;

    assign result_error = error_q;
    assign result_order_id = id_q;
    assign result_before = before_q;
    assign result_after = after_q;
    assign result_bbo = snapshot_q;

    // An empty book is a valid snapshot.
    // Internal faults make the snapshot untrustworthy.
    assign result_bbo_valid = result_valid && !faulted;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            fault_q <= 1'b0;
            error_q <= BOOK_OK;
            id_q <= '0;
            before_q <= '0;
            after_q <= '0;
            snapshot_q <= '0;
            last_bbo_q <= '0;

        end else begin
            case (state)

                IDLE: begin
                    if (event_valid && event_ready)
                        state <= WAIT_BOOK;
                end

                WAIT_BOOK: begin
                    if (book_valid && book_ready) begin
                        id_q <= book_id;
                        before_q <= book_before;
                        after_q <= book_after;

                        if (book_faulted) begin
                            error_q <= BOOK_INTERNAL_ERROR;
                            fault_q <= 1'b1;
                            snapshot_q <= last_bbo_q;
                            state <= RESPOND;

                        end else if (!book_success) begin
                            error_q <= book_error;
                            snapshot_q <= last_bbo_q;
                            state <= RESPOND;

                        end else begin
                            state <= WAIT_BBO;
                        end
                    end
                end

                WAIT_BBO: begin
                    if (bbo_valid && bbo_ready) begin
                        if (bbo_error) begin
                            // The book already changed. Reset both
                            // stages to recover from this inconsistency.
                            error_q <= BOOK_INTERNAL_ERROR;
                            fault_q <= 1'b1;
                            snapshot_q <= last_bbo_q;

                        end else begin
                            error_q <= BOOK_OK;
                            snapshot_q <= bbo_data;
                            last_bbo_q <= bbo_data;
                        end

                        state <= RESPOND;
                    end
                end

                RESPOND: begin
                    // Hold the entire result until accepted.
                    if (result_ready)
                        state <= IDLE;
                end

                default: begin
                    error_q <= BOOK_INTERNAL_ERROR;
                    fault_q <= 1'b1;
                    snapshot_q <= last_bbo_q;
                    state <= RESPOND;
                end

            endcase
        end
    end

endmodule