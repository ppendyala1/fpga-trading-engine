// Balanced lowest-index selection. Avoid a DEPTH-long procedural mux cascade.
module priority_encoder #(
    parameter int WIDTH=1024,
    parameter int INDEX_WIDTH=$clog2(WIDTH)
) (
    input logic [WIDTH-1:0] bits_in,
    output logic found,
    output logic [INDEX_WIDTH-1:0] index
);
    wire valid_tree[1:2*WIDTH-1];
    wire [INDEX_WIDTH-1:0] index_tree[1:2*WIDTH-1];
    for(genvar i=0;i<WIDTH;i++) begin: leaf
        assign valid_tree[WIDTH+i]=bits_in[i];
        assign index_tree[WIDTH+i]=INDEX_WIDTH'(i);
    end
    for(genvar i=1;i<WIDTH;i++) begin: branch
        assign valid_tree[i]=valid_tree[2*i] || valid_tree[2*i+1];
        assign index_tree[i]=valid_tree[2*i]?index_tree[2*i]:index_tree[2*i+1];
    end
    assign found=valid_tree[1];
    assign index=found?index_tree[1]:'0;
    // synthesis translate_off
    initial if(WIDTH<2 || (WIDTH & (WIDTH-1))!=0) $fatal(1,"Encoder width must be a power of two >=2");
    // synthesis translate_on
endmodule
