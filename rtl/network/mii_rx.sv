// Single-frame store-and-forward mailbox. Memory and metadata remain frozen
// until the core acknowledges the toggle. No partial frame ever crosses CDC.
module mii_rx #(
    parameter int MAX_FRAME = 1536
) (
    input logic arst, rx_clk,
    input logic [3:0] rxd,
    input logic rx_dv, rx_er,
    input logic clk,
    output logic frame_valid,
    input logic frame_ready,
    output logic [10:0] frame_length,
    input logic [10:0] read_addr,
    output logic [7:0] read_data,
    output logic [31:0] bad_frames, dropped_frames
);
    import ethernet_crc_pkg::*;
    (* ram_style="block" *) logic [7:0] mem[0:MAX_FRAME-1];
    logic request, acknowledge;
    (* ASYNC_REG="TRUE" *) logic ack1, ack2, req1, req2;
    (* ASYNC_REG="TRUE" *) logic rx_running1,rx_running2;
    (* ASYNC_REG="TRUE" *) logic [1:0] rx_reset;
    logic [10:0] length_q;
    logic [31:0] bad_binary, drop_binary, bad_gray, drop_gray;
    (* ASYNC_REG="TRUE" *) logic [31:0] bad1,bad2,drop1,drop2;
    logic active, half_byte, started, invalid, busy_frame;
    logic [3:0] low;
    logic [3:0] preamble;
    logic [11:0] count;
    logic [31:0] crc;
    wire [7:0] octet = {rxd,low};
    function automatic logic [31:0] ungray(input logic [31:0] g);
        logic [31:0] b;
        b[31]=g[31];
        for(int i=30;i>=0;i--) b[i]=b[i+1]^g[i];
        return b;
    endfunction
    always_ff @(posedge rx_clk or posedge arst)
        if(arst) rx_reset<=2'b11; else rx_reset<={rx_reset[0],1'b0};
    always_ff @(posedge rx_clk) begin
        if(rx_reset[1]) begin ack1<=0; ack2<=0; end
        else begin ack1<=acknowledge; ack2<=ack1; end
    end
    always_ff @(posedge rx_clk) begin
        if(rx_reset[1]) begin
            request<=0; length_q<=0; active<=0; half_byte<=0;
            started<=0; invalid<=0; busy_frame<=0; low<=0;
            preamble<=0; count<=0; crc<='1;
            bad_binary<=0; drop_binary<=0; bad_gray<=0; drop_gray<=0;
        end else begin
            if(rx_dv) begin
                if(!active) begin
                    active<=1; half_byte<=0; low<=0;
                    started<=0; invalid<=rx_er || rxd!=4'h5;
                    preamble<=rxd==4'h5 ? 1 : 0; count<=0;
                    crc<='1; busy_frame <= (request != ack2);
                end else begin
                    if(rx_er) invalid<=1;
                    // RX_DV may begin partway through the preamble, including
                    // on an odd nibble. The SFD establishes byte alignment.
                    if(!started) begin
                        if(rxd==4'h5) begin
                            if(preamble!=15) preamble<=preamble+1'b1;
                        end else if(rxd==4'hd && preamble!=0) begin
                            started<=1; half_byte<=0;
                        end
                        else invalid<=1;
                    end else begin
                        half_byte<=!half_byte;
                        if(!half_byte) low<=rxd;
                        else begin
                            if(count<MAX_FRAME) begin
                                if(!busy_frame) mem[count[10:0]]<=octet;
                                count<=count+1'b1;
                            end else invalid<=1;
                            crc<=crc_byte(crc,octet);
                        end
                    end
                end
            end else if(active) begin
                active<=0;
                if(busy_frame) begin
                    drop_binary<=drop_binary+1'b1;
                    drop_gray<=((drop_binary+1'b1)>>1)^(drop_binary+1'b1);
                end else if(invalid || half_byte || !started || count<64 || crc!=32'hdebb20e3) begin
                    bad_binary<=bad_binary+1'b1;
                    bad_gray<=((bad_binary+1'b1)>>1)^(bad_binary+1'b1);
                end else begin length_q<=11'(count-4); request<=!request; end
            end
        end
    end
    always_ff @(posedge clk) begin
        if(arst) begin
            req1<=0;req2<=0;acknowledge<=0;
            rx_running1<=0;rx_running2<=0;
            bad1<=0;bad2<=0;drop1<=0;drop2<=0;
        end else begin
            req1<=request;req2<=req1;
            rx_running1<=!rx_reset[1];rx_running2<=rx_running1;
            bad1<=bad_gray;bad2<=bad1;drop1<=drop_gray;drop2<=drop1;
            if(frame_valid && frame_ready) acknowledge<=req2;
        end
    end
    always_ff @(posedge clk) read_data<=mem[read_addr];
    assign frame_valid=!arst && rx_running2 && req2!=acknowledge;
    assign frame_length=length_q;
    assign bad_frames=ungray(bad2);
    assign dropped_frames=ungray(drop2);
endmodule
