module order_store #(
    parameter int unsigned DEPTH = trading_types_pkg::MAX_ORDERS
) (
    input  logic clk,
    input  logic rst,

    // Low while reset is clearing the memory.
    output logic ready,

    input  logic write_en,
    input  logic [$clog2(DEPTH)-1:0] write_addr,
    input  trading_types_pkg::order_record_t write_data,

    input  logic read_en,
    input  logic [$clog2(DEPTH)-1:0] read_addr,
    output logic read_valid,
    output trading_types_pkg::order_record_t read_data
);

    import trading_types_pkg::*;

    localparam int unsigned ADDR_WIDTH = $clog2(DEPTH);
    localparam int unsigned DATA_WIDTH = $bits(order_record_t);

    // Synchronous memory access permits block RAM inference.
    (* ram_style = "block" *)
    logic [DATA_WIDTH-1:0] memory [0:DEPTH-1];

    logic clearing;
    logic [ADDR_WIDTH-1:0] clear_addr;

    logic [DATA_WIDTH-1:0] ram_read_q;

    // Forward the new record when reading and writing the same slot.
    logic forward_valid_q;
    order_record_t forward_data_q;

    assign ready = !rst && !clearing;

    // Require a power-of-two depth of at least two.
    // synthesis translate_off
    initial begin
        if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0)
            $fatal(1, "DEPTH must be a power of two and at least 2");
    end
    // synthesis translate_on

    // Clear one slot per cycle rather than resetting the entire
    // memory array in one clock cycle.
    always_ff @(posedge clk) begin
        if (rst) begin
            clearing  <= 1'b1;
            clear_addr <= '0;
        end else if (clearing) begin
            if (clear_addr == ADDR_WIDTH'(DEPTH - 1)) begin
                clearing <= 1'b0;
            end else begin
                clear_addr <= clear_addr + 1'b1;
            end
        end
    end

    // Memory write port.
    always_ff @(posedge clk) begin
        if (!rst) begin
            if (clearing) begin
                memory[clear_addr] <= '0;
            end else if (write_en) begin
                memory[write_addr] <= write_data;
            end
        end
    end

    // Memory read port.
    always_ff @(posedge clk) begin
        if (ready && read_en)
            ram_read_q <= memory[read_addr];
    end

    // Register read completion and collision forwarding.
    always_ff @(posedge clk) begin
        if (rst) begin
            read_valid      <= 1'b0;
            forward_valid_q <= 1'b0;
            forward_data_q  <= '0;
        end else begin
            read_valid      <= ready && read_en;
            forward_valid_q <= 1'b0;

            if (ready && read_en) begin
                forward_valid_q <=
                    write_en && (write_addr == read_addr);

                if (write_en && (write_addr == read_addr))
                    forward_data_q <= write_data;
            end
        end
    end

    always_comb begin
        read_data = '0;

        if (read_valid) begin
            if (forward_valid_q)
                read_data = forward_data_q;
            else
                read_data = order_record_t'(ram_read_q);
        end
    end

endmodule