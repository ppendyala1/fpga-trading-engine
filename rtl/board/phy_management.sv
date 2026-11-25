// Clause 22 management for the Arty DP83848J. Discover address by PHY ID,
// advertise only 100BASE-TX full duplex, restart AN, and gate MAC on PHYSTS.
module phy_management #(
    parameter int HALF_PERIOD=50 // 200 MHz / (2*50) = 2 MHz MDC, below 2.5 MHz limit
) (
    input logic clk,rst,
    output logic mdc,
    inout wire mdio,
    output logic link_up
);
    logic busy,done,read_op,ack_ok;
    logic [15:0] read_value;
    logic [63:0] transaction;
    logic [6:0] bit_index;
    logic [$clog2(HALF_PERIOD+1)-1:0] divider;
    logic launch;
    logic [4:0] phy_address,register_address;
    logic [15:0] write_value;
    wire release_bus=read_op && bit_index>=46;
    assign mdio=busy && !release_bus ? transaction[63-bit_index] : 1'bz;
    typedef enum logic [3:0] {SCAN,SCAN_WAIT,ID3,ID3_WAIT,ADVERTISE,ADV_WAIT,
        RESTART,RESTART_WAIT,POLL,POLL_WAIT} state_t;
    state_t state;
    always_comb begin
        launch=0;read_op=1;register_address=2;write_value=0;
        case(state)
            SCAN: launch=!busy;
            ID3: begin launch=!busy;register_address=3;end
            ADVERTISE: begin launch=!busy;read_op=0;register_address=4;write_value=16'h0101;end
            RESTART: begin launch=!busy;read_op=0;register_address=0;write_value=16'h1200;end
            POLL: begin launch=!busy;register_address=16;end
            SCAN_WAIT: register_address=2;
            ID3_WAIT: register_address=3;
            ADV_WAIT: begin read_op=0;register_address=4;end
            RESTART_WAIT: begin read_op=0;register_address=0;end
            default: register_address=16;
        endcase
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            busy<=0;done<=0;ack_ok<=0;read_value<=0;transaction<=0;
            bit_index<=0;divider<=0;mdc<=0;
        end else begin
            done<=0;
            if(launch && !busy) begin
                transaction<={32'hffffffff,2'b01,(read_op?2'b10:2'b01),phy_address,
                              register_address,(read_op?2'b11:2'b10),write_value};
                busy<=1;bit_index<=0;divider<=0;mdc<=0;read_value<=0;ack_ok<=!read_op;
            end else if(busy) begin
                if(divider==HALF_PERIOD-1) begin
                    divider<=0;mdc<=!mdc;
                    if(!mdc) begin
                        if(read_op && bit_index==47) ack_ok<=mdio==1'b0;
                        if(read_op && bit_index>=48) read_value<={read_value[14:0],mdio};
                    end else begin
                        if(bit_index==63) begin busy<=0;done<=1;end
                        else bit_index<=bit_index+1'b1;
                    end
                end else divider<=divider+1'b1;
            end
        end
    end
    always_ff @(posedge clk) begin
        if(rst) begin state<=SCAN;phy_address<=0;link_up<=0;end
        else case(state)
            SCAN: if(launch) state<=SCAN_WAIT;
            SCAN_WAIT: if(done) begin
                if(ack_ok && read_value==16'h2000) state<=ID3;
                else begin phy_address<=phy_address+1'b1;state<=SCAN;end
            end
            ID3: if(launch) state<=ID3_WAIT;
            ID3_WAIT: if(done) begin
                if(ack_ok && (read_value & 16'hfff0)==16'h5c90) state<=ADVERTISE;
                else begin phy_address<=phy_address+1'b1;state<=SCAN;end
            end
            ADVERTISE: if(launch) state<=ADV_WAIT;
            ADV_WAIT: if(done) state<=RESTART;
            RESTART: if(launch) state<=RESTART_WAIT;
            RESTART_WAIT: if(done) state<=POLL;
            POLL: if(launch) state<=POLL_WAIT;
            POLL_WAIT: if(done) begin
                link_up<=ack_ok && read_value[4] && read_value[2] && !read_value[1] && read_value[0];
                state<=POLL;
            end
            default: begin state<=SCAN;link_up<=0;end
        endcase
    end
endmodule
