module slot_allocator #(
    parameter int unsigned DEPTH = trading_types_pkg::MAX_ORDERS
) (
    input logic clk,
    input logic rst,

    // Request one unused slot.
    input logic alloc_req,
    output logic alloc_valid,
    output logic [$clog2(DEPTH)-1:0] alloc_addr,

    // Return an allocated slot.
    input logic free_req,
    input logic [$clog2(DEPTH)-1:0] free_addr,
    output logic free_valid,

    // Pulses for a rejected request.
    output logic op_error,

    output logic full,
    output logic [$clog2(DEPTH+1)-1:0] used_count
);

    localparam int unsigned ADDR_WIDTH = $clog2(DEPTH);
    localparam int unsigned COUNT_WIDTH = $clog2(DEPTH + 1);

    // A one means that the slot is currently allocated.
    logic [DEPTH-1:0] allocated;

    logic free_found;
    logic [ADDR_WIDTH-1:0] next_free_addr;

    // synthesis translate_off
    initial begin
        if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0)
            $fatal(1, "DEPTH must be a power of two and at least 2");
    end
    // synthesis translate_on

    assign full = (used_count == COUNT_WIDTH'(DEPTH));

    // Same deterministic lowest-free policy, with logarithmic selection depth.
    priority_encoder #(.WIDTH(DEPTH)) select_free(
        .bits_in(~allocated),.found(free_found),.index(next_free_addr));

    always_ff @(posedge clk) begin
        if (rst) begin
            allocated   <= '0;
            used_count  <= '0;
            alloc_valid <= 1'b0;
            alloc_addr  <= '0;
            free_valid  <= 1'b0;
            op_error    <= 1'b0;
        end else begin
            // Responses are pulses for this cycle's requests.
            alloc_valid <= 1'b0;
            free_valid  <= 1'b0;
            op_error    <= 1'b0;

            // First version accepts at most one operation per cycle.
            // Reject simultaneous requests without changing state.
            if (alloc_req && free_req) begin
                op_error <= 1'b1;

            end else if (alloc_req) begin
                if (free_found) begin
                    allocated[next_free_addr] <= 1'b1;
                    used_count <= used_count + 1'b1;

                    alloc_addr  <= next_free_addr;
                    alloc_valid <= 1'b1;
                end else begin
                    op_error <= 1'b1;
                end

            end else if (free_req) begin
                if (allocated[free_addr]) begin
                    allocated[free_addr] <= 1'b0;
                    used_count <= used_count - 1'b1;
                    free_valid <= 1'b1;
                end else begin
                    // Includes double-free requests.
                    op_error <= 1'b1;
                end
            end
        end
    end

endmodule
