/*
 * tb_order_lookup
 * ---------------
 * Unit test for order_lookup (order_id -> price/side/remaining-qty cache).
 *
 * TABLE_BITS deliberately shrunk to 4 (16 entries) so a collision case can be
 * forced with small order_ids: ids 1 and 17 share the low 4 bits, so inserting
 * 17 silently evicts 1 -> a later query on 1 MUST report res_hit=0.
 *
 * Covers:
 *   - insert then EXECUTE partial : hit, price/side resolved, delta=req_qty,
 *                                   removed=0, remaining decremented
 *   - EXECUTE the rest            : removed=1, slot freed
 *   - insert then CANCEL          : delta=req_qty
 *   - insert then DELETE          : delta = ALL remaining, removed=1
 *   - query unknown id            : res_hit=0
 *   - collision eviction          : evicted id queries as a miss
 *   - qty-clamp: EXECUTE more than resting -> remaining clamps to 0, removed=1
 */
`timescale 1ns/1ps

module tb_order_lookup;
    import ITCH50_pkg::*;

    localparam int TABLE_BITS = 4;

    logic        clk = 0, arstn = 0;
    logic        ins_valid = 0;
    logic [63:0] ins_order_id = 0;
    logic [31:0] ins_price = 0, ins_qty = 0;
    logic        ins_side = 0;
    logic        qry_valid = 0;
    logic [63:0] qry_order_id = 0;
    lookup_op_e  qry_op = OP_EXECUTE;
    logic [31:0] qry_qty = 0;
    logic        busy;
    logic        res_valid, res_hit, res_side, res_removed;
    logic [31:0] res_price, res_delta_qty;

    int pass_count = 0, fail_count = 0;

    order_lookup #(.TABLE_BITS(TABLE_BITS)) dut (
        .clk(clk), .arstn(arstn),
        .ins_valid(ins_valid), .ins_order_id(ins_order_id),
        .ins_price(ins_price), .ins_qty(ins_qty), .ins_side(ins_side),
        .qry_valid(qry_valid), .qry_order_id(qry_order_id),
        .qry_op(qry_op), .qry_qty(qry_qty),
        .busy(busy),
        .res_valid(res_valid), .res_hit(res_hit), .res_price(res_price),
        .res_side(res_side), .res_delta_qty(res_delta_qty),
        .res_removed(res_removed)
    );

    always #5 clk = ~clk;

    // watchdog: never let a wait-loop bug hang the sim indefinitely
    initial begin
        #100000;   // 100 us
        $error("[TIMEOUT] simulation did not finish - a wait loop is stuck");
        $finish;
    end

    // Status/results are sampled on the NEGEDGE. Sampling `busy`/`res_valid`
    // at the posedge races the DUT's own nonblocking state update (you read
    // the pre-update value and return a cycle too early). At the negedge all
    // posedge updates have settled, so the view is race-free. Stimulus is
    // driven on the negedge (blocking =) so it is stable before the posedge
    // the DUT samples it on.
    task automatic wait_idle();
        do @(negedge clk); while (busy);
    endtask

    task automatic do_insert(input logic [63:0] oid, input logic [31:0] price,
                             input logic [31:0] qty, input logic side);
        wait_idle();
        @(negedge clk);
        ins_valid    = 1'b1;
        ins_order_id = oid;
        ins_price    = price;
        ins_qty      = qty;
        ins_side     = side;
        @(negedge clk);
        ins_valid    = 1'b0;
        wait_idle();
    endtask

    // issue a query, block until res_valid, return outputs
    task automatic do_query(input logic [63:0] oid, input lookup_op_e op,
                            input logic [31:0] qty,
                            output logic hit, output logic [31:0] price,
                            output logic side, output logic [31:0] delta,
                            output logic removed);
        wait_idle();
        @(negedge clk);
        qry_valid    = 1'b1;
        qry_order_id = oid;
        qry_op       = op;
        qry_qty      = qty;
        @(negedge clk);
        qry_valid    = 1'b0;
        do @(negedge clk); while (!res_valid);   // res_valid pulses 1 cyc; caught at negedge
        hit     = res_hit;
        price   = res_price;
        side    = res_side;
        delta   = res_delta_qty;
        removed = res_removed;
    endtask

    task automatic check(input string desc, input logic cond);
        if (cond) begin pass_count++; $display("[PASS] %s", desc); end
        else      begin fail_count++; $error("[FAIL] %s", desc); end
    endtask

    logic       h, sd, rm;
    logic [31:0] pr, dl;

    initial begin
        repeat (4) @(posedge clk);
        arstn = 1;
        repeat (2) @(posedge clk);

        // --- insert oid=100, sell, 300 @ price 1_600_000 ---
        do_insert(64'd100, 32'd1_600_000, 32'd300, 1'b1);

        // EXECUTE 50 -> hit, delta=50, remaining=250, not removed
        do_query(64'd100, OP_EXECUTE, 32'd50, h, pr, sd, dl, rm);
        check("exec: hit",        h  == 1'b1);
        check("exec: price",      pr == 32'd1_600_000);
        check("exec: side=sell",  sd == 1'b1);
        check("exec: delta=50",   dl == 32'd50);
        check("exec: not removed",rm == 1'b0);

        // EXECUTE 250 more -> removed=1
        do_query(64'd100, OP_EXECUTE, 32'd250, h, pr, sd, dl, rm);
        check("exec2: hit",       h  == 1'b1);
        check("exec2: delta=250", dl == 32'd250);
        check("exec2: removed",   rm == 1'b1);

        // now oid=100 slot freed -> next query misses
        do_query(64'd100, OP_EXECUTE, 32'd1, h, pr, sd, dl, rm);
        check("after-drain: miss", h == 1'b0);

        // --- CANCEL path ---
        do_insert(64'd200, 32'd1_600_100, 32'd500, 1'b0);
        do_query(64'd200, OP_CANCEL, 32'd120, h, pr, sd, dl, rm);
        check("cancel: hit",       h  == 1'b1);
        check("cancel: side=buy",  sd == 1'b0);
        check("cancel: delta=120", dl == 32'd120);
        check("cancel: not removed", rm == 1'b0);

        // --- DELETE returns ALL remaining (380) ---
        do_query(64'd200, OP_DELETE, 32'd0, h, pr, sd, dl, rm);
        check("delete: hit",           h  == 1'b1);
        check("delete: delta=380(all)",dl == 32'd380);
        check("delete: removed",       rm == 1'b1);

        // --- unknown id ---
        do_query(64'd9999, OP_EXECUTE, 32'd1, h, pr, sd, dl, rm);
        check("unknown: miss", h == 1'b0);

        // --- collision: 1 and 17 share low 4 bits; 17 evicts 1 ---
        do_insert(64'd1,  32'd1_601_000, 32'd10, 1'b0);
        do_insert(64'd17, 32'd1_602_000, 32'd20, 1'b1);   // evicts oid=1
        do_query(64'd1,  OP_EXECUTE, 32'd1, h, pr, sd, dl, rm);
        check("collision: evicted id=1 misses", h == 1'b0);
        do_query(64'd17, OP_EXECUTE, 32'd5, h, pr, sd, dl, rm);
        check("collision: id=17 still hits", h  == 1'b1);
        check("collision: id=17 price",      pr == 32'd1_602_000);

        // --- clamp: execute more than resting ---
        do_insert(64'd50, 32'd1_600_500, 32'd30, 1'b0);
        do_query(64'd50, OP_EXECUTE, 32'd999, h, pr, sd, dl, rm);
        check("clamp: hit",     h  == 1'b1);
        check("clamp: removed", rm == 1'b1);   // drained to zero

        $display("========================================");
        $display("  PASSED: %0d   FAILED: %0d", pass_count, fail_count);
        $display(fail_count == 0 ? "  ALL TESTS PASSED" : "  THERE ARE FAILURES");
        $display("========================================");
        $finish;
    end

    initial begin
        $dumpfile("tb_order_lookup.vcd");
        $dumpvars(0, tb_order_lookup);
    end

endmodule
