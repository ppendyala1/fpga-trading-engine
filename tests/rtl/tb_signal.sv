`timescale 1ns/1ps
module tb_signal;
    import trading_types_pkg::*;
    logic clk=0;always #2.5 clk=~clk;
    logic rst=1,bbo_valid=0,bbo_ready,bbo_usable=1,cfg_enable=1;
    logic decision_valid,decision_ready=0,buy_signal,sell_signal;
    price_t cfg_max_spread=1000;
    level_quantity_t cfg_min_quantity=1,cfg_min_imbalance=1;
    bbo_t bbo_data,decision_bbo;
    order_id_t bbo_order_id=64'hfedcba9876543210,decision_order_id;
    int checks=0;
    trading_signal dut(.*);
    task automatic check(input logic [1:0] expected);
        @(negedge clk);bbo_valid=1;
        @(posedge clk);#1;
        if(!decision_valid || {buy_signal,sell_signal}!==expected || decision_order_id!=bbo_order_id || decision_bbo!==bbo_data)
            $fatal(1,"Signal check %d expected %b got %b",checks,expected,{buy_signal,sell_signal});
        @(negedge clk);bbo_valid=0;
        repeat(3) begin
            @(posedge clk);#1;
            if(!decision_valid || bbo_ready || {buy_signal,sell_signal}!==expected) $fatal(1,"Signal output not held");
        end
        @(negedge clk);decision_ready=1;
        @(negedge clk);decision_ready=0;checks++;
    endtask
    initial begin
        bbo_data='0;
        repeat(3) @(negedge clk);rst=0;
        bbo_data={1'b1,32'd1500000,64'd100,1'b1,32'd1500200,64'd25};check(2'b10);
        bbo_data.bid_quantity=10;check(2'b01);
        bbo_data.bid_quantity=25;check(0);
        bbo_data.bid_quantity=100;cfg_enable=0;check(0);
        cfg_enable=1;cfg_max_spread=199;check(0);
        cfg_max_spread=200;check(2'b10);
        cfg_min_quantity=26;check(0);
        cfg_min_quantity=25;cfg_min_imbalance=76;check(0);
        cfg_min_imbalance=75;check(2'b10);
        bbo_usable=0;check(0);bbo_usable=1;
        bbo_data.bid_valid=0;check(0);bbo_data.bid_valid=1;
        bbo_data.ask_valid=0;check(0);bbo_data.ask_valid=1;
        bbo_data.ask_price=1500000;check(0);
        bbo_data.ask_price=1499900;check(0);
        bbo_data.ask_price=1500200;
        bbo_data.bid_quantity=64'hffffffffffffffff;bbo_data.ask_quantity=1;
        cfg_min_quantity=1;cfg_min_imbalance=64'hfffffffffffffffe;check(2'b10);
        // Reset discards a held decision.
        @(negedge clk);bbo_valid=1;
        @(negedge clk);bbo_valid=0;rst=1;
        @(negedge clk);
        if(decision_valid || buy_signal || sell_signal) $fatal(1,"Signal reset failed");
        $display("PASS: %0d signal threshold/quantity/spread/enable/trust cases, 64-bit extremes, backpressure and reset",checks);
        $finish;
    end
    initial begin #100000;$fatal(1,"Signal timeout");end
endmodule
