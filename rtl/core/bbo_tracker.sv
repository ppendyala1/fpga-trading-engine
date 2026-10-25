// Planned role: Best bid and best ask tracking.
module bbo_tracker (
    input logic clk,
    input logic rst,

    // Feed successful order-book updates into this interface.
    input logic update_valid,
    output logic update_ready,

    input trading_types_pkg::order_record_t update_before,
    input trading_types_pkg::order_record_t update_after,

    // Updated BBO response.
    output logic result_valid,
    input logic result_ready,

    output logic result_error,
    output trading_types_pkg::bbo_t result_bbo
);

    import trading_types_pkg::*;

    localparam int unsigned INDEX_WIDTH = $clog2(PRICE_LEVELS);

    // Split BBO selection into groups, then combine group results.
    localparam int unsigned GROUP_SIZE = 16;
    localparam int unsigned GROUP_COUNT =
        (PRICE_LEVELS + GROUP_SIZE - 1) / GROUP_SIZE;

    typedef enum logic [1:0] {
        IDLE,
        CAPTURE_GROUPS,
        MERGE_GROUPS,
        RESPOND
    } state_t;

    state_t state;

    // Register-backed aggregate quantity at each supported price.
    level_quantity_t bid_quantity [0:PRICE_LEVELS-1];
    level_quantity_t ask_quantity [0:PRICE_LEVELS-1];

    bbo_t group_comb [0:GROUP_COUNT-1];
    bbo_t group_q [0:GROUP_COUNT-1];

    bbo_t merged_bbo;
    bbo_t bbo_q;

    order_record_t anchor_record;
    logic [INDEX_WIDTH-1:0] level_index;

    level_quantity_t current_total;
    level_quantity_t old_quantity;
    level_quantity_t new_quantity;

    logic [64:0] next_total;
    logic transaction_ok;
    logic update_ok;
    logic error_q;

    function automatic logic price_ok(input price_t price);
        if (price < BASE_PRICE)
            return 1'b0;

        return (
            ((price - BASE_PRICE) % TICK_SIZE == 0) &&
            ((price - BASE_PRICE) / TICK_SIZE < PRICE_LEVELS)
        );
    endfunction

    function automatic logic record_ok(
        input order_record_t record
    );
        // Fields of an invalid record are ignored.
        if (!record.valid)
            return 1'b1;

        return (
            (record.side == SIDE_BUY || record.side == SIDE_SELL) &&
            record.quantity != 0 &&
            price_ok(record.price)
        );
    endfunction

    // Validate and calculate one price-level update.
    always_comb begin
        // Existing orders identify the affected level.
        // For Add, use the newly created order.
        anchor_record = update_before.valid
            ? update_before
            : update_after;

        level_index = '0;

        if (price_ok(anchor_record.price)) begin
            level_index = INDEX_WIDTH'(
                (anchor_record.price - BASE_PRICE) / TICK_SIZE
            );
        end

        old_quantity = update_before.valid
            ? {32'd0, update_before.quantity}
            : 64'd0;

        new_quantity = update_after.valid
            ? {32'd0, update_after.quantity}
            : 64'd0;

        current_total = (anchor_record.side == SIDE_BUY)
            ? bid_quantity[level_index]
            : ask_quantity[level_index];

        // Extra bit detects aggregate overflow.
        next_total =
            {1'b0, current_total} -
            {1'b0, old_quantity} +
            {1'b0, new_quantity};

        transaction_ok =
            record_ok(update_before) &&
            record_ok(update_after) &&
            (update_before.valid || update_after.valid);

        // A partial Execute/Cancel must preserve ID, side, and price,
        // and reduce the order quantity.
        if (update_before.valid && update_after.valid) begin
            transaction_ok =
                transaction_ok &&
                update_before.order_id == update_after.order_id &&
                update_before.side == update_after.side &&
                update_before.price == update_after.price &&
                update_after.quantity < update_before.quantity;
        end

        update_ok =
            transaction_ok &&
            current_total >= old_quantity &&
            !next_total[64];
    end

    // First selection stage: find BBO within each group.
    always_comb begin
        for (int unsigned g = 0; g < GROUP_COUNT; g++) begin
            group_comb[g] = '0;

            for (int unsigned j = 0; j < GROUP_SIZE; j++) begin
                if (g * GROUP_SIZE + j < PRICE_LEVELS) begin

                    // Ascending scan: last occupied bid wins.
                    if (bid_quantity[g * GROUP_SIZE + j] != 0) begin
                        group_comb[g].bid_valid = 1'b1;

                        group_comb[g].bid_price =
                            BASE_PRICE +
                            price_t'(
                                (g * GROUP_SIZE + j) * TICK_SIZE
                            );

                        group_comb[g].bid_quantity =
                            bid_quantity[g * GROUP_SIZE + j];
                    end

                    // Ascending scan: first occupied ask wins.
                    if (
                        ask_quantity[g * GROUP_SIZE + j] != 0 &&
                        !group_comb[g].ask_valid
                    ) begin
                        group_comb[g].ask_valid = 1'b1;

                        group_comb[g].ask_price =
                            BASE_PRICE +
                            price_t'(
                                (g * GROUP_SIZE + j) * TICK_SIZE
                            );

                        group_comb[g].ask_quantity =
                            ask_quantity[g * GROUP_SIZE + j];
                    end
                end
            end
        end
    end

    // Second selection stage: combine registered group results.
    always_comb begin
        merged_bbo = '0;

        for (int unsigned g = 0; g < GROUP_COUNT; g++) begin
            if (group_q[g].bid_valid) begin
                merged_bbo.bid_valid = 1'b1;
                merged_bbo.bid_price = group_q[g].bid_price;
                merged_bbo.bid_quantity = group_q[g].bid_quantity;
            end

            if (
                group_q[g].ask_valid &&
                !merged_bbo.ask_valid
            ) begin
                merged_bbo.ask_valid = 1'b1;
                merged_bbo.ask_price = group_q[g].ask_price;
                merged_bbo.ask_quantity = group_q[g].ask_quantity;
            end
        end
    end

    assign update_ready = !rst && state == IDLE;
    assign result_valid = !rst && state == RESPOND;

    assign result_error = error_q;
    assign result_bbo = bbo_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            error_q <= 1'b0;
            bbo_q <= '0;

            // Whole-array reset keeps the register-based implementation and
            // avoids simulator-dependent loop unrolling for nonblocking writes.
            bid_quantity <= '{default:'0};
            ask_quantity <= '{default:'0};

            for (int unsigned g = 0; g < GROUP_COUNT; g++)
                group_q[g] <= '0;

        end else begin
            case (state)

                IDLE: begin
                    if (update_valid && update_ready) begin
                        error_q <= !update_ok;

                        if (update_ok) begin
                            if (anchor_record.side == SIDE_BUY)
                                bid_quantity[level_index] <=
                                    next_total[63:0];
                            else
                                ask_quantity[level_index] <=
                                    next_total[63:0];
                        end

                        // Also report unchanged BBO on rejected updates.
                        state <= CAPTURE_GROUPS;
                    end
                end

                CAPTURE_GROUPS: begin
                    // Quantities now include the accepted update.
                    for (int unsigned g = 0; g < GROUP_COUNT; g++)
                        group_q[g] <= group_comb[g];

                    state <= MERGE_GROUPS;
                end

                MERGE_GROUPS: begin
                    bbo_q <= merged_bbo;
                    state <= RESPOND;
                end

                RESPOND: begin
                    // Hold BBO and error status until consumed.
                    if (result_ready)
                        state <= IDLE;
                end

                default: begin
                    error_q <= 1'b1;
                    state <= RESPOND;
                end

            endcase
        end
    end

endmodule