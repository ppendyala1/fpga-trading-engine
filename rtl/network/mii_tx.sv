module mii_tx (
    input logic arst, clk,
    input logic write_en,
    input logic [10:0] write_addr,
    input logic [7:0] write_data,
    input logic send,
    input logic [10:0] length,
    output logic ready,
    input logic tx_clk,
    output logic [3:0] txd,
    output logic tx_en
);
    import ethernet_crc_pkg::*;
    // Bundled mailbox. Producer cannot write until the last IFG completes.
    (* ram_style="distributed" *) logic [7:0] mem[0:767];
    logic request,acknowledge;
    logic [10:0] length_q;
    (* ASYNC_REG="TRUE" *) logic ack1,ack2,req1,req2;
    (* ASYNC_REG="TRUE" *) logic [1:0] tx_reset;
    typedef enum logic [2:0] {IDLE,PREAMBLE,DATA,FCS,IFG} state_t;
    state_t state;
    logic half_byte;
    logic [10:0] index;
    logic [31:0] crc,fcs;
    logic [7:0] octet;
    assign ready=!arst && request==ack2;
    always_ff @(posedge clk) begin
        if(arst) begin request<=0;ack1<=0;ack2<=0;length_q<=0;end
        else begin
            ack1<=acknowledge;ack2<=ack1;
            if(send && ready) begin request<=!request;length_q<=length;end
        end
    end
    always_ff @(posedge clk) if(write_en && ready) mem[write_addr]<=write_data;
    always_ff @(negedge tx_clk or posedge arst)
        if(arst) tx_reset<=3; else tx_reset<={tx_reset[0],1'b0};
    always_ff @(negedge tx_clk) begin
        if(tx_reset[1]) begin req1<=0;req2<=0;end
        else begin req1<=request;req2<=req1;end
    end
    always_comb begin
        octet=0;
        case(state)
            PREAMBLE: octet=index==7 ? 8'hd5:8'h55;
            DATA: octet=mem[index];
            FCS: octet=8'(fcs>>(index*8));
            default: octet=0;
        endcase
    end
    // Drive on falling PHY clock; PHY samples rising edge.
    always_ff @(negedge tx_clk) begin
        if(tx_reset[1]) begin
            state<=IDLE;acknowledge<=0;half_byte<=0;index<=0;
            crc<='1;fcs<=0;txd<=0;tx_en<=0;
        end else begin
            tx_en<=0;txd<=0;
            case(state)
                IDLE: if(req2!=acknowledge) begin
                    state<=PREAMBLE;index<=0;half_byte<=0;crc<='1;
                end
                PREAMBLE,DATA,FCS: begin
                    tx_en<=1;
                    txd<=half_byte?octet[7:4]:octet[3:0];
                    half_byte<=!half_byte;
                    if(half_byte) begin
                        index<=index+1'b1;
                        if(state==PREAMBLE && index==7) begin state<=DATA;index<=0;end
                        if(state==DATA) begin
                            crc<=crc_byte(crc,octet);
                            if(index==length_q-1) begin
                                state<=FCS;index<=0;fcs<=~crc_byte(crc,octet);
                            end
                        end
                        if(state==FCS && index==3) begin state<=IFG;index<=0;end
                    end
                end
                IFG: if(index==23) begin acknowledge<=req2;state<=IDLE;end
                     else index<=index+1'b1;
                default: state<=IDLE;
            endcase
        end
    end
endmodule
