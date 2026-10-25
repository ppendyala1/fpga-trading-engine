`timescale 1ns/1ps

module tb_async_fifo;

    localparam int unsigned DATA_WIDTH = 8;
    localparam int unsigned DEPTH = 16;
    localparam int unsigned MAX_WORDS = 4096;

    logic arst;

    // Independent clocks: periods of 10 ns and 14 ns.
    logic wr_clk = 1'b0;
    logic rd_clk = 1'b0;

    always #5 wr_clk = ~wr_clk;
    always #7 rd_clk = ~rd_clk;

    logic wr_en;
    logic [DATA_WIDTH-1:0] wr_data;
    logic wr_full;

    logic rd_en;
    logic [DATA_WIDTH-1:0] rd_data;
    logic rd_valid;
    logic rd_empty;

    // Scoreboard stores every accepted write.
    logic [DATA_WIDTH-1:0] expected_data [0:MAX_WORDS-1];

    int unsigned writes;
    int unsigned reads;

    logic read_accepted;
    logic [DATA_WIDTH-1:0] expected_word;

    async_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(DEPTH)
    ) dut (
        .arst,
        .wr_clk,
        .wr_en,
        .wr_data,
        .wr_full,
        .rd_clk,
        .rd_en,
        .rd_data,
        .rd_valid,
        .rd_empty
    );

    // Record accepted writes at the sampling edge.
    always @(posedge wr_clk or posedge arst) begin
        if (arst) begin
            writes = 0;
        end else if (wr_en && !wr_full) begin
            if (writes >= MAX_WORDS)
                $fatal(1, "Scoreboard capacity exceeded");

            expected_data[writes] = wr_data;
            writes++;
        end
    end

    // Check each registered read result after NBA updates.
    always @(posedge rd_clk or posedge arst) begin
        if (arst) begin
            reads = 0;
            read_accepted = 1'b0;
            expected_word = '0;
        end else begin
            read_accepted = rd_en && !rd_empty;

            if (read_accepted) begin
                if (reads >= writes)
                    $fatal(1, "Read accepted without a queued word");

                expected_word = expected_data[reads];
                reads++;
            end

            #1;

            if (!arst) begin
                if (rd_valid !== read_accepted)
                    $fatal(
                        1,
                        "rd_valid mismatch: expected %b, got %b",
                        read_accepted, rd_valid
                    );

                if (read_accepted && rd_data !== expected_word)
                    $fatal(
                        1,
                        "Data mismatch: expected %h, got %h",
                        expected_word, rd_data
                    );
            end
        end
    end

    task automatic reset_fifo;
        // Assert away from the read monitor's sampling edge.
        @(negedge rd_clk);

        arst = 1'b1;
        wr_en = 1'b0;
        rd_en = 1'b0;

        repeat (3) @(negedge wr_clk);
        arst = 1'b0;

        // Allow both domains to release their local resets.
        repeat (5) @(negedge wr_clk);
        repeat (5) @(negedge rd_clk);

        if (wr_full !== 1'b0)
            $fatal(1, "FIFO remained full after reset");

        if (rd_empty !== 1'b1)
            $fatal(1, "FIFO was not empty after reset");

        if (rd_valid !== 1'b0)
            $fatal(1, "Unexpected valid output after reset");

        if (writes != 0 || reads != 0)
            $fatal(1, "Scoreboard did not reset");
    endtask

    task automatic write_words(
        input int unsigned count,
        input int unsigned seed,
        input int unsigned gap
    );
        int unsigned cycles;

        for (int unsigned i = 0; i < count; i++) begin
            @(negedge wr_clk);

            wr_en = 1'b1;
            wr_data = DATA_WIDTH'(seed + i);

            cycles = 0;

            do begin
                @(posedge wr_clk);
                cycles++;

                if (cycles > 1000)
                    $fatal(1, "Writer timed out waiting for space");

            end while (wr_full !== 1'b0);

            @(negedge wr_clk);
            wr_en = 1'b0;

            repeat (gap) @(negedge wr_clk);
        end
    endtask

    task automatic read_words(
        input int unsigned count,
        input int unsigned gap
    );
        int unsigned cycles;

        for (int unsigned i = 0; i < count; i++) begin
            @(negedge rd_clk);
            rd_en = 1'b1;

            cycles = 0;

            do begin
                @(posedge rd_clk);
                cycles++;

                if (cycles > 1000)
                    $fatal(1, "Reader timed out waiting for data");

            end while (rd_empty !== 1'b0);

            @(negedge rd_clk);
            rd_en = 1'b0;

            repeat (gap) @(negedge rd_clk);
        end
    endtask

    task automatic check_drained;
        // Allow synchronized flags to catch up.
        repeat (5) @(negedge wr_clk);
        repeat (5) @(negedge rd_clk);

        if (writes != reads)
            $fatal(
                1,
                "FIFO not drained: writes=%0d reads=%0d",
                writes, reads
            );

        if (rd_empty !== 1'b1)
            $fatal(1, "Empty flag missing after drain");

        if (wr_full !== 1'b0)
            $fatal(1, "Full flag remained asserted after drain");
    endtask

    initial begin
        arst = 1'b1;
        wr_en = 1'b0;
        wr_data = '0;
        rd_en = 1'b0;

        reset_fifo();

        // Requests while empty must not produce valid output.
        @(negedge rd_clk);
        rd_en = 1'b1;

        repeat (4) @(posedge rd_clk);

        @(negedge rd_clk);
        rd_en = 1'b0;

        if (reads != 0)
            $fatal(1, "Empty read advanced the FIFO");

        // Fill all entries without reading.
        write_words(DEPTH, 32'h10, 0);

        if (wr_full !== 1'b1)
            $fatal(1, "Full flag missing at capacity");

        // Extra writes while full must be ignored.
        @(negedge wr_clk);
        wr_en = 1'b1;
        wr_data = 8'hEE;

        repeat (4) @(posedge wr_clk);

        @(negedge wr_clk);
        wr_en = 1'b0;

        if (writes != DEPTH)
            $fatal(1, "Full write was incorrectly accepted");

        read_words(DEPTH, 0);
        check_drained();

        // Faster producer, slower consumer.
        // Transfers exceed the depth to exercise pointer wraparound.
        fork
            write_words(10 * DEPTH, 32'h40, 0);
            read_words(10 * DEPTH, 3);
        join

        check_drained();

        // Slower producer, faster consumer.
        fork
            write_words(10 * DEPTH, 32'h90, 4);
            read_words(10 * DEPTH, 0);
        join

        check_drained();

        // Reset with unread words still queued.
        write_words(DEPTH / 2, 32'hC0, 0);
        reset_fifo();

        // Fresh data must not be confused with pre-reset contents.
        write_words(DEPTH, 32'h20, 0);
        read_words(DEPTH, 0);
        check_drained();

        $display("PASS: async_fifo tests completed");
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "Global simulation timeout");
    end

endmodule