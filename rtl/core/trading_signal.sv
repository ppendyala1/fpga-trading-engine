module trading_signal (
    input logic clk,
    input logic rst,

    // Incoming BBO/result stream.
    input logic bbo_valid,
    output logic bbo_ready,

    input trading_types_pkg::bbo_t bbo_data,
    input trading_types_pkg::order_id_t bbo_order_id,

    // True only for a successful event with a trusted BBO.
    input logic bbo_usable,

    // Configuration, sampled when an input is accepted.
    input logic cfg_enable,
    input trading_types_pkg::price_t cfg_max_spread,
    input trading_types_pkg::level_quantity_t cfg_min_quantity,
    input trading_types_pkg::level_quantity_t cfg_min_imbalance,

    // Registered output with backpressure.
    output logic decision_valid,
    input logic decision_ready,

    output logic buy_signal,
    output logic sell_signal,

    output trading_types_pkg::order_id_t decision_order_id,
    output trading_types_pkg::bbo_t decision_bbo
);

    import trading_types_pkg::*;

    price_t spread;

    level_quantity_t bid_excess;
    level_quantity_t ask_excess;

    logic market_ok;
    logic buy_next;
    logic sell_next;

    // One-entry output register:
    // accept when empty or when the previous result is consumed.
    assign bbo_ready =
        !rst && (!decision_valid || decision_ready);

    always_comb begin
        spread = '0;
        bid_excess = '0;
        ask_excess = '0;

        market_ok = 1'b0;
        buy_next = 1'b0;
        sell_next = 1'b0;

        if (
            bbo_usable &&
            bbo_data.bid_valid &&
            bbo_data.ask_valid &&
            bbo_data.bid_price < bbo_data.ask_price
        ) begin
            spread = bbo_data.ask_price - bbo_data.bid_price;

            market_ok =
                cfg_enable &&
                spread <= cfg_max_spread &&
                bbo_data.bid_quantity >= cfg_min_quantity &&
                bbo_data.ask_quantity >= cfg_min_quantity;

            if (bbo_data.bid_quantity > bbo_data.ask_quantity)
                bid_excess =
                    bbo_data.bid_quantity - bbo_data.ask_quantity;

            if (bbo_data.ask_quantity > bbo_data.bid_quantity)
                ask_excess =
                    bbo_data.ask_quantity - bbo_data.bid_quantity;

            if (market_ok) begin
                buy_next =
                    bbo_data.bid_quantity > bbo_data.ask_quantity &&
                    bid_excess >= cfg_min_imbalance;

                sell_next =
                    bbo_data.ask_quantity > bbo_data.bid_quantity &&
                    ask_excess >= cfg_min_imbalance;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            decision_valid <= 1'b0;
            buy_signal <= 1'b0;
            sell_signal <= 1'b0;
            decision_order_id <= '0;
            decision_bbo <= '0;

        end else if (bbo_ready) begin
            decision_valid <= bbo_valid;
            buy_signal <= 1'b0;
            sell_signal <= 1'b0;

            if (bbo_valid) begin
                decision_order_id <= bbo_order_id;
                decision_bbo <= bbo_data;

                buy_signal <= buy_next;
                sell_signal <= sell_next;
            end
        end
    end

endmodule