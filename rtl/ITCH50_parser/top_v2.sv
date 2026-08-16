/*
top_v2
------
Wires the complete v2 ITCH pipeline:
 
byte stream -> itch_parser -> event_dispatcher -> { order_lookup,
book_update } -> priority_encoder -> tob_tracker -> feature_engine
-> board_link_tx -> byte stream out (to Pynq Z1)
 
The AXI-Lite status register block and latency counters from v1 attach
at this level (not included here; wire the diagnostic outputs -
parse_error, unknown_count, msg_count, miss_count, oow_count,
drop_count - into the existing feed_handler register map).
 
Parameters BASE_PRICE / WINDOW_SIZE / QTY_SHIFT are surfaced here so a
single place controls calibration for the whole design.
*/

module top_v2
    import ITCH50_pkg::*;
#(
    parameter int unsigned BASE_PRICE    = 1_550_000,
    parameter int unsigned WINDOW_SIZE   = 1023,
    parameter int unsigned QTY_SHIFT     = 0,
    parameter int          TABLE_BITS    = 14,
    // single-instrument filter (calibrate with BASE_PRICE per symbol/day)
    parameter bit          FILTER_EN     = 1'b0,
    parameter logic [15:0] FILTER_LOCATE = 16'd0,
    parameter int unsigned ADDR_W        = $clog2(WINDOW_SIZE)
)
(
    input  logic        clk,
    input  logic        arstn,

    // inbound ITCH byte stream (XDMA H2C)
    input  logic        s_tvalid,
    input  logic [7:0]  s_tdata,
    output logic        s_tready,

    // outbound feature-frame byte stream (board link to Pynq Z1)
    output logic        tx_valid,
    output logic [7:0]  tx_data,
    input  logic        tx_ready,

    // diagnostics (to AXI-Lite status registers)
    output logic        parse_error,
    output logic [31:0] unknown_count,
    output logic [31:0] msg_count,
    output logic [31:0] filtered_count,
    output logic [31:0] miss_count,
    output logic [31:0] oow_count,
    output logic [31:0] drop_count,

    // ---- latency instrumentation (pure observation, see latency_probe.sv) ----
    // t_total is measured from ev_handoff (parser -> dispatcher) to the first
    // feat_valid it produces, so it excludes the transport entirely and is a
    // property of the core rather than of whatever is feeding it.
    output logic [31:0] lat_last,       // t_total, most recent
    output logic [31:0] lat_min,
    output logic [31:0] lat_max,
    output logic [31:0] lat_sum,        // host computes mean = sum / count
    output logic [31:0] lat_count,
    output logic [31:0] lat_resolve,    // ev_handoff -> book_updated
    output logic [31:0] lat_book2tob,   // book_updated -> tob_valid (expect 5)
    output logic [31:0] lat_tob2feat,   // tob_valid -> feat_valid  (expect 1)
    output logic [31:0] lat_ia_last,    // interval between events = transport cost
    output logic [31:0] lat_ia_min,
    output logic [31:0] lat_unmatched   // events that produced no feature
);

    // ---------------- parser -> dispatcher ----------------
    itch_event_t ev;
    logic        ev_valid, ev_ready;

    itch_parser #(
        .FILTER_EN(FILTER_EN), .FILTER_LOCATE(FILTER_LOCATE)
    ) u_parser (
        .clk(clk), .arstn(arstn),
        .s_tvalid(s_tvalid), .s_tdata(s_tdata), .s_tready(s_tready),
        .ev(ev), .ev_valid(ev_valid), .ev_ready(ev_ready),
        .parse_error(parse_error),
        .unknown_count(unknown_count),
        .msg_count(msg_count),
        .filtered_count(filtered_count)
    );

    // ---------------- dispatcher <-> lookup / book ----------------
    logic        ins_valid;
    logic [63:0] ins_order_id;
    logic [31:0] ins_price, ins_qty;
    logic        ins_side;

    logic        qry_valid;
    logic [63:0] qry_order_id;
    lookup_op_e  qry_op;
    logic [31:0] qry_qty;

    logic        lk_busy, res_valid, res_hit, res_side, res_removed;
    logic [31:0] res_price, res_delta_qty;

    logic        bu_valid, bu_is_add, bu_side, bu_ready;
    logic [31:0] bu_price, bu_qty;

    logic        trade_valid, trade_side;
    logic [31:0] trade_qty;

    event_dispatcher u_dispatch (
        .clk(clk), .arstn(arstn),
        .ev(ev), .ev_valid(ev_valid), .ev_ready(ev_ready),
        .ins_valid(ins_valid), .ins_order_id(ins_order_id),
        .ins_price(ins_price), .ins_qty(ins_qty), .ins_side(ins_side),
        .qry_valid(qry_valid), .qry_order_id(qry_order_id),
        .qry_op(qry_op), .qry_qty(qry_qty),
        .lk_busy(lk_busy),
        .res_valid(res_valid), .res_hit(res_hit), .res_price(res_price),
        .res_side(res_side), .res_delta_qty(res_delta_qty),
        .res_removed(res_removed),
        .bu_valid(bu_valid), .bu_is_add(bu_is_add), .bu_price(bu_price),
        .bu_qty(bu_qty), .bu_side(bu_side), .bu_ready(bu_ready),
        .trade_valid(trade_valid), .trade_side(trade_side),
        .trade_qty(trade_qty),
        .miss_count(miss_count)
    );

    order_lookup #(.TABLE_BITS(TABLE_BITS)) u_lookup (
        .clk(clk), .arstn(arstn),
        .ins_valid(ins_valid), .ins_order_id(ins_order_id),
        .ins_price(ins_price), .ins_qty(ins_qty), .ins_side(ins_side),
        .qry_valid(qry_valid), .qry_order_id(qry_order_id),
        .qry_op(qry_op), .qry_qty(qry_qty),
        .busy(lk_busy),
        .res_valid(res_valid), .res_hit(res_hit), .res_price(res_price),
        .res_side(res_side), .res_delta_qty(res_delta_qty),
        .res_removed(res_removed)
    );

    // ---------------- book -> encoder -> tob ----------------
    logic [WINDOW_SIZE-1:0] bid_mask, ask_mask;
    logic [ADDR_W-1:0]      bid_rd_addr, ask_rd_addr;
    logic [31:0]            bid_rd_data, ask_rd_data;
    logic                   book_updated;

    book_update #(
        .BASE_PRICE(BASE_PRICE), .WINDOW_SIZE(WINDOW_SIZE)
    ) u_book (
        .clk(clk), .arstn(arstn),
        .bu_valid(bu_valid), .bu_is_add(bu_is_add), .bu_price(bu_price),
        .bu_qty(bu_qty), .bu_side(bu_side), .bu_ready(bu_ready),
        .bid_mask(bid_mask), .ask_mask(ask_mask),
        .bid_rd_addr(bid_rd_addr), .bid_rd_data(bid_rd_data),
        .ask_rd_addr(ask_rd_addr), .ask_rd_data(ask_rd_data),
        .book_updated(book_updated),
        .oow_count(oow_count)
    );

    logic [ADDR_W-1:0] best_bid_addr, best_ask_addr;
    logic              best_bid_valid, best_ask_valid;

    priority_encoder #(.WINDOW_SIZE(WINDOW_SIZE)) u_encoder (
        .clk(clk), .arstn(arstn),
        .bid_mask(bid_mask), .ask_mask(ask_mask),
        .best_bid_addr(best_bid_addr), .best_bid_valid(best_bid_valid),
        .best_ask_addr(best_ask_addr), .best_ask_valid(best_ask_valid)
    );

    tob_t tob;
    logic tob_valid;

    tob_tracker #(.WINDOW_SIZE(WINDOW_SIZE)) u_tob (
        .clk(clk), .arstn(arstn),
        .book_updated(book_updated),
        .best_bid_addr(best_bid_addr), .best_bid_valid(best_bid_valid),
        .best_ask_addr(best_ask_addr), .best_ask_valid(best_ask_valid),
        .bid_rd_addr(bid_rd_addr), .bid_rd_data(bid_rd_data),
        .ask_rd_addr(ask_rd_addr), .ask_rd_data(ask_rd_data),
        .tob(tob), .tob_valid(tob_valid)
    );

    // ---------------- features -> board link ----------------
    logic               feat_valid;
    logic signed [15:0] f_spr, f_tobi, f_ofi, f_emadev, f_mom, f_tflow;

    feature_engine #(.QTY_SHIFT(QTY_SHIFT)) u_feat (
        .clk(clk), .arstn(arstn),
        .tob_valid(tob_valid), .tob(tob),
        .trade_valid(trade_valid), .trade_side(trade_side),
        .trade_qty(trade_qty),
        .feat_valid(feat_valid),
        .f_spr(f_spr), .f_tobi(f_tobi), .f_ofi(f_ofi),
        .f_emadev(f_emadev), .f_mom(f_mom), .f_tflow(f_tflow)
    );

    board_link_tx u_link (
        .clk(clk), .arstn(arstn),
        .feat_valid(feat_valid),
        .f_spr(f_spr), .f_tobi(f_tobi), .f_ofi(f_ofi),
        .f_emadev(f_emadev), .f_mom(f_mom), .f_tflow(f_tflow),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),
        .drop_count(drop_count)
    );


    // ---------------- latency instrumentation ----------------
    // Taps only. No back-pressure, no handshake, nothing downstream depends on
    // it - deleting this instance cannot change the datapath's behaviour.
    // ev_handoff is the cycle the parser's event is actually accepted, which is
    // where a core-only measurement must start.
    latency_probe u_probe (
        .clk(clk), .arstn(arstn),

        .ev_handoff  (ev_valid && ev_ready),
        .book_updated(book_updated),
        .tob_valid   (tob_valid),
        .feat_valid  (feat_valid),

        .lat_last     (lat_last),
        .lat_min      (lat_min),
        .lat_max      (lat_max),
        .lat_sum      (lat_sum),
        .lat_count    (lat_count),
        .lat_resolve  (lat_resolve),
        .lat_book2tob (lat_book2tob),
        .lat_tob2feat (lat_tob2feat),
        .lat_ia_last  (lat_ia_last),
        .lat_ia_min   (lat_ia_min),
        .lat_unmatched(lat_unmatched)
    );

endmodule