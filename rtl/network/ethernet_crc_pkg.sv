package ethernet_crc_pkg;
    function automatic logic [31:0] crc_byte(input logic [31:0] crc,
                                             input logic [7:0] data);
        logic [31:0] c;
        c = crc;
        for (int i=0; i<8; i++)
            c = (c >> 1) ^ ((c[0] ^ data[i]) ? 32'hedb88320 : 32'd0);
        return c;
    endfunction
endpackage
