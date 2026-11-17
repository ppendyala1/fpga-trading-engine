// Deliberately bounded protocol: Ethernet II, IPv4 IHL=5, UDP, 48-byte FTE1.
// MAC has already checked FCS. Copy the header before validating atomically.
module udp_event_parser #(
    parameter logic [47:0] LOCAL_MAC=48'h020000000001,
    parameter logic [31:0] LOCAL_IP=32'hc0a80180,
    parameter logic [31:0] HOST_IP=32'hc0a80101,
    parameter logic [15:0] PORT=16'd9000
) (
    input logic clk,rst,
    input logic frame_valid,
    output logic frame_ready,
    input logic [10:0] frame_length,
    output logic [10:0] read_addr,
    input logic [7:0] read_data,
    output logic command_valid,
    input logic command_ready,
    output logic [383:0] command_data,
    output logic [31:0] malformed
);
    typedef enum logic [2:0] {IDLE,ADDR,COPY,CHECK,HOLD,RELEASE} state_t;
    state_t state;
    logic [7:0] header[0:89];
    logic [6:0] index;
    logic [10:0] length_q;
    logic [31:0] ip_sum,udp_sum;
    logic [16:0] ip_fold,udp_fold;
    logic good;
    always_comb begin
        ip_sum=0;
        for(int i=14;i<34;i+=2) ip_sum=ip_sum+{header[i],header[i+1]};
        ip_fold={1'b0,ip_sum[15:0]}+{1'b0,ip_sum[31:16]};
        udp_sum=32'd17+32'd56;
        for(int i=26;i<34;i+=2) udp_sum=udp_sum+{header[i],header[i+1]};
        for(int i=34;i<90;i+=2) udp_sum=udp_sum+{header[i],header[i+1]};
        udp_fold={1'b0,udp_sum[15:0]}+{1'b0,udp_sum[31:16]};
        good=length_q==90 &&
            {header[0],header[1],header[2],header[3],header[4],header[5]}==LOCAL_MAC &&
            {header[12],header[13]}==16'h0800 && header[14]==8'h45 &&
            {header[16],header[17]}==16'd76 &&
            ({header[20],header[21]} & 16'hbfff)==0 && header[23]==17 &&
            (ip_fold[15:0]+ip_fold[16])==16'hffff &&
            {header[26],header[27],header[28],header[29]}==HOST_IP &&
            {header[30],header[31],header[32],header[33]}==LOCAL_IP &&
            {header[36],header[37]}==PORT && {header[38],header[39]}==56 &&
            ({header[40],header[41]}==0 || (udp_fold[15:0]+udp_fold[16])==16'hffff) &&
            {header[42],header[43],header[44],header[45]}==32'h46544531 &&
            header[47]==1 && {header[48],header[49]}==0 &&
            {header[76],header[77]}==0;
        command_data='0;
        for(int i=0;i<48;i++) command_data[383-i*8 -:8]=header[42+i];
    end
    assign read_addr={4'd0,index};
    assign frame_ready=state==RELEASE;
    assign command_valid=!rst && state==HOLD;
    always_ff @(posedge clk) begin
        if(rst) begin state<=IDLE;index<=0;malformed<=0;length_q<=0;end
        else case(state)
            IDLE: if(frame_valid) begin length_q<=frame_length;index<=0;state<=ADDR;end
            ADDR: state<=COPY;
            COPY: begin
                header[index]<=read_data;
                if(index==89) state<=CHECK;
                else begin index<=index+1'b1;state<=ADDR;end
            end
            CHECK: if(good) state<=HOLD;
                   else begin malformed<=malformed+1'b1;state<=RELEASE;end
            HOLD: if(command_ready) state<=RELEASE;
            RELEASE: state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
