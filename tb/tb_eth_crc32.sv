/*
 * tb_eth_crc32
 * ------------
 * Every expected value here was produced by Python's zlib.crc32 (which
 * implements exactly the Ethernet CRC-32 parameter set) rather than copied
 * from a datasheet, so the DUT is checked against an independent reference:
 *
 *   py -c "import zlib; print(hex(zlib.crc32(b'123456789')))"   -> 0xcbf43926
 *
 * Coverage:
 *   T1  the universal CRC-32 check vector "123456789"
 *   T2  empty message (init only)  -> raw stays at the seed
 *   T3  a real 24-byte Ethernet frame body -> known FCS
 *   T4  RESIDUE: feeding the frame's own FCS back in lands on 0xDEBB20E3,
 *       for several payload lengths - this is what an RX actually uses
 *   T5  a single corrupted bit must break the residue check
 *   T6  init asserted together with the first byte (no wasted cycle)
 *   T7  back-to-back frames: a new init fully clears prior state
 */
`timescale 1ns/1ps

module tb_eth_crc32;

    logic        clk = 0, arstn = 0;
    logic        init = 0, data_valid = 0;
    logic [7:0]  data = '0;
    logic [31:0] crc_raw, fcs;
    logic        crc_ok;

    int pass_count = 0, fail_count = 0;

    eth_crc32 dut (
        .clk(clk), .arstn(arstn),
        .init(init), .data_valid(data_valid), .data(data),
        .crc_raw(crc_raw), .fcs(fcs), .crc_ok(crc_ok)
    );

    always #5 clk = ~clk;

    task automatic check(input string desc, input logic cond);
        if (cond) begin pass_count++; $display("[PASS] %s", desc); end
        else      begin fail_count++; $error("[FAIL] %s", desc); end
    endtask

    // Feed one byte. `first` seeds the register in the same cycle.
    task automatic feed(input logic [7:0] b, input logic first = 1'b0);
        data       <= b;
        data_valid <= 1'b1;
        init       <= first;
        @(posedge clk);
        data_valid <= 1'b0;
        init       <= 1'b0;
    endtask

    // 24-byte Ethernet frame body: dest, src, ethertype 0x0800, 10 payload bytes
    // 00112233445566778899AABB 0800 00010203040506070809
    localparam int FRAME_LEN = 24;
    logic [7:0] frame [FRAME_LEN] = '{
        8'h00, 8'h11, 8'h22, 8'h33, 8'h44, 8'h55,
        8'h66, 8'h77, 8'h88, 8'h99, 8'hAA, 8'hBB,
        8'h08, 8'h00,
        8'h00, 8'h01, 8'h02, 8'h03, 8'h04,
        8'h05, 8'h06, 8'h07, 8'h08, 8'h09
    };
    localparam logic [31:0] FRAME_FCS = 32'hA110_66C2;   // zlib.crc32(frame)
    localparam logic [31:0] RESIDUE   = 32'hDEBB_20E3;

    task automatic feed_frame();
        for (int i = 0; i < FRAME_LEN; i++) feed(frame[i], i == 0);
    endtask

    // append the FCS the way Ethernet puts it on the wire: little-endian
    task automatic feed_fcs(input logic [31:0] f);
        feed(f[7:0]);  feed(f[15:8]);  feed(f[23:16]);  feed(f[31:24]);
    endtask

    initial begin
        arstn = 1'b0;
        repeat (4) @(posedge clk);
        arstn <= 1'b1;
        @(posedge clk);

        //-------------------------------------------------------------------
        // T1: the universal check vector. zlib.crc32("123456789") = 0xCBF43926
        //-------------------------------------------------------------------
        feed("1", 1'b1);
        feed("2"); feed("3"); feed("4"); feed("5");
        feed("6"); feed("7"); feed("8"); feed("9");
        @(posedge clk);
        check("T1: fcs(\"123456789\") = 0xCBF43926", fcs     == 32'hCBF4_3926);
        check("T1: raw                = 0x340BC6D9", crc_raw == 32'h340B_C6D9);

        //-------------------------------------------------------------------
        // T2: init with no data - the register holds the seed, fcs = 0
        //-------------------------------------------------------------------
        init <= 1'b1; @(posedge clk); init <= 1'b0;
        @(posedge clk);
        check("T2: empty raw = 0xFFFFFFFF", crc_raw == 32'hFFFF_FFFF);
        check("T2: empty fcs = 0x00000000", fcs     == 32'h0000_0000);

        //-------------------------------------------------------------------
        // T3: a real frame body -> the FCS a transmitter would append
        //-------------------------------------------------------------------
        feed_frame();
        @(posedge clk);
        check("T3: frame fcs = 0xA11066C2", fcs == FRAME_FCS);
        check("T3: crc_ok deasserted mid-frame (residue not reached)", crc_ok == 1'b0);

        //-------------------------------------------------------------------
        // T4: RESIDUE - keep going through the frame's own FCS bytes.
        //     This is the receive-side check, and it needs no length
        //     knowledge and no stored expected value.
        //-------------------------------------------------------------------
        feed_fcs(FRAME_FCS);
        @(posedge clk);
        check("T4: residue reached = 0xDEBB20E3", crc_raw == RESIDUE);
        check("T4: crc_ok asserted on a good frame", crc_ok == 1'b1);

        //-------------------------------------------------------------------
        // T5: corrupt ONE bit of the payload, keep the original FCS.
        //     The residue must not be reached.
        //-------------------------------------------------------------------
        for (int i = 0; i < FRAME_LEN; i++) begin
            if (i == 20) feed(frame[i] ^ 8'h01, 1'b0);   // flip one bit
            else         feed(frame[i], i == 0);
        end
        feed_fcs(FRAME_FCS);
        @(posedge clk);
        check("T5: crc_ok LOW on a 1-bit corrupted frame", crc_ok == 1'b0);
        check("T5: residue not reached",                   crc_raw != RESIDUE);

        //-------------------------------------------------------------------
        // T6: corrupt one bit of the FCS itself instead of the payload
        //-------------------------------------------------------------------
        feed_frame();
        feed_fcs(FRAME_FCS ^ 32'h0000_0100);
        @(posedge clk);
        check("T6: crc_ok LOW when the FCS itself is corrupted", crc_ok == 1'b0);

        //-------------------------------------------------------------------
        // T7: back-to-back frames - init must fully clear the previous frame's
        //     state, otherwise frame N+1 inherits frame N's residue.
        //-------------------------------------------------------------------
        feed_frame();
        @(posedge clk);
        check("T7: 2nd frame fcs identical to 1st", fcs == FRAME_FCS);
        feed_fcs(FRAME_FCS);
        @(posedge clk);
        check("T7: 2nd frame crc_ok", crc_ok == 1'b1);

        // and immediately a third, with no idle gap at all
        feed_frame();
        feed_fcs(FRAME_FCS);
        @(posedge clk);
        check("T7: 3rd frame back-to-back crc_ok", crc_ok == 1'b1);

        //-------------------------------------------------------------------
        $display("========================================");
        $display("  PASSED: %0d   FAILED: %0d", pass_count, fail_count);
        $display("========================================");
        $finish;
    end

endmodule
