// Planned role: BRAM-backed order records and price-level quantity updates.

module order_book #(
    parameter int unsigned DEPTH = trading_types_pkg::MAX_ORDERS
) (
    input logic clk,
    input logic rst,

    // Input event handshake.
    input logic event_valid,
    output logic event_ready,
    input trading_types_pkg::market_event_t event_data,

    // Output result handshake.
    output logic result_valid,
    input logic result_ready,

    output logic result_success,
    output trading_types_pkg::book_error_t result_error,
    output trading_types_pkg::order_id_t result_order_id,

    // Meaningful only for a successful result.
    output trading_types_pkg::order_record_t result_before,
    output trading_types_pkg::order_record_t result_after,

    // Unexpected component failures stop further input until reset.
    output logic faulted
);

    import trading_types_pkg::*;

    localparam int unsigned ADDR_WIDTH = $clog2(DEPTH);
    localparam int unsigned COUNT_WIDTH = $clog2(DEPTH + 1);

    typedef enum logic [4:0] {
        IDLE,

        FIND_REQ,
        FIND_WAIT,

        ALLOC_REQ,
        ALLOC_WAIT,

        INSERT_REQ,
        INSERT_WAIT,

        UNDO_ALLOC_REQ,
        UNDO_ALLOC_WAIT,

        READ_REQ,
        READ_WAIT,
        PREPARE_UPDATE,

        REMOVE_REQ,
        REMOVE_WAIT,

        FREE_REQ,
        FREE_WAIT,

        WRITE_RECORD,
        RESPOND
    } state_t;

    state_t state;

    market_event_t event_q;
    logic [ADDR_WIDTH-1:0] slot_q;

    order_record_t before_q;
    order_record_t after_q;
    order_record_t updated_record;

    book_error_t error_q;
    logic input_event_valid;

    // Lookup interface.
    logic lookup_req_valid;
    lookup_cmd_t lookup_req_cmd;

    logic lookup_rsp_valid;
    logic lookup_rsp_success;
    logic [ADDR_WIDTH-1:0] lookup_rsp_slot;

    // Allocator interface.
    logic alloc_req;
    logic alloc_valid;
    logic [ADDR_WIDTH-1:0] alloc_addr;

    logic free_req;
    logic free_valid;
    logic alloc_error;
    logic alloc_full;
    logic [COUNT_WIDTH-1:0] used_count;

    // Order storage interface.
    logic store_ready;

    logic store_write_en;
    logic store_read_en;
    logic store_read_valid;

    order_record_t store_read_data;

    order_lookup #(
        .DEPTH(DEPTH)
    ) lookup_inst (
        .clk,
        .rst,

        .req_valid(lookup_req_valid),
        .req_cmd(lookup_req_cmd),
        .req_order_id(event_q.order_id),
        .req_slot(slot_q),

        .rsp_valid(lookup_rsp_valid),
        .rsp_success(lookup_rsp_success),
        .rsp_slot(lookup_rsp_slot)
    );

    slot_allocator #(
        .DEPTH(DEPTH)
    ) allocator_inst (
        .clk,
        .rst,

        .alloc_req,
        .alloc_valid,
        .alloc_addr,

        .free_req,
        .free_addr(slot_q),
        .free_valid,

        .op_error(alloc_error),
        .full(alloc_full),
        .used_count
    );

    order_store #(
        .DEPTH(DEPTH)
    ) store_inst (
        .clk,
        .rst,
        .ready(store_ready),

        .write_en(store_write_en),
        .write_addr(slot_q),
        .write_data(after_q),

        .read_en(store_read_en),
        .read_addr(slot_q),
        .read_valid(store_read_valid),
        .read_data(store_read_data)
    );

    // Make an order record from a validated Add event.
    function automatic order_record_t make_add_record(
        input market_event_t incoming
    );
        order_record_t record;

        record = '0;
        record.valid = 1'b1;
        record.order_id = incoming.order_id;
        record.side = incoming.side;
        record.price = incoming.price;
        record.quantity = incoming.quantity;

        return record;
    endfunction

    // Validate decoded-event fields using the Python conventions.
    always_comb begin
        input_event_valid = 1'b0;

        case (event_data.event_type)

            EVENT_ADD: begin
                if (
                    (event_data.side == SIDE_BUY ||
                     event_data.side == SIDE_SELL) &&
                    event_data.quantity != 0 &&
                    event_data.price >= BASE_PRICE
                ) begin
                    input_event_valid =
                        ((event_data.price - BASE_PRICE) %
                            TICK_SIZE == 0) &&
                        ((event_data.price - BASE_PRICE) /
                            TICK_SIZE < PRICE_LEVELS);
                end
            end

            EVENT_EXECUTE,
            EVENT_CANCEL: begin
                input_event_valid =
                    event_data.side == SIDE_NONE &&
                    event_data.price == 0 &&
                    event_data.quantity != 0;
            end

            EVENT_DELETE: begin
                input_event_valid =
                    event_data.side == SIDE_NONE &&
                    event_data.price == 0 &&
                    event_data.quantity == 0;
            end

            default: begin
                input_event_valid = 1'b0;
            end

        endcase
    end

    // Calculate the replacement record for an existing order.
    // The FSM checks quantity bounds before using this result.
    always_comb begin
        updated_record = before_q;

        if (
            event_q.event_type == EVENT_DELETE ||
            event_q.quantity == before_q.quantity
        ) begin
            updated_record = '0;
        end else begin
            updated_record.quantity =
                before_q.quantity - event_q.quantity;
        end
    end

    assign event_ready =
        !rst &&
        !faulted &&
        store_ready &&
        state == IDLE;

    assign result_valid = !rst && state == RESPOND;

    assign result_success =
        result_valid && error_q == BOOK_OK;

    assign result_error = error_q;
    assign result_order_id = event_q.order_id;

    assign result_before = before_q;
    assign result_after = after_q;

    // Issue component requests only in their request states.
    always_comb begin
        lookup_req_valid = 1'b0;
        lookup_req_cmd = LOOKUP_FIND;

        alloc_req = 1'b0;
        free_req = 1'b0;

        store_read_en = 1'b0;
        store_write_en = 1'b0;

        if (!rst) begin
            case (state)

                FIND_REQ: begin
                    lookup_req_valid = 1'b1;
                    lookup_req_cmd = LOOKUP_FIND;
                end

                ALLOC_REQ: begin
                    alloc_req = !alloc_full;
                end

                INSERT_REQ: begin
                    lookup_req_valid = 1'b1;
                    lookup_req_cmd = LOOKUP_INSERT;
                end

                UNDO_ALLOC_REQ: begin
                    free_req = 1'b1;
                end

                READ_REQ: begin
                    store_read_en = store_ready;
                end

                REMOVE_REQ: begin
                    lookup_req_valid = 1'b1;
                    lookup_req_cmd = LOOKUP_REMOVE;
                end

                FREE_REQ: begin
                    free_req = 1'b1;
                end

                WRITE_RECORD: begin
                    store_write_en = store_ready;
                end

                default: begin
                end

            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;

            event_q <= '0;
            slot_q <= '0;

            before_q <= '0;
            after_q <= '0;

            error_q <= BOOK_OK;
            faulted <= 1'b0;

        end else begin
            case (state)

                IDLE: begin
                    if (event_valid && event_ready) begin
                        event_q <= event_data;

                        before_q <= '0;
                        after_q <= '0;
                        error_q <= BOOK_OK;

                        if (!input_event_valid) begin
                            error_q <= BOOK_BAD_EVENT;
                            state <= RESPOND;
                        end else begin
                            if (event_data.event_type == EVENT_ADD)
                                after_q <= make_add_record(event_data);

                            state <= FIND_REQ;
                        end
                    end
                end

                FIND_REQ: begin
                    state <= FIND_WAIT;
                end

                FIND_WAIT: begin
                    if (lookup_rsp_valid) begin

                        if (event_q.event_type == EVENT_ADD) begin
                            if (lookup_rsp_success) begin
                                error_q <= BOOK_DUPLICATE_ID;
                                state <= RESPOND;
                            end else begin
                                state <= ALLOC_REQ;
                            end

                        end else begin
                            if (!lookup_rsp_success) begin
                                error_q <= BOOK_UNKNOWN_ID;
                                state <= RESPOND;
                            end else begin
                                slot_q <= lookup_rsp_slot;
                                state <= READ_REQ;
                            end
                        end
                    end
                end

                ALLOC_REQ: begin
                    if (alloc_full) begin
                        error_q <= BOOK_FULL;
                        state <= RESPOND;
                    end else begin
                        state <= ALLOC_WAIT;
                    end
                end

                ALLOC_WAIT: begin
                    if (alloc_valid) begin
                        slot_q <= alloc_addr;
                        state <= INSERT_REQ;
                    end else if (alloc_error) begin
                        error_q <= BOOK_INTERNAL_ERROR;
                        faulted <= 1'b1;
                        state <= RESPOND;
                    end
                end

                INSERT_REQ: begin
                    state <= INSERT_WAIT;
                end

                INSERT_WAIT: begin
                    if (lookup_rsp_valid) begin
                        if (
                            lookup_rsp_success &&
                            lookup_rsp_slot == slot_q
                        ) begin
                            state <= WRITE_RECORD;
                        end else begin
                            // Return the reserved slot if insertion fails.
                            error_q <= BOOK_INTERNAL_ERROR;
                            faulted <= 1'b1;
                            state <= UNDO_ALLOC_REQ;
                        end
                    end
                end

                UNDO_ALLOC_REQ: begin
                    state <= UNDO_ALLOC_WAIT;
                end

                UNDO_ALLOC_WAIT: begin
                    if (free_valid || alloc_error)
                        state <= RESPOND;
                end

                READ_REQ: begin
                    if (store_ready)
                        state <= READ_WAIT;
                end

                READ_WAIT: begin
                    if (store_read_valid) begin
                        if (
                            !store_read_data.valid ||
                            store_read_data.order_id != event_q.order_id ||
                            store_read_data.quantity == 0 ||
                            (store_read_data.side != SIDE_BUY &&
                             store_read_data.side != SIDE_SELL)
                        ) begin
                            error_q <= BOOK_INTERNAL_ERROR;
                            faulted <= 1'b1;
                            state <= RESPOND;
                        end else begin
                            before_q <= store_read_data;
                            state <= PREPARE_UPDATE;
                        end
                    end
                end

                PREPARE_UPDATE: begin
                    if (
                        event_q.event_type != EVENT_DELETE &&
                        event_q.quantity > before_q.quantity
                    ) begin
                        error_q <= BOOK_BAD_QUANTITY;
                        state <= RESPOND;

                    end else begin
                        after_q <= updated_record;

                        if (updated_record.valid)
                            state <= WRITE_RECORD;
                        else
                            state <= REMOVE_REQ;
                    end
                end

                REMOVE_REQ: begin
                    state <= REMOVE_WAIT;
                end

                REMOVE_WAIT: begin
                    if (lookup_rsp_valid) begin
                        if (
                            lookup_rsp_success &&
                            lookup_rsp_slot == slot_q
                        ) begin
                            state <= FREE_REQ;
                        end else begin
                            error_q <= BOOK_INTERNAL_ERROR;
                            faulted <= 1'b1;
                            state <= RESPOND;
                        end
                    end
                end

                FREE_REQ: begin
                    state <= FREE_WAIT;
                end

                FREE_WAIT: begin
                    if (free_valid) begin
                        state <= WRITE_RECORD;
                    end else if (alloc_error) begin
                        error_q <= BOOK_INTERNAL_ERROR;
                        faulted <= 1'b1;
                        state <= RESPOND;
                    end
                end

                WRITE_RECORD: begin
                    if (store_ready)
                        state <= RESPOND;
                end

                RESPOND: begin
                    // Keep the response stable until it is accepted.
                    if (result_ready)
                        state <= IDLE;
                end

                default: begin
                    error_q <= BOOK_INTERNAL_ERROR;
                    faulted <= 1'b1;
                    state <= RESPOND;
                end

            endcase
        end
    end

endmodule