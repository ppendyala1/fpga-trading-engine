`timescale 1ns/1ps
module tb_packet_pipeline;
    logic clk=0,rx_clk=0,arst=1,rx_dv=0,rx_er=0;
    always #2.5 clk=~clk;
    always #20 rx_clk=~rx_clk;
    logic [3:0] rxd=0;
    logic fv,fr,cv,cr=0;
    logic [10:0] fl,ra;
    logic [7:0] rd;
    logic [383:0] command_data,held;
    logic [31:0] bad_frames,dropped_frames,malformed;
    logic [7:0] data[0:101];
    int accepted=0;
    mii_rx rx(.arst,.clk,.rx_clk,.rxd,.rx_dv,.rx_er,.frame_valid(fv),.frame_ready(fr),
        .frame_length(fl),.read_addr(ra),.read_data(rd),.bad_frames,.dropped_frames);
    udp_event_parser parser(.clk,.rst(arst),.frame_valid(fv),.frame_ready(fr),
        .frame_length(fl),.read_addr(ra),.read_data(rd),.command_valid(cv),.command_ready(cr),
        .command_data,.malformed);
    always @(posedge clk) if(cv && cr) accepted++;
    task automatic frame(input int file_index,input int size=102,input int error_at=-1,
                         input int start_byte=0,input bit skip_first_nibble=0);
        $readmemh($sformatf("../vectors/frame%0d.hex",file_index),data);
        for(int i=start_byte;i<size;i++) begin
            if(i!=start_byte || !skip_first_nibble) begin
                @(negedge rx_clk);rx_dv=1;rxd=data[i][3:0];rx_er=i==error_at;
            end
            @(negedge rx_clk);rx_dv=1;rxd=data[i][7:4];rx_er=i==error_at;
        end
        @(negedge rx_clk);rx_dv=0;rx_er=0;rxd=0;
        repeat(30) @(negedge rx_clk);
    endtask
    initial begin
        repeat(10) @(negedge rx_clk);arst=0;
        repeat(10) @(negedge rx_clk);
        frame(1);wait(cv);held=command_data;
        // Occupied mailbox cannot tear the stalled command.
        frame(2);
        if(!cv || command_data!==held || dropped_frames!=1) $fatal(1,"Mailbox backpressure/overflow");
        cr=1;repeat(20) @(negedge rx_clk);
        if(accepted!=1) $fatal(1,"Command repeated");
        frame(5); // bad CRC
        frame(6);frame(7);frame(8);frame(9,101);
        frame(1,102,45); // RX_ER even with otherwise good FCS
        frame(1,70); // truncation
        if(accepted!=1 || malformed!=4 || bad_frames!=3)
            $fatal(1,"Bad packet counters accepted=%d malformed=%d FCS/error=%d",accepted,malformed,bad_frames);
        // Reset with a held frame discards it in both clock domains.
        cr=0;frame(1);wait(cv);
        arst=1;repeat(10) @(negedge rx_clk);arst=0;
        repeat(10) @(negedge rx_clk);
        if(cv || fv || bad_frames || malformed || dropped_frames) $fatal(1,"Reset failed");
        cr=1;frame(2);
        if(accepted!=2) $fatal(1,"Did not resume after reset");
        frame(1,102,-1,2); // PHY removes two preamble bytes.
        frame(1,102,-1,0,1); // RX_DV starts on an odd preamble nibble.
        if(accepted!=4 || bad_frames || malformed) $fatal(1,"Short preamble alignment failed");
        $display("PASS: MII FCS, malformed IPv4/UDP, truncation, RX_ER, overflow, CDC, stalled command and reset");
        $finish;
    end
    initial begin #1000000;$fatal(1,"Packet test timeout");end
endmodule
