// tb_victim_cache_equiv.v  (testbench, this repository)
// Lockstep test of the victim cache: the timing-optimised l1d_victim_cache (V-1, V-2, V-4, V-5; V-3 and V-6 were tried and dropped
//) against the ORIGINAL victim cache of the original design (renamed l1d_victim_cache_ref with its own
// l1d_age_matrix_ref by scripts/make_entry_ref.sh).
// Same inputs for both; every output (lookup hit / slot / state / data / dirty / shared, victim slot available / index, write-back request
// valid / line / slot / data, all_slots_free, slot_freed_pulses) must be equal in every cycle.
// Stimulus (bank-like): the line looked up is last cycle's lookup_line_addr_next (s2_line <= s1_line, as tb/formal/fv_wrap_victim_cache.v);
// a B response (writeback_done) only for a slot whose write was handed to the write channel and not answered yet; no insert into a slot whose
// write is offered or out; never an x line address (looked up or held by a slot that is swapped).
// Everything else is random, also several operations on one slot in the same cycle (insert beats release beats snoop beats swap, as in the RTL).
// Options (iverilog -D / xvlog -d):   NCYC=<n> cycles (default 300000)   SEED=<n> (default 1)

`timescale 1ns/1ps
`include "l1d_defines.vh"

module tb_victim_cache_equiv #(`L1D_PARAMS) ();
    `include "l1d_encodings.vh"
    `include "l1d_fields.vh"

`ifdef NCYC
    localparam NCYC = `NCYC;
`else
    localparam NCYC = 300000;
`endif
`ifdef SEED
    localparam SEED0 = `SEED;
`else
    localparam SEED0 = 1;
`endif
    localparam N  = VC_SLOTS;                         // N = 8 slots
    localparam NP = 12;                               // lines in the pool (repeats give multi-slot matches)

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    // inputs
    reg  [LINE_ADDR_W-1:0] lk_next;                   // LINE_ADDR_W = 58 bits
    reg  [LINE_ADDR_W-1:0] lk_q;                      // the bank's s2_line: last cycle's s1_line
    reg                    insert_valid, insert_dirty, insert_shared, insert_wbp;
    reg  [VC_ID_W-1:0]     insert_slot;               // VC_ID_W = 3 bits
    reg  [LINE_ADDR_W-1:0] insert_line;
    reg  [LINE_W-1:0]      insert_data;               // LINE_W = 512 bits
    reg                    swap_valid, release_valid, snoop_valid, snoop_inv, drain, wr_ready, done_valid;
    reg  [VC_ID_W-1:0]     swap_slot, release_slot, snoop_slot, done_slot;

    // outputs: o_ = optimised, r_ = reference
    wire                   o_hit, r_hit, o_dty, r_dty, o_shr, r_shr, o_av, r_av, o_wv, r_wv, o_empty, r_empty;
    wire [VC_ID_W-1:0]     o_slot, r_slot, o_vidx, r_vidx, o_wslot, r_wslot;
    wire [2:0]             o_st, r_st;
    wire [LINE_W-1:0]      o_data, r_data, o_wdata, r_wdata;
    wire [LINE_ADDR_W-1:0] o_wline, r_wline;
    wire [N-1:0]           o_freed, r_freed;

    always @(posedge clk) lk_q <= lk_next;

`define VC_IN \
        .clk(clk), .rst(rst), .lookup_line_addr(lk_q), \
        .insert_valid(insert_valid), .insert_slot(insert_slot), .insert_line_addr(insert_line), .insert_line_data(insert_data), \
        .insert_dirty(insert_dirty), .insert_shared(insert_shared), .insert_as_writeback_pending(insert_wbp), \
        .swap_start_valid(swap_valid), .swap_start_slot(swap_slot), .release_valid(release_valid), .release_slot(release_slot), \
        .snoop_hit_valid(snoop_valid), .snoop_hit_slot(snoop_slot), .snoop_invalidate(snoop_inv), .drain_enable(drain), \
        .writeback_req_ready(wr_ready), .writeback_done_valid(done_valid), .writeback_done_slot_id(done_slot),

    l1d_victim_cache dut_opt (`VC_IN .lookup_line_addr_next(lk_next),
        .lookup_hit(o_hit), .lookup_slot(o_slot), .lookup_slot_state(o_st), .lookup_line_data(o_data), .lookup_dirty(o_dty),
        .lookup_shared(o_shr), .victim_slot_available(o_av), .victim_slot_index(o_vidx),
        .writeback_req_valid(o_wv), .writeback_req_line_addr(o_wline), .writeback_req_slot_id(o_wslot), .writeback_req_data(o_wdata),
        .all_slots_free(o_empty), .slot_freed_pulses(o_freed));
    l1d_victim_cache_ref dut_ref (`VC_IN
        .lookup_hit(r_hit), .lookup_slot(r_slot), .lookup_slot_state(r_st), .lookup_line_data(r_data), .lookup_dirty(r_dty),
        .lookup_shared(r_shr), .victim_slot_available(r_av), .victim_slot_index(r_vidx),
        .writeback_req_valid(r_wv), .writeback_req_line_addr(r_wline), .writeback_req_slot_id(r_wslot), .writeback_req_data(r_wdata),
        .all_slots_free(r_empty), .slot_freed_pulses(r_freed));

    // AXI model: a slot is "sent" from the hand-over of its write (valid and ready) until its B response
    reg [N-1:0] sent;                                 // N = 8 bits
    always @(posedge clk) begin
        if (rst) sent <= {N{1'b0}};
        else begin
            if (r_wv && wr_ready)  sent[r_wslot]  <= 1'b1;
            if (done_valid)        sent[done_slot] <= 1'b0;
        end
    end

    integer seed, cyc, errors, k, kk, ph, p_ins, p_rdy, n_try;
    integer n_ins, n_ins_wbp, n_hit, n_multi, n_hand, n_b, n_drain, n_full, n_swap, n_rel, n_snp, n_pick_dirty, n_same_slot;
    reg [LINE_ADDR_W-1:0] pool [0:NP-1];

    function [31:0] rnd;       // random number 0..2**31-1 (advances seed)
        input dummy;
        begin
            rnd = $random(seed);
            rnd = rnd & 32'h7fffffff;
        end
    endfunction

    function integer popcount;
        input [N-1:0] v;
        integer q;
        begin
            popcount = 0;
            for (q = 0; q < N; q = q + 1) popcount = popcount + v[q];
        end
    endfunction

    // a random slot in state s of the reference (or -1 when none), found from a random starting point
    function integer slot_in;
        input [2:0] s;
        integer b, q, found;
        begin
            found = -1;  b = rnd(0) % N;
            for (q = 0; q < N; q = q + 1)
                if (found < 0 && dut_ref.st[(b + q) % N] === s) found = (b + q) % N;
            slot_in = found;
        end
    endfunction

    task drive;
        integer t;
        begin
            ph = (cyc / 5000) % 4;                     // 0 fill up, 1 drain, 2 light traffic, 3 heavy traffic with a slow write channel
            p_ins = (ph == 0) ? 60 : (ph == 3) ? 45 : 20;
            p_rdy = (ph == 3) ? 15 : 60;
            drain    = (ph == 1) && ((cyc % 5000) < 1500);
            wr_ready = (rnd(0) % 100) < p_rdy;
            // B response: only for a sent slot
            done_valid = 1'b0;  done_slot = rnd(0) % N;
            if (sent != {N{1'b0}} && (rnd(0) % 100) < 30) begin
                n_try = 0;
                while (!sent[done_slot] && n_try < 16) begin done_slot = rnd(0) % N; n_try = n_try + 1; end
                done_valid = sent[done_slot];
            end
            // insert a victim: mostly into the slot the cache offers (as the bank), sometimes anywhere; never into a sent slot
            insert_valid = (rnd(0) % 100) < p_ins;
            insert_slot  = (r_av && (rnd(0) % 5) != 0) ? r_vidx : (rnd(0) % N);
            // never into a slot whose write is out or still offered on the write channel (the bank inserts only into a FREE, clean VALID
            // or MOVING slot, and an offered or sent slot stays WBPEND there). Runs 1 and 2 of this test broke that rule: run 1 inserted into
            // the slot handed over at that edge, run 2 into an offered slot that the random any-slot swap and a release had freed.
            if (sent[insert_slot] || (r_wv && r_wslot == insert_slot)) insert_valid = 1'b0;
            insert_line  = pool[rnd(0) % NP];
            for (t = 0; t < LINE_W / 32; t = t + 1) insert_data[t*32 +: 32] = $random(seed);
            insert_dirty  = rnd(0) % 2;
            insert_shared = (rnd(0) % 4) == 0;
            insert_wbp    = (rnd(0) % 10) == 0;
            // swap start on a VALID slot (a hit), release of a MOVING slot, snoop on a VALID slot; now and then on any slot
            kk = slot_in(VC_VALID);
            swap_valid = (kk >= 0) && (rnd(0) % 100) < 10;   swap_slot = (kk >= 0) ? kk : 0;
            // now and then a swap on any slot, but only one whose line is defined: a swap on a never-written slot makes it "in use" with an
            // x line, which the old encoder and the new AND-OR resolve differently in simulation (the bank swaps only a VALID slot it hit)
            if ((rnd(0) % 50) == 0) begin
                kk = rnd(0) % N;
                if (^dut_ref.la[kk] !== 1'bx) begin swap_valid = 1'b1; swap_slot = kk; end
            end
            kk = slot_in(VC_MOVING);
            release_valid = (kk >= 0) && (rnd(0) % 100) < 15;  release_slot = (kk >= 0) ? kk : 0;
            kk = slot_in(VC_VALID);
            snoop_valid = (kk >= 0) && (rnd(0) % 100) < 8;   snoop_slot = (kk >= 0) ? kk : 0;  snoop_inv = rnd(0) % 2;
            // the line looked up next cycle: mostly a line held in a slot, else a pool line or a new line
            k = rnd(0) % 10;
            if (k < 6) begin                           // a slot's line, but never an unwritten (x) one: the bank never looks up an x
                lk_next = dut_ref.la[rnd(0) % N];      // address, and x is resolved differently by the old encoder and the new AND-OR
                if (^lk_next === 1'bx) lk_next = pool[rnd(0) % NP];
            end
            else if (k < 9) lk_next = pool[rnd(0) % NP];
            else begin lk_next[31:0] = rnd(0); lk_next[LINE_ADDR_W-1:32] = rnd(0); end
        end
    endtask

    initial begin
        seed = SEED0; errors = 0; cyc = 0;
        n_ins = 0; n_ins_wbp = 0; n_hit = 0; n_multi = 0; n_hand = 0; n_b = 0; n_drain = 0; n_full = 0; n_swap = 0; n_rel = 0; n_snp = 0;
        n_pick_dirty = 0; n_same_slot = 0;
        for (k = 0; k < NP; k = k + 1) begin pool[k][31:0] = rnd(0) ^ (rnd(0) << 1); pool[k][LINE_ADDR_W-1:32] = rnd(0); end
        lk_next = 0; lk_q = 0; insert_valid = 0; insert_slot = 0; insert_line = 0; insert_data = 0; insert_dirty = 0; insert_shared = 0;
        insert_wbp = 0; swap_valid = 0; swap_slot = 0; release_valid = 0; release_slot = 0; snoop_valid = 0; snoop_slot = 0; snoop_inv = 0;
        drain = 0; wr_ready = 0; done_valid = 0; done_slot = 0;
        rst = 1'b1;
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        for (cyc = 0; cyc < NCYC; cyc = cyc + 1) begin
            @(negedge clk);
            drive;
            #1;                                        // inputs of this cycle settled: compare with exactly the inputs the next edge samples
            if (o_hit !== r_hit || o_slot !== r_slot || o_st !== r_st || o_data !== r_data || o_dty !== r_dty || o_shr !== r_shr ||
                // VC-A: the write-back address / slot / data are compared only while writeback_req_valid (l1d_bank.v reads them only then)
                o_av !== r_av || o_vidx !== r_vidx || o_wv !== r_wv ||
                (r_wv === 1'b1 && (o_wline !== r_wline || o_wslot !== r_wslot || o_wdata !== r_wdata)) ||
                o_empty !== r_empty || o_freed !== r_freed) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("MISMATCH cycle %0d: hit %b/%b slot %0d/%0d state %0d/%0d dirty %b/%b shared %b/%b avail %b/%b vidx %0d/%0d wb %b/%b wslot %0d/%0d empty %b/%b freed %b/%b%s%s%s",
                             cyc, o_hit, r_hit, o_slot, r_slot, o_st, r_st, o_dty, r_dty, o_shr, r_shr, o_av, r_av, o_vidx, r_vidx, o_wv, r_wv,
                             o_wslot, r_wslot, o_empty, r_empty, o_freed, r_freed, (o_data !== r_data) ? "  lookup data differs" : "",
                             (r_wv === 1'b1 && o_wline !== r_wline) ? "  wb line differs" : "", (r_wv === 1'b1 && o_wdata !== r_wdata) ? "  wb data differs" : "");
            end
            // coverage
            if (insert_valid)                    n_ins = n_ins + 1;
            if (insert_valid && insert_wbp)      n_ins_wbp = n_ins_wbp + 1;
            if (r_hit)                           n_hit = n_hit + 1;
            if (popcount(dut_opt.lk_match_q) > 1) n_multi = n_multi + 1;
            if (r_wv && wr_ready)                n_hand = n_hand + 1;
            if (done_valid)                      n_b = n_b + 1;
            if (drain)                           n_drain = n_drain + 1;
            if (!r_av)                           n_full = n_full + 1;
            if (swap_valid)                      n_swap = n_swap + 1;
            if (release_valid)                   n_rel = n_rel + 1;
            if (snoop_valid)                     n_snp = n_snp + 1;
            if (dut_ref.wb_start && !dut_ref.any_pend) n_pick_dirty = n_pick_dirty + 1;
            if (insert_valid && ((swap_valid && swap_slot == insert_slot) || (release_valid && release_slot == insert_slot) ||
                                 (snoop_valid && snoop_slot == insert_slot) || (done_valid && done_slot == insert_slot)))
                n_same_slot = n_same_slot + 1;
        end
        $display("cycles %0d  inserts %0d (as WBPEND %0d)  lookup hits %0d  multi-slot matches %0d  write hand-overs %0d  B responses %0d",
                 NCYC, n_ins, n_ins_wbp, n_hit, n_multi, n_hand, n_b);
        $display("drain cycles %0d  no victim slot %0d  swaps %0d  releases %0d  snoops %0d  dirty write-back starts %0d  same-slot operations %0d",
                 n_drain, n_full, n_swap, n_rel, n_snp, n_pick_dirty, n_same_slot);
        if (n_ins < 5000 || n_hit < 5000 || n_multi < 500 || n_hand < 1000 || n_b < 1000 || n_full < 1000 || n_swap < 1000 ||
            n_rel < 500 || n_snp < 500 || n_pick_dirty < 500 || n_ins_wbp < 300 || n_same_slot < 100) begin
            $display("COVERAGE TOO LOW");
            errors = errors + 1;
        end
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d mismatching cycles / errors", errors);
        $finish;
    end
endmodule
