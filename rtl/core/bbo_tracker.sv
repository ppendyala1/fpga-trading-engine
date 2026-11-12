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
    output trading_types_pkg::bbo_t result_bbo,
    input logic [8:0] depth_address,
    output trading_types_pkg::level_quantity_t depth_quantity
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
    // Updates and snapshots are serialized. Share the expensive 512x64 read
    // mux rather than creating a second full aggregate-array read port.
    logic [8:0] aggregate_address;

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
    logic [GROUP_SIZE-1:0] bid_mask[0:GROUP_COUNT-1],ask_mask[0:GROUP_COUNT-1];
    logic [3:0] bid_reverse_index[0:GROUP_COUNT-1],ask_index[0:GROUP_COUNT-1];
    logic [3:0] bid_index[0:GROUP_COUNT-1];
    logic bid_found[0:GROUP_COUNT-1],ask_found[0:GROUP_COUNT-1];
    logic [GROUP_COUNT-1:0] bid_groups,ask_groups;
    logic [3:0] bid_group_reverse,ask_group_index,bid_group_index;
    logic any_bid,any_ask;
    assign aggregate_address = update_valid
        ? {(anchor_record.side==SIDE_SELL),level_index} : depth_address;
    assign depth_quantity = aggregate_address[8]
        ? ask_quantity[aggregate_address[7:0]] : bid_quantity[aggregate_address[7:0]];

    for(genvar g=0;g<GROUP_COUNT;g++) begin: select_group
        for(genvar j=0;j<GROUP_SIZE;j++) begin: occupied
            assign bid_mask[g][GROUP_SIZE-1-j]=(bid_quantity[g*GROUP_SIZE+j]!=0);
            assign ask_mask[g][j]=(ask_quantity[g*GROUP_SIZE+j]!=0);
        end
        priority_encoder #(.WIDTH(GROUP_SIZE)) bids(.bits_in(bid_mask[g]),.found(bid_found[g]),.index(bid_reverse_index[g]));
        priority_encoder #(.WIDTH(GROUP_SIZE)) asks(.bits_in(ask_mask[g]),.found(ask_found[g]),.index(ask_index[g]));
        assign bid_index[g]=4'd15-bid_reverse_index[g];
        assign bid_groups[GROUP_COUNT-1-g]=group_q[g].bid_valid;
        assign ask_groups[g]=group_q[g].ask_valid;
    end
    priority_encoder #(.WIDTH(GROUP_COUNT)) top_bid(.bits_in(bid_groups),.found(any_bid),.index(bid_group_reverse));
    priority_encoder #(.WIDTH(GROUP_COUNT)) top_ask(.bits_in(ask_groups),.found(any_ask),.index(ask_group_index));
    assign bid_group_index=4'd15-bid_group_reverse;

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

        current_total = depth_quantity;

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

    // First selection stage: encode occupancy, then use binary data selection.
    // Avoid a priority mux cascade for every bit of every 64-bit quantity.
    always_comb begin
        for (int unsigned g = 0; g < GROUP_COUNT; g++) begin
            group_comb[g] = '0;
            if(bid_found[g]) begin
                group_comb[g].bid_valid=1;
                group_comb[g].bid_price=BASE_PRICE+price_t'((g*GROUP_SIZE+bid_index[g])*TICK_SIZE);
                group_comb[g].bid_quantity=bid_quantity[g*GROUP_SIZE+bid_index[g]];
            end
            if(ask_found[g]) begin
                group_comb[g].ask_valid=1;
                group_comb[g].ask_price=BASE_PRICE+price_t'((g*GROUP_SIZE+ask_index[g])*TICK_SIZE);
                group_comb[g].ask_quantity=ask_quantity[g*GROUP_SIZE+ask_index[g]];
            end
        end
    end

    // Second selection stage: combine registered group results.
    always_comb begin
        merged_bbo = '0;

        if(any_bid) begin
            merged_bbo.bid_valid=1;
            merged_bbo.bid_price=group_q[bid_group_index].bid_price;
            merged_bbo.bid_quantity=group_q[bid_group_index].bid_quantity;
        end
        if(any_ask) begin
            merged_bbo.ask_valid=1;
            merged_bbo.ask_price=group_q[ask_group_index].ask_price;
            merged_bbo.ask_quantity=group_q[ask_group_index].ask_quantity;
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
