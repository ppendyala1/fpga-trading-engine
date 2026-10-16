module order_lookup #(
    parameter int unsigned DEPTH = trading_types_pkg::MAX_ORDERS
) (
    input logic clk,
    input logic rst,

    // One request may be submitted each clock cycle.
    input logic req_valid,
    input trading_types_pkg::lookup_cmd_t req_cmd,
    input trading_types_pkg::order_id_t req_order_id,

    // Used only by INSERT: slot supplied by the allocator.
    input logic [$clog2(DEPTH)-1:0] req_slot,

    // Registered response to the sampled request.
    output logic rsp_valid,
    output logic rsp_success,
    output logic [$clog2(DEPTH)-1:0] rsp_slot
);

    import trading_types_pkg::*;

    localparam int unsigned ADDR_WIDTH = $clog2(DEPTH);

    // Each table entry corresponds directly to an order-memory slot.
    order_id_t order_ids [0:DEPTH-1];
    logic [DEPTH-1:0] slot_valid;

    logic match_found;
    logic [ADDR_WIDTH-1:0] match_slot;

    // synthesis translate_off
    initial begin
        if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0)
            $fatal(1, "DEPTH must be a power of two and at least 2");
    end
    // synthesis translate_on

    // Compare the requested full 64-bit ID against active entries.
    always_comb begin
        match_found = 1'b0;
        match_slot = '0;

        for (int unsigned i = 0; i < DEPTH; i++) begin
            if (slot_valid[i] &&
                order_ids[i] == req_order_id &&
                !match_found) begin

                match_found = 1'b1;
                match_slot = ADDR_WIDTH'(i);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            slot_valid  <= '0;
            rsp_valid   <= 1'b0;
            rsp_success <= 1'b0;
            rsp_slot    <= '0;

            // IDs need no reset: slot_valid determines whether
            // an entry participates in lookup.
        end else begin
            rsp_valid   <= req_valid;
            rsp_success <= 1'b0;
            rsp_slot    <= '0;

            if (req_valid) begin
                case (req_cmd)

                    LOOKUP_FIND: begin
                        if (match_found) begin
                            rsp_success <= 1'b1;
                            rsp_slot <= match_slot;
                        end
                    end

                    LOOKUP_INSERT: begin
                        // Reject duplicate IDs and occupied slots.
                        if (!match_found && !slot_valid[req_slot]) begin
                            order_ids[req_slot] <= req_order_id;
                            slot_valid[req_slot] <= 1'b1;

                            rsp_success <= 1'b1;
                            rsp_slot <= req_slot;
                        end
                    end

                    LOOKUP_REMOVE: begin
                        if (match_found) begin
                            slot_valid[match_slot] <= 1'b0;

                            rsp_success <= 1'b1;
                            rsp_slot <= match_slot;
                        end
                    end

                    default: begin
                        // Invalid command: unsuccessful response,
                        // with no table changes.
                        rsp_success <= 1'b0;
                    end

                endcase
            end
        end
    end

endmodule