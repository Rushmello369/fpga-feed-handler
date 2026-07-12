module latency_counter
    import fm24_pkg::*;
(
    input  logic        clk,
    input  logic        arstn,
    input  logic        s_tvalid,
    input  logic        s_tready,
    input  logic        qty_valid,
    output logic [31:0] latency,        
    output logic        latency_valid   
);

    logic [31:0] counter;       
    logic [31:0] start_count;   
    logic        measuring;     

    always_ff @(posedge clk) begin
        if(!arstn) begin
            counter <= '0;
            start_count <= '0;
            measuring <= '0;
            latency <= '0;
            latency_valid <= '0;
        end else begin
            counter <= counter + 1;
            latency_valid <= 0;
            if(!measuring && s_tvalid && s_tready) begin
                start_count <= counter;
                measuring <= 1;
            end else if(measuring && qty_valid) begin
                latency <= counter - start_count;
                latency_valid <= 1;
                measuring <= 0;
            end
        end
    end

endmodule