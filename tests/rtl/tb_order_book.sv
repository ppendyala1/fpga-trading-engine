// Planned role: Directed tests for order updates and error cases.

`timescale 1ns/1ps

module tb_order_book;

    import trading_types_pkg::*;

    localparam int unsigned DEPTH = 16;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst;

    logic event_valid;
    logic event_ready;
    market_event_t event_data;

    logic result_valid;
    logic result_ready;
    logic result_success;

    book_error_t result_error;
    order_id_t result_order_id;
    order_record_t result_before;
    order_record_t result_after;

    logic faulted;
    bbo_t result_bbo;
    logic result_bbo_valid;

    level_quantity_t expected_bids [0:PRICE_LEVELS-1];
    level_quantity_t expected_asks [0:PRICE_LEVELS-1];

    int unsigned checks = 0;

    trading_core #(
        .DEPTH(DEPTH)
    ) dut (
        .depth_address(9'd0),.depth_quantity(),
        .clk,
        .rst,

        .event_valid,
        .event_ready,
        .event_data,

        .result_valid,
        .result_ready,
        .result_success,
        .result_error,
        .result_order_id,
        .result_before,
        .result_after,

        .result_bbo,
        .result_bbo_valid,
        .faulted
    );

    function automatic market_event_t make_event(
        input event_type_t kind,
        input order_id_t id,
        input quantity_t quantity,
        input side_t side,
        input price_t price
    );
        market_event_t event_value;

        event_value = '0;
        event_value.event_type = kind;
        event_value.order_id = id;
        event_value.quantity = quantity;
        event_value.side = side;
        event_value.price = price;

        return event_value;
    endfunction

    function automatic order_record_t make_record(
        input order_id_t id,
        input side_t side,
        input price_t price,
        input quantity_t quantity
    );
        order_record_t record;

        record = '0;

        if (quantity != 0) begin
            record.valid = 1'b1;
            record.order_id = id;
            record.side = side;
            record.price = price;
            record.quantity = quantity;
        end

        return record;
    endfunction

    function automatic bbo_t expected_bbo_value();
        logic bv, av;
        price_t bp, ap;
        level_quantity_t bq, aq;
        bv=0;av=0;bp=0;ap=0;bq=0;aq=0;

        for (int unsigned i = 0; i < PRICE_LEVELS; i++) begin
            if (expected_bids[i] != 0) begin
                bv=1; bp=BASE_PRICE+i*TICK_SIZE; bq=expected_bids[i];
            end

            if (expected_asks[i] != 0 && !av) begin
                av=1; ap=BASE_PRICE+i*TICK_SIZE; aq=expected_asks[i];
            end
        end

        return {bv,bp,bq,av,ap,aq};
    endfunction

    task automatic reset_book;
        int unsigned cycles;

        @(negedge clk);
        rst = 1'b1;

        for (int unsigned i = 0; i < PRICE_LEVELS; i++) begin
            expected_bids[i] = 0;
            expected_asks[i] = 0;
        end

        event_valid = 1'b0;
        result_ready = 1'b0;

        repeat (2) @(posedge clk);

        @(negedge clk);
        rst = 1'b0;

        cycles = 0;

        while (event_ready !== 1'b1) begin
            @(negedge clk);
            cycles++;

            if (cycles > DEPTH + 10)
                $fatal(1, "Initialization timeout");

            if (faulted !== 1'b0)
                $fatal(1, "Unexpected fault during initialization");
        end
    endtask

    task automatic send_and_check(
        input market_event_t incoming,
        input book_error_t expected_error,
        input order_record_t expected_before,
        input order_record_t expected_after
    );
        int unsigned cycles;
        int unsigned index;

        bbo_t held_bbo;
        order_id_t held_id;
        book_error_t held_error;
        logic held_success;
        order_record_t held_before;
        order_record_t held_after;

        @(negedge clk);
        event_data = incoming;
        event_valid = 1'b1;
        result_ready = 1'b0;

        // Sample ready at the accepting edge, before NBA updates.
        cycles = 0;

        do begin
            @(posedge clk);
            cycles++;

            if (cycles > 200)
                $fatal(1, "Input handshake timeout");

        end while (event_ready !== 1'b1);

        @(negedge clk);
        event_valid = 1'b0;

        cycles = 0;

        while (result_valid !== 1'b1) begin
            @(negedge clk);
            cycles++;

            if (cycles > 200)
                $fatal(1, "Result timeout");

            if (faulted !== 1'b0)
                $fatal(1, "Unexpected internal fault");
        end

        checks++;

        if (faulted !== 1'b0)
            $fatal(1, "Check %0d: unexpected fault", checks);

        if (result_order_id !== incoming.order_id)
            $fatal(1, "Check %0d: wrong result order ID", checks);

        if (result_error !== expected_error)
            $fatal(
                1,
                "Check %0d: expected error %0d, got %0d",
                checks, expected_error, result_error
            );

        if (result_success !== (expected_error == BOOK_OK))
            $fatal(
                1,
                "Check %0d: incorrect success flag",
                checks
            );

        // Before/after records are only meaningful on success.
        if (expected_error == BOOK_OK) begin
            if (result_before !== expected_before)
                $fatal(
                    1,
                    "Check %0d: before expected %h, got %h",
                    checks, expected_before, result_before
                );

            if (result_after !== expected_after)
                $fatal(
                    1,
                    "Check %0d: after expected %h, got %h",
                    checks, expected_after, result_after
                );
        end

        // Build expected level totals from expected records,
        // independently of the DUT's returned records.
        if (expected_error == BOOK_OK) begin
            if (expected_before.valid) begin
                index =
                    (expected_before.price - BASE_PRICE) / TICK_SIZE;

                if (expected_before.side == SIDE_BUY)
                    expected_bids[index] -=
                        level_quantity_t'(expected_before.quantity);
                else
                    expected_asks[index] -=
                        level_quantity_t'(expected_before.quantity);
            end

            if (expected_after.valid) begin
                index =
                    (expected_after.price - BASE_PRICE) / TICK_SIZE;

                if (expected_after.side == SIDE_BUY)
                    expected_bids[index] +=
                        level_quantity_t'(expected_after.quantity);
                else
                    expected_asks[index] +=
                        level_quantity_t'(expected_after.quantity);
            end
        end

        // Rejected events must preserve the previous BBO.
        if (result_bbo_valid !== 1'b1)
            $fatal(1, "Missing valid BBO snapshot");

        if (result_bbo !== expected_bbo_value())
            $fatal(
                1,
                "Check %0d: BBO mismatch: expected %h, got %h",
                checks, expected_bbo_value(), result_bbo
            );

        held_bbo = result_bbo;
        held_id = result_order_id;
        held_error = result_error;
        held_success = result_success;
        held_before = result_before;
        held_after = result_after;

        // Apply output backpressure for three cycles.
        repeat (3) begin
            @(posedge clk);
            #1;

            if (result_valid !== 1'b1)
                $fatal(1, "Result disappeared under backpressure");

            if (event_ready !== 1'b0)
                $fatal(
                    1,
                    "Controller accepted input while holding result"
                );

            if (
                result_order_id !== held_id ||
                result_error !== held_error ||
                result_success !== held_success ||
                result_before !== held_before ||
                result_after !== held_after
            )
                $fatal(1, "Result changed under backpressure");

            if (
                result_bbo_valid !== 1'b1 ||
                result_bbo !== held_bbo
            )
                $fatal(1, "BBO changed under backpressure");

            if (faulted !== 1'b0)
                $fatal(1, "Unexpected fault under backpressure");
        end

        // Accept the result.
        @(negedge clk);
        result_ready = 1'b1;

        @(posedge clk);
        #1;

        if (result_valid !== 1'b0)
            $fatal(1, "Result did not retire");

        @(negedge clk);
        result_ready = 1'b0;
    endtask

    task automatic add_order(
        input order_id_t id,
        input side_t side,
        input price_t price,
        input quantity_t quantity
    );
        send_and_check(
            make_event(EVENT_ADD, id, quantity, side, price),
            BOOK_OK,
            '0,
            make_record(id, side, price, quantity)
        );
    endtask

    task automatic delete_order(
        input order_id_t id,
        input side_t side,
        input price_t price,
        input quantity_t quantity
    );
        send_and_check(
            make_event(EVENT_DELETE, id, 0, SIDE_NONE, 0),
            BOOK_OK,
            make_record(id, side, price, quantity),
            '0
        );
    endtask

    initial begin
        rst = 1'b1;
        event_valid = 1'b0;
        event_data = '0;
        result_ready = 1'b0;

        reset_book();

        // Add a buy order.
        add_order(42, SIDE_BUY, BASE_PRICE, 100);

        // Duplicate Add must not overwrite the original record.
        send_and_check(
            make_event(
                EVENT_ADD, 42, 999,
                SIDE_SELL, BASE_PRICE + TICK_SIZE
            ),
            BOOK_DUPLICATE_ID, '0, '0
        );

        // Partial Execute: 100 -> 70.
        send_and_check(
            make_event(EVENT_EXECUTE, 42, 30, SIDE_NONE, 0),
            BOOK_OK,
            make_record(42, SIDE_BUY, BASE_PRICE, 100),
            make_record(42, SIDE_BUY, BASE_PRICE, 70)
        );

        // Too-large reduction must leave the order unchanged.
        send_and_check(
            make_event(EVENT_CANCEL, 42, 71, SIDE_NONE, 0),
            BOOK_BAD_QUANTITY, '0, '0
        );

        // Partial Cancel: 70 -> 50.
        send_and_check(
            make_event(EVENT_CANCEL, 42, 20, SIDE_NONE, 0),
            BOOK_OK,
            make_record(42, SIDE_BUY, BASE_PRICE, 70),
            make_record(42, SIDE_BUY, BASE_PRICE, 50)
        );

        // Different orders may share a price.
        add_order(43, SIDE_BUY, BASE_PRICE, 25);
        add_order(44, SIDE_SELL, BASE_PRICE + 2*TICK_SIZE, 80);

        // Delete removes all remaining shares.
        delete_order(42, SIDE_BUY, BASE_PRICE, 50);

        send_and_check(
            make_event(EVENT_EXECUTE, 42, 1, SIDE_NONE, 0),
            BOOK_UNKNOWN_ID, '0, '0
        );

        // Full Execute removes the order.
        send_and_check(
            make_event(EVENT_EXECUTE, 43, 25, SIDE_NONE, 0),
            BOOK_OK,
            make_record(43, SIDE_BUY, BASE_PRICE, 25),
            '0
        );

        // Full Cancel also removes the order.
        send_and_check(
            make_event(EVENT_CANCEL, 44, 80, SIDE_NONE, 0),
            BOOK_OK,
            make_record(
                44, SIDE_SELL, BASE_PRICE + 2*TICK_SIZE, 80
            ),
            '0
        );

        // A removed order ID may be reused.
        add_order(42, SIDE_SELL, BASE_PRICE + TICK_SIZE, 9);
        delete_order(42, SIDE_SELL, BASE_PRICE + TICK_SIZE, 9);

        // Zero is a valid order ID.
        // IDs with identical low 48 bits must remain distinct.
        add_order(64'h000100000000002a, SIDE_BUY, BASE_PRICE, 10);
        add_order(64'h000200000000002a, SIDE_SELL, BASE_PRICE+TICK_SIZE, 20);
        delete_order(64'h000100000000002a, SIDE_BUY, BASE_PRICE, 10);
        delete_order(64'h000200000000002a, SIDE_SELL, BASE_PRICE+TICK_SIZE, 20);
        add_order(64'hffffffffffffffff, SIDE_BUY, BASE_PRICE, 1);
        delete_order(64'hffffffffffffffff, SIDE_BUY, BASE_PRICE, 1);

        // Zero is a valid order ID.
        add_order(0, SIDE_BUY, BASE_PRICE, 1);
        delete_order(0, SIDE_BUY, BASE_PRICE, 1);

        // Invalid event formats.
        send_and_check(
            make_event(EVENT_ADD, 90, 0, SIDE_BUY, BASE_PRICE),
            BOOK_BAD_EVENT, '0, '0
        );

        send_and_check(
            make_event(EVENT_ADD, 90, 10, SIDE_NONE, BASE_PRICE),
            BOOK_BAD_EVENT, '0, '0
        );

        send_and_check(
            make_event(
                EVENT_ADD, 90, 10, SIDE_BUY, BASE_PRICE + 1
            ),
            BOOK_BAD_EVENT, '0, '0
        );

        send_and_check(
            make_event(
                EVENT_ADD, 90, 10, SIDE_BUY,
                BASE_PRICE + PRICE_LEVELS*TICK_SIZE
            ),
            BOOK_BAD_EVENT, '0, '0
        );

        send_and_check(
            make_event(EVENT_DELETE, 90, 1, SIDE_NONE, 0),
            BOOK_BAD_EVENT, '0, '0
        );

        send_and_check(
            make_event(EVENT_EXECUTE, 90, 1, SIDE_BUY, 0),
            BOOK_BAD_EVENT, '0, '0
        );

        send_and_check(
            make_event(
                event_type_t'(8'hFF), 90, 0, SIDE_NONE, 0
            ),
            BOOK_BAD_EVENT, '0, '0
        );

        // Correctly formatted request for a missing order.
        send_and_check(
            make_event(EVENT_DELETE, 90, 0, SIDE_NONE, 0),
            BOOK_UNKNOWN_ID, '0, '0
        );

        // Fill the complete configured order capacity.
        for (int unsigned i = 0; i < DEPTH; i++) begin
            add_order(
                order_id_t'(1000) + order_id_t'(i),
                SIDE_BUY,
                BASE_PRICE + i*TICK_SIZE,
                quantity_t'(i + 1)
            );
        end

        send_and_check(
            make_event(
                EVENT_ADD, 9000, 77, SIDE_SELL, BASE_PRICE
            ),
            BOOK_FULL, '0, '0
        );

        // Duplicate detection takes priority over capacity.
        send_and_check(
            make_event(
                EVENT_ADD, 1000, 77, SIDE_SELL, BASE_PRICE
            ),
            BOOK_DUPLICATE_ID, '0, '0
        );

        // Release a slot, then successfully allocate again.
        delete_order(
            1005, SIDE_BUY, BASE_PRICE + 5*TICK_SIZE, 6
        );

        add_order(9000, SIDE_SELL, BASE_PRICE, 77);

        // Drain all remaining orders.
        for (int unsigned i = 0; i < DEPTH; i++) begin
            if (i != 5) begin
                delete_order(
                    order_id_t'(1000) + order_id_t'(i),
                    SIDE_BUY,
                    BASE_PRICE + i*TICK_SIZE,
                    quantity_t'(i + 1)
                );
            end
        end

        delete_order(9000, SIDE_SELL, BASE_PRICE, 77);

        // Exercise BBO selection across group boundaries.
        add_order(600, SIDE_BUY, BASE_PRICE + 15*TICK_SIZE, 10);
        add_order(601, SIDE_BUY, BASE_PRICE + 16*TICK_SIZE, 20);
        add_order(602, SIDE_BUY, BASE_PRICE + 255*TICK_SIZE, 30);

        add_order(603, SIDE_SELL, BASE_PRICE + 255*TICK_SIZE, 40);
        add_order(604, SIDE_SELL, BASE_PRICE + 16*TICK_SIZE, 50);
        add_order(605, SIDE_SELL, BASE_PRICE + 15*TICK_SIZE, 60);

        delete_order(
            602, SIDE_BUY, BASE_PRICE + 255*TICK_SIZE, 30
        );
        delete_order(
            605, SIDE_SELL, BASE_PRICE + 15*TICK_SIZE, 60
        );
        delete_order(
            601, SIDE_BUY, BASE_PRICE + 16*TICK_SIZE, 20
        );
        delete_order(
            604, SIDE_SELL, BASE_PRICE + 16*TICK_SIZE, 50
        );
        delete_order(
            600, SIDE_BUY, BASE_PRICE + 15*TICK_SIZE, 10
        );
        delete_order(
            603, SIDE_SELL, BASE_PRICE + 255*TICK_SIZE, 40
        );

        // Aggregate quantities must exceed 32 bits without wrapping.
        add_order(700, SIDE_BUY, BASE_PRICE, 32'hFFFFFFFF);
        add_order(701, SIDE_BUY, BASE_PRICE, 32'hFFFFFFFF);

        delete_order(700, SIDE_BUY, BASE_PRICE, 32'hFFFFFFFF);
        delete_order(701, SIDE_BUY, BASE_PRICE, 32'hFFFFFFFF);

        // Reset a populated book.
        add_order(500, SIDE_BUY, BASE_PRICE, 10);

        reset_book();

        send_and_check(
            make_event(EVENT_EXECUTE, 500, 1, SIDE_NONE, 0),
            BOOK_UNKNOWN_ID, '0, '0
        );

        // Verify operation resumes after reset.
        add_order(500, SIDE_BUY, BASE_PRICE, 20);
        delete_order(500, SIDE_BUY, BASE_PRICE, 20);

        $display(
            "PASS: order_book tests completed (%0d events)",
            checks
        );

        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "Global simulation timeout");
    end

endmodule
