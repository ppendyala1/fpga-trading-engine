// Planned role: Clock-domain crossing for received data.

module async_fifo #(
    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned DEPTH = 1024
) (
    // Common reset: clears both sides and discards queued data.
    input logic arst,

    // Write-clock domain.
    input logic wr_clk,
    input logic wr_en,
    input logic [DATA_WIDTH-1:0] wr_data,
    output logic wr_full,

    // Read-clock domain.
    input logic rd_clk,
    input logic rd_en,
    output logic [DATA_WIDTH-1:0] rd_data,
    output logic rd_valid,
    output logic rd_empty
);

    localparam int unsigned ADDR_WIDTH = $clog2(DEPTH);
    localparam int unsigned PTR_WIDTH = ADDR_WIDTH + 1;

    logic [DATA_WIDTH-1:0] memory [0:DEPTH-1];

    logic [PTR_WIDTH-1:0] wr_bin;
    logic [PTR_WIDTH-1:0] wr_gray;
    logic [PTR_WIDTH-1:0] wr_bin_next;
    logic [PTR_WIDTH-1:0] wr_gray_next;

    logic [PTR_WIDTH-1:0] rd_bin;
    logic [PTR_WIDTH-1:0] rd_gray;
    logic [PTR_WIDTH-1:0] rd_bin_next;
    logic [PTR_WIDTH-1:0] rd_gray_next;

    // Read pointer synchronized into the write domain.
    (* ASYNC_REG = "TRUE" *)
    logic [PTR_WIDTH-1:0] rd_gray_wr_sync1;

    (* ASYNC_REG = "TRUE" *)
    logic [PTR_WIDTH-1:0] rd_gray_wr_sync2;

    // Write pointer synchronized into the read domain.
    (* ASYNC_REG = "TRUE" *)
    logic [PTR_WIDTH-1:0] wr_gray_rd_sync1;

    (* ASYNC_REG = "TRUE" *)
    logic [PTR_WIDTH-1:0] wr_gray_rd_sync2;

    // Asynchronous reset assertion, synchronous release per domain.
    (* ASYNC_REG = "TRUE" *)
    logic [1:0] wr_reset_pipe;

    (* ASYNC_REG = "TRUE" *)
    logic [1:0] rd_reset_pipe;

    logic wr_reset;
    logic rd_reset;

    logic full_q;
    logic full_next;
    logic empty_q;
    logic empty_next;

    logic wr_fire;
    logic rd_fire;
    logic rd_valid_q;

    // synthesis translate_off
    initial begin
        if (DATA_WIDTH < 1)
            $fatal(1, "DATA_WIDTH must be positive");

        if (DEPTH < 4 || (DEPTH & (DEPTH - 1)) != 0)
            $fatal(1, "DEPTH must be a power of two and at least 4");
    end
    // synthesis translate_on

    always_ff @(posedge wr_clk or posedge arst) begin
        if (arst)
            wr_reset_pipe <= 2'b11;
        else
            wr_reset_pipe <= {wr_reset_pipe[0], 1'b0};
    end

    always_ff @(posedge rd_clk or posedge arst) begin
        if (arst)
            rd_reset_pipe <= 2'b11;
        else
            rd_reset_pipe <= {rd_reset_pipe[0], 1'b0};
    end

    assign wr_reset = wr_reset_pipe[1];
    assign rd_reset = rd_reset_pipe[1];

    // Block requests while the corresponding domain is resetting.
    assign wr_full = arst || wr_reset || full_q;
    assign rd_empty = arst || rd_reset || empty_q;

    assign wr_fire = wr_en && !wr_full;
    assign rd_fire = rd_en && !rd_empty;

    assign rd_valid = rd_valid_q && !arst && !rd_reset;

    // Binary pointers address memory; Gray pointers cross domains.
    assign wr_bin_next =
        wr_bin + {{(PTR_WIDTH-1){1'b0}}, wr_fire};

    assign rd_bin_next =
        rd_bin + {{(PTR_WIDTH-1){1'b0}}, rd_fire};

    assign wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;
    assign rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;

    // Full when the next write pointer is one complete buffer
    // ahead of the synchronized read pointer.
    assign full_next = (
        wr_gray_next == {
            ~rd_gray_wr_sync2[ADDR_WIDTH:ADDR_WIDTH-1],
             rd_gray_wr_sync2[ADDR_WIDTH-2:0]
        }
    );

    assign empty_next = (rd_gray_next == wr_gray_rd_sync2);

    // Synchronize the read Gray pointer into wr_clk.
    always_ff @(posedge wr_clk or posedge arst) begin
        if (arst) begin
            rd_gray_wr_sync1 <= '0;
            rd_gray_wr_sync2 <= '0;
        end else if (wr_reset) begin
            rd_gray_wr_sync1 <= '0;
            rd_gray_wr_sync2 <= '0;
        end else begin
            rd_gray_wr_sync1 <= rd_gray;
            rd_gray_wr_sync2 <= rd_gray_wr_sync1;
        end
    end

    // Synchronize the write Gray pointer into rd_clk.
    always_ff @(posedge rd_clk or posedge arst) begin
        if (arst) begin
            wr_gray_rd_sync1 <= '0;
            wr_gray_rd_sync2 <= '0;
        end else if (rd_reset) begin
            wr_gray_rd_sync1 <= '0;
            wr_gray_rd_sync2 <= '0;
        end else begin
            wr_gray_rd_sync1 <= wr_gray;
            wr_gray_rd_sync2 <= wr_gray_rd_sync1;
        end
    end

    always_ff @(posedge wr_clk or posedge arst) begin
        if (arst) begin
            wr_bin <= '0;
            wr_gray <= '0;
            full_q <= 1'b0;
        end else if (wr_reset) begin
            wr_bin <= '0;
            wr_gray <= '0;
            full_q <= 1'b0;
        end else begin
            wr_bin <= wr_bin_next;
            wr_gray <= wr_gray_next;
            full_q <= full_next;
        end
    end

    always_ff @(posedge rd_clk or posedge arst) begin
        if (arst) begin
            rd_bin <= '0;
            rd_gray <= '0;
            empty_q <= 1'b1;
            rd_valid_q <= 1'b0;
        end else if (rd_reset) begin
            rd_bin <= '0;
            rd_gray <= '0;
            empty_q <= 1'b1;
            rd_valid_q <= 1'b0;
        end else begin
            rd_bin <= rd_bin_next;
            rd_gray <= rd_gray_next;
            empty_q <= empty_next;
            rd_valid_q <= rd_fire;
        end
    end

    // Independent synchronous memory ports.
    // Memory contents do not need reset: pointers define valid data.
    always_ff @(posedge wr_clk) begin
        if (wr_fire)
            memory[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
    end

    always_ff @(posedge rd_clk) begin
        if (rd_fire)
            rd_data <= memory[rd_bin[ADDR_WIDTH-1:0]];
    end

endmodule