`timescale 1ns/1ps
module tb_phy;
    logic clk=0,rst=1;
    always #2.5 clk=~clk;
    wire mdc,link_up;
    tri1 mdio;
    logic slave_drive=0,slave_bit=1,connected=1;
    logic [15:0] reply;
    int advertisements=0,restarts=0;
    phy_management #(.HALF_PERIOD(2)) dut(.*);
    assign mdio=slave_drive?slave_bit:1'bz;
    // Behavioral PHY at address 1; emulate ID and vendor status registers.
    // Drive on falling MDC and sample on rising MDC, including turnaround.
    always @(negedge mdc) begin
        #0.1;
        slave_drive=0;slave_bit=1;reply=16'hffff;
        if(dut.phy_address==1) begin
            case(dut.register_address)
                2:reply=16'h2000;
                3:reply=16'h5c90;
                16:reply=connected?16'h0015:16'h0000;
                default:reply=0;
            endcase
            if(dut.busy && dut.read_op && dut.bit_index>=46) begin
                slave_drive=1;
                if(dut.bit_index==46) slave_bit=1;
                else if(dut.bit_index==47) slave_bit=0;
                else slave_bit=reply[63-dut.bit_index];
            end
        end
    end
    always @(posedge clk) if(dut.done && !dut.read_op) begin
        if(dut.register_address==4) begin
            if(dut.transaction[15:0]!=16'h0101) $fatal(1,"Bad AN advertisement");
            advertisements++;
        end
        if(dut.register_address==0) begin
            if(dut.transaction[15:0]!=16'h1200) $fatal(1,"Bad AN restart");
            restarts++;
        end
    end
    initial begin
        repeat(4) @(negedge clk);rst=0;
        wait(link_up);
        if(advertisements!=1 || restarts!=1 || dut.phy_address!=1) $fatal(1,"PHY initialization failed");
        connected=0;wait(!link_up);
        connected=1;wait(link_up);
        @(negedge clk);rst=1;
        repeat(4) @(negedge clk);
        if(link_up || mdc) $fatal(1,"PHY reset failed");
        $display("PASS: MDIO discovery, PHY ID, 100/full advertisement, AN restart, link loss/recovery and reset");
        $finish;
    end
    initial begin #1000000;$fatal(1,"PHY test timeout");end
endmodule
