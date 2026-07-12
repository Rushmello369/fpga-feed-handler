//=============================================================================
// feed_handler.sv
//-----------------------------------------------------------------------------
// Packageable top wrapper for Vivado IP Packager / Block Design.
//
//   * AXI4-Stream slave  (s_axis_*) : 8-bit feed input, driven by AXI DMA MM2S
//   * AXI4-Lite  slave   (s_axi_*)  : control + tob/latency status registers
//
// It instantiates the existing `top` core unchanged; the SystemVerilog structs
// and 1024-bit masks stay INSIDE the RTL and never reach a BD port.
//
// AXI-Lite register map (word offsets, all 32-bit):
//   0x00  RO  best_bid_price
//   0x04  RO  best_bid_qty
//   0x08  RO  best_ask_price
//   0x0C  RO  best_ask_qty
//   0x10  RO  status = {.. , latency_seen, ask_valid, bid_valid}
//                       bit0 = bid_valid, bit1 = ask_valid,
//                       bit2 = latency_seen (sticky, cleared on read of 0x10)
//   0x14  RO  latency (cycle count)
//   0x18  RW  scratch / control  (free for future use, e.g. soft-enable)
//   0x1C  RO  ID = 0xFEED0001     (read this first to confirm the IP is alive)
//=============================================================================
module feed_handler #(
    parameter int C_S_AXI_DATA_WIDTH = 32,
    parameter int C_S_AXI_ADDR_WIDTH = 5    // 8 words * 4 bytes = 32B -> 5 addr bits
)(
    // ---- global clock / reset (shared by both interfaces) ----------------
    input  logic                              aclk,
    input  logic                              aresetn,    // active-low

    // ---- AXI4-Stream slave : feed input (8-bit) --------------------------
    input  logic [7:0]                        s_axis_tdata,
    input  logic                              s_axis_tvalid,
    output logic                              s_axis_tready,
    input  logic                              s_axis_tlast,

    // ---- AXI4-Lite slave : control / status ------------------------------
    input  logic [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  logic [2:0]                        s_axi_awprot,
    input  logic                              s_axi_awvalid,
    output logic                              s_axi_awready,
    input  logic [C_S_AXI_DATA_WIDTH-1:0]     s_axi_wdata,
    input  logic [(C_S_AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input  logic                              s_axi_wvalid,
    output logic                              s_axi_wready,
    output logic [1:0]                        s_axi_bresp,
    output logic                              s_axi_bvalid,
    input  logic                              s_axi_bready,
    input  logic [C_S_AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
    input  logic [2:0]                        s_axi_arprot,
    input  logic                              s_axi_arvalid,
    output logic                              s_axi_arready,
    output logic [C_S_AXI_DATA_WIDTH-1:0]     s_axi_rdata,
    output logic [1:0]                        s_axi_rresp,
    output logic                              s_axi_rvalid,
    input  logic                              s_axi_rready
);

    import fm24_pkg::*;

    //-------------------------------------------------------------------------
    // Core instance (unchanged datapath)
    //-------------------------------------------------------------------------
    fm24_tob_t   tob;
    logic [31:0] latency;
    logic        latency_valid;

    top u_core (
        .clk           (aclk),
        .arstn         (aresetn),
        .s_tdata       (s_axis_tdata),
        .s_tvalid      (s_axis_tvalid),
        .s_tready      (s_axis_tready),
        .s_tlast       (s_axis_tlast),
        .tob           (tob),
        .latency       (latency),
        .latency_valid (latency_valid)
    );

    //-------------------------------------------------------------------------
    // Sticky "new latency measured" flag (latency_valid is a 1-cycle pulse,
    // not pollable). Set on the pulse, cleared when the PS reads status (0x10).
    //-------------------------------------------------------------------------
    logic latency_seen;
    logic status_read;   // pulses high the cycle status reg is read

    always_ff @(posedge aclk) begin
        if (!aresetn)
            latency_seen <= 1'b0;
        else if (latency_valid)
            latency_seen <= 1'b1;
        else if (status_read)
            latency_seen <= 1'b0;
    end

    //-------------------------------------------------------------------------
    // AXI4-Lite WRITE channel  (only the scratch/control reg is writable)
    //-------------------------------------------------------------------------
    logic [31:0] ctrl_reg;
    logic        aw_en;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            aw_en         <= 1'b1;
            ctrl_reg      <= 32'h0;
        end else begin
            // address-write handshake
            if (!s_axi_awready && s_axi_awvalid && s_axi_wvalid && aw_en) begin
                s_axi_awready <= 1'b1;
                aw_en         <= 1'b0;
            end else if (s_axi_bready && s_axi_bvalid) begin
                aw_en         <= 1'b1;
                s_axi_awready <= 1'b0;
            end else begin
                s_axi_awready <= 1'b0;
            end

            // data-write handshake
            if (!s_axi_wready && s_axi_wvalid && s_axi_awvalid && aw_en)
                s_axi_wready <= 1'b1;
            else
                s_axi_wready <= 1'b0;

            // commit write: only address 0x18 (word index 6) is a real register
            if (s_axi_wready && s_axi_wvalid && s_axi_awready && s_axi_awvalid) begin
                if (s_axi_awaddr[4:2] == 3'd6) begin
                    for (int b = 0; b < 4; b++)
                        if (s_axi_wstrb[b])
                            ctrl_reg[b*8 +: 8] <= s_axi_wdata[b*8 +: 8];
                end
                // writes to read-only addresses are accepted & ignored (OKAY)
            end

            // write response
            if (s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid
                && !s_axi_bvalid) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00; // OKAY
            end else if (s_axi_bready && s_axi_bvalid) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    //-------------------------------------------------------------------------
    // AXI4-Lite READ channel
    //-------------------------------------------------------------------------
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b00;
        end else begin
            if (!s_axi_arready && s_axi_arvalid)
                s_axi_arready <= 1'b1;
            else
                s_axi_arready <= 1'b0;

            if (s_axi_arready && s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= 2'b00; // OKAY
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    // status read strobe: high when an address read completes on word 4 (0x10)
    assign status_read = s_axi_arready && s_axi_arvalid && (s_axi_araddr[4:2] == 3'd4);

    // read data mux
    always_comb begin
        unique case (s_axi_araddr[4:2])
            3'd0:    s_axi_rdata = tob.best_bid_price;
            3'd1:    s_axi_rdata = tob.best_bid_qty;
            3'd2:    s_axi_rdata = tob.best_ask_price;
            3'd3:    s_axi_rdata = tob.best_ask_qty;
            3'd4:    s_axi_rdata = {29'b0, latency_seen, tob.ask_valid, tob.bid_valid};
            3'd5:    s_axi_rdata = latency;
            3'd6:    s_axi_rdata = ctrl_reg;
            3'd7:    s_axi_rdata = 32'hFEED_0001;
            default: s_axi_rdata = 32'h0;
        endcase
    end

endmodule
