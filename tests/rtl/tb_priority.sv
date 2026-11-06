`timescale 1ns/1ps
module tb_priority;
    logic [1023:0] bits_in;
    logic found;
    logic [9:0] index;
    int expected,checks=0;
    priority_encoder dut(.*);
    task automatic check;
        #1;
        expected=-1;
        for(int i=1023;i>=0;i--) if(bits_in[i]) expected=i;
        if(found !== (expected>=0) || (expected>=0 && index!=expected) || (expected<0 && index!=0))
            $fatal(1,"Priority mismatch expected=%d actual=%d found=%b",expected,index,found);
        checks++;
    endtask
    initial begin
        bits_in=0;check();
        for(int i=0;i<1024;i++) begin bits_in=0;bits_in[i]=1;check();end
        bits_in='1;check();
        for(int i=0;i<1024;i++) begin bits_in[i]=0;check();end
        for(int n=0;n<100;n++) begin
            for(int i=0;i<32;i++) bits_in[i*32+:32]=$urandom();
            check();
        end
        $display("PASS: balanced 1024-way priority encoder, %0d masks including all one-hot and lowest-index cases",checks);
        $finish;
    end
endmodule
