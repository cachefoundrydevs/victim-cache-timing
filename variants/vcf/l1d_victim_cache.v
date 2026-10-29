// ============================================================================
// l1d_victim_cache.v  -  the victim cache of one bank
// ============================================================================
// IN SIMPLE WORDS
//   When the cache needs room for a new line it throws one old line out (the "victim"). Instead of losing it, the
//   victim goes into this small fully-associative buffer of VC_SLOTS (8) slots. If the CPU asks for that line soon
//   again (a conflict miss), it is found here and swapped back - much faster than a trip to memory. Slots can hold
//   clean or dirty lines (a design rule). The victim cache knows nothing about ways: Stage 1 picks the victim way,
//   this unit only says which SLOT will take it.
//
// THE SLOT STATES  
//   FREE     empty
//   VALID    holds an evicted line (dty = dirty). A hit on it starts a SWAP back into the cache.
//   MOVING   the line was copied into an MSHR entry for a swap back; the slot is RESERVED for the victim of that install.
//            Requests that need it wait (seat state WANY) until the MSHR entry is freed.
//   WBPEND   a DIRTY line being written to memory. It can still be found: loads are answered from it. It is freed only by
//            the AXI B response; store-class requests wait for it (seat state WVC).
//
//     insert (victim)            hit + swap                swap installed         dirty + (no free slot or drain)
//   FREE ----------------> VALID ----------> MOVING ----------------> FREE         VALID ----------------> WBPEND
//                                              (release_valid if the install had no victim)        --B response--> FREE
//
// THE OPERATIONS (all requested by the bank pipeline)
//   lookup      Stage 2: is the missing line here? (combinational: a CAM + priority encoder)
//   alloc query Stage 1: which slot will take a victim? A FREE slot, else the OLDEST clean VALID slot (its line is simply
//               dropped: memory already has it). victim_slot_available = 0 when neither exists -> the refill token is held.
//   insert      Stage 2: put a victim (or a flush / clean line) into the chosen slot
//   swap start  Stage 2: a hit on a VALID slot starts a swap -> MOVING
//   release     Stage 2: a swap installed into an empty way, so the MOVING slot gets no victim -> FREE
//   drain       flush / clean: drop clean lines, write back dirty ones
//
// v2 (MESI and snoops)
//   Every slot keeps a "shared" bit (the line was S), so a swap back installs S. A snoop that finds a VALID slot acts on
//   it in Stage 2: invalidate -> the slot becomes FREE (a dirty line's data goes out in the answer); read -> the slot stays
//   VALID, now shared and clean. The snooped slot is kept out of the writeback and victim choices in that cycle, like a
//   slot starting a swap. A snoop never touches a MOVING or WBPEND slot: it waits for the install or the B response.
//
// WRITEBACK ENGINE
//   When no slot is FREE (or while draining) the first VALID dirty slot becomes WBPEND and its line is sent on the
//   bank's write channel (AXI AW + W burst). Slots inserted directly as WBPEND (flush / clean) are sent the same way. One
//   line is handed over at a time; several may wait for their B responses. A B response frees the slot and pulses
//   slot_freed_pulses, which wakes the requests waiting for it. Write-back order is fixed priority (lowest slot first).
//
// PORTS (new name, old name, meaning)
//   lookup_line_addr                     (was lk_line)                  line address looked up
//   lookup_hit                           (was lk_hit)                   the line is in a slot
//   lookup_slot                          (was lk_slot)                  number of that slot
//   lookup_slot_state                    (was lk_state)                 state of that slot (VC_FREE / VC_VALID / VC_MOVING / VC_WBPEND)
//   lookup_line_data                     (was lk_data)                  line data of that slot
//   lookup_dirty                         (was lk_dirty)                 that line is dirty
//   lookup_shared                        (was lk_shared)                that line was shared
//   victim_slot_available                (was al_ok)                    a slot can take the next victim
//   victim_slot_index                    (was al_slot)                  number of that slot
//   insert_valid                         (was ins_valid)                put a line into a slot
//   insert_slot                          (was ins_slot)                 slot to use
//   insert_line_addr                     (was ins_line)                 line address
//   insert_line_data                     (was ins_data)                 line data
//   insert_dirty                         (was ins_dirty)                the line is dirty
//   insert_shared                        (was ins_shared)               the line was shared
//   insert_as_writeback_pending          (was ins_wbpend)               flush/clean: write the line back at once
//   swap_start_valid                     (was swap_start)               a hit starts a swap back into the cache
//   swap_start_slot                      (was swap_slot)                slot of that swap
//   release_valid                        (was rel_valid)                a swap installed into an empty way: free the reserved slot
//   release_slot                         (was rel_slot)                 slot to free
//   snoop_hit_valid                      (was snp_valid)                a snoop hit a VALID slot
//   snoop_hit_slot                       (was snp_slot)                 that slot
//   snoop_invalidate                     (was snp_inv)                  1 = invalidate (slot becomes free), 0 = read (slot becomes shared and clean)
//   drain_enable                         (was drain)                    flush/clean: drop clean lines, write back dirty ones
//   writeback_req_valid                  (was wr_valid)                 a line is offered on the bank's write channel
//   writeback_req_ready                  (was wr_ready)                 the write channel takes it
//   writeback_req_line_addr              (was wr_line)                  line address to write
//   writeback_req_slot_id                (was wr_sub)                   slot number, sent as the AXI id
//   writeback_req_data                   (was wr_data)                  line data to write
//   writeback_done_valid                 (was b_valid)                  the AXI write response for a slot arrived
//   writeback_done_slot_id               (was b_sub)                    slot number from the AXI id
//   all_slots_free                       (was empty)                    every slot is free
//   slot_freed_pulses                    (was freed)                    one bit per slot: it became free
//
// VERILOG WORDS USED IN THIS FILE
//   reg [2:0] st [0:N-1]   arrays with one entry per slot: st = state, la = line address, dty = dirty, shr = shared,
//                          iss = writeback already handed over, dmem = the 512-bit line (no reset; st says what is valid)
//   output reg slot_freed_pulses   a register: a one-cycle pulse per freed slot
// ============================================================================

`default_nettype none
`include "l1d_defines.vh"

module l1d_victim_cache #(`L1D_PARAMS) (
    clk, rst,
    lookup_line_addr_next, lookup_line_addr, lookup_hit, lookup_slot, lookup_slot_state, lookup_line_data, lookup_dirty, lookup_shared,
    victim_slot_available, victim_slot_index,
    insert_valid, insert_slot, insert_line_addr, insert_line_data, insert_dirty, insert_shared, insert_as_writeback_pending,
    swap_start_valid, swap_start_slot,
    release_valid, release_slot,
    snoop_hit_valid, snoop_hit_slot, snoop_invalidate,
    drain_enable,
    writeback_req_valid, writeback_req_ready, writeback_req_line_addr, writeback_req_slot_id, writeback_req_data,
    writeback_done_valid, writeback_done_slot_id,
    all_slots_free, slot_freed_pulses
);
    `include "l1d_encodings.vh"
    `include "l1d_fields.vh"

    // N = number of slots
    localparam N = VC_SLOTS;

    input  wire                   clk;                    // clock: all registers change on its rising edge
    input  wire                   rst;                    // synchronous reset, active high (control state goes to its idle value)
    // lookup (Stage 2)
    input  wire [LINE_ADDR_W-1:0] lookup_line_addr_next;  // TIMING OPT (V-5): the line address looked up in the NEXT cycle (bank: s1_line,
                                                          // which becomes s2_line at every clock edge); the match is computed one cycle ahead
    input  wire [LINE_ADDR_W-1:0] lookup_line_addr;       // line address looked up (= lookup_line_addr_next of the previous cycle; checked in simulation)
    output wire                   lookup_hit;             // the line is in a slot
    output wire [VC_ID_W-1:0]     lookup_slot;            // number of that slot
    output wire [2:0]             lookup_slot_state;      // state of that slot (VC_FREE / VC_VALID / VC_MOVING / VC_WBPEND)
    output wire [LINE_W-1:0]      lookup_line_data;       // line data of that slot
    output wire                   lookup_dirty;           // that line is dirty
    output wire                   lookup_shared;          // that line was shared
    // slot for the next victim (Stage 1)
    output wire                   victim_slot_available;  // a slot can take the next victim
    output wire [VC_ID_W-1:0]     victim_slot_index;      // number of that slot
    // insert (Stage 2)
    input  wire                   insert_valid;           // put a line into a slot
    input  wire [VC_ID_W-1:0]     insert_slot;            // slot to use
    input  wire [LINE_ADDR_W-1:0] insert_line_addr;       // line address
    input  wire [LINE_W-1:0]      insert_line_data;       // line data
    input  wire                   insert_dirty;           // the line is dirty
    input  wire                   insert_shared;          // the line was shared
    input  wire                   insert_as_writeback_pending;  // flush/clean: write the line back at once
    // swap start (Stage 2)
    input  wire                   swap_start_valid;       // a hit starts a swap back into the cache
    input  wire [VC_ID_W-1:0]     swap_start_slot;        // slot of that swap
    // swap installed without a victim (Stage 2)
    input  wire                   release_valid;          // a swap installed into an empty way: free the reserved slot
    input  wire [VC_ID_W-1:0]     release_slot;           // slot to free
    // snoop on a VALID slot (Stage 2)
    input  wire                   snoop_hit_valid;        // a snoop hit a VALID slot
    input  wire [VC_ID_W-1:0]     snoop_hit_slot;         // that slot
    input  wire                   snoop_invalidate;       // 1 = invalidate (slot becomes free), 0 = read (slot becomes shared and clean)
    // flush / clean drain
    input  wire                   drain_enable;           // flush/clean: drop clean lines, write back dirty ones
    // write channel (to the bank's AXI write arbiter)
    output wire                   writeback_req_valid;    // a line is offered on the bank's write channel
    input  wire                   writeback_req_ready;    // the write channel takes it
    output wire [LINE_ADDR_W-1:0] writeback_req_line_addr;  // line address to write
    output wire [VC_ID_W-1:0]     writeback_req_slot_id;  // slot number, sent as the AXI id
    output wire [LINE_W-1:0]      writeback_req_data;     // line data to write
    // write response for one of this bank's slots
    input  wire                   writeback_done_valid;   // the AXI write response for a slot arrived
    input  wire [VC_ID_W-1:0]     writeback_done_slot_id; // slot number from the AXI id
    // status
    output wire                   all_slots_free;         // every slot is free
    output reg  [N-1:0]           slot_freed_pulses;      // one bit per slot: it became free

    // ---- the memory of the victim cache: one record per slot ----
    reg [2:0]             st   [0:N-1];                   // slot state (VC_FREE / VC_VALID / VC_MOVING / VC_WBPEND)
    reg [LINE_ADDR_W-1:0] la   [0:N-1];                   // line address stored in the slot
    reg                   dty  [0:N-1];                   // the line is dirty (memory is stale)
    reg                   shr  [0:N-1];   // line was shared (S): a swap back installs S
    reg                   iss  [0:N-1];   // WBPEND line already handed to the write channel
    reg [LINE_W-1:0]      dmem [0:N-1];                   // the line data (512 bits)

    // per-slot summaries: in_use = not FREE; is_free / is_clean / is_dirty / is_pend = candidates for a victim, a drop or a
    // writeback; excl = the slot is being swapped or snooped in this very cycle, so it is not a candidate
    wire [N-1:0]             in_use, is_free, is_clean, is_dirty, is_pend;
    wire [N-1:0]             excl;        // slot starting a swap or snooped this cycle: not a candidate

    // one set of summary gates per slot (g_slot[0] .. g_slot[N-1])
    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : g_slot
            assign excl[g]     = (swap_start_valid && (swap_start_slot == g)) || (snoop_hit_valid && (snoop_hit_slot == g));
            assign in_use[g]   = (st[g] != VC_FREE);
            assign is_free[g]  = (st[g] == VC_FREE) && !excl[g];
            assign is_clean[g] = (st[g] == VC_VALID) && !dty[g] && !excl[g];
            assign is_dirty[g] = (st[g] == VC_VALID) &&  dty[g] && !excl[g];
            assign is_pend[g]  = (st[g] == VC_WBPEND) && !iss[g];
        end
    endgenerate

    // ---------------- lookup ----------------
    // ---- lookup: CAM over the slots in use, then the slot number (lookup_slot) and its state / data / flags ----
    // TIMING OPT (V-5): the CAM result is computed one cycle AHEAD and registered: lk_match_q = the slots that will be in use
    // and hold lookup_line_addr_next after this clock edge. In the next cycle that is exactly the old CAM result (in_use & la == lookup_line_addr),
    // because the bank looks up next cycle the line it gives as lookup_line_addr_next now (s2_line <= s1_line, no stall). Right after reset
    // every slot is free, so the match is 0 either way. The 58-bit compares now end in a flop instead of starting the lookup outputs.
    // TIMING OPT (VC-F): only the ADDRESS part of the look-ahead is registered (lk_addr_q: the slot will hold lookup_line_addr_next after
    // this edge); the "in use" part is taken AFTER the flop from the slot state itself, because "st_n != FREE now" is exactly "st != FREE"
    // in the next cycle. So lk_match_q is the same value as before in every cycle (no assumption), and the late write-back pick (wb_set)
    // no longer reaches the look-ahead flops; the lookup outputs get one more gate (the in-use decode).
    reg  [N-1:0] lk_addr_q;                               // N = 8 bits
    wire [N-1:0] lk_match_q = lk_addr_q & in_use;         // N = 8 bits (the name is kept: the test counts multi-slot matches with it)
    wire [N-1:0] lk_match = lk_match_q;                   // N = 8 bits
    // TIMING OPT (V-1): the lowest matching slot as ONE-HOT bits (prefix chain) and the slot's state, data, dirty and shared bits
    // by AND-OR with it, not the encoded number as a mux select (512-bit data). lk_pick = lk_first, or slot 0 when no other slot is picked,
    // which is what the old binary mux showed when nothing matched (number 0), so every output is equal in every cycle.
    reg  [N-1:0] lk_first;                                // lowest matching slot, one-hot (zero when no match), N = 8 bits
    reg          lk_seen;
    reg  [VC_ID_W-1:0] lk_idx;                            // its number (OR-encode), VC_ID_W = 3 bits
    integer      q;
    always @* begin
        lk_seen = 1'b0;
        lk_idx  = {VC_ID_W{1'b0}};
        for (q = 0; q < N; q = q + 1) begin
            lk_first[q] = lk_match[q] & ~lk_seen;
            lk_seen     = lk_seen | lk_match[q];
            if (lk_first[q]) lk_idx = lk_idx | q[VC_ID_W-1:0];
        end
    end
    assign lookup_hit  = |lk_match;
    assign lookup_slot = lk_idx;
    wire [N-1:0] lk_pick = {lk_first[N-1:1], ~|lk_first[N-1:1]};   // N = 8 bits
    reg  [2:0]        lk_st;                              // 3 bits
    reg  [LINE_W-1:0] lk_data;                            // LINE_W = 512 bits
    reg               lk_dty, lk_shr;
    always @* begin
        lk_st = 3'd0;  lk_data = {LINE_W{1'b0}};  lk_dty = 1'b0;  lk_shr = 1'b0;
        for (q = 0; q < N; q = q + 1) begin
            lk_st   = lk_st   | ({3{lk_pick[q]}}      & st[q]);
            lk_data = lk_data | ({LINE_W{lk_pick[q]}} & dmem[q]);
            lk_dty  = lk_dty  | (lk_pick[q] & dty[q]);
            lk_shr  = lk_shr  | (lk_pick[q] & shr[q]);
        end
    end
    assign lookup_slot_state = lk_st;
    assign lookup_line_data  = lk_data;
    assign lookup_dirty      = lk_dty;
    assign lookup_shared     = lk_shr;

    // ---------------- slot for the next victim ----------------
    // ---- slot for the next victim: a free slot first; otherwise the oldest clean one (age matrix, insertion order) ----
    // TIMING OPT (V-4): the lowest free / pending / dirty slot as ONE-HOT bits (prefix chains); the numbers that are outputs
    // or debug signals are OR-encodes of them (the same number l1d_pri_enc gives: the lowest set bit). The functions read only their
    // arguments, so calling them from continuous assignments is safe in simulation.
    function [N-1:0] lowest_oh;                           // lowest set bit of v, one-hot (zero when v = 0)
        input [N-1:0] v;
        integer b;
        reg seen;
        begin
            seen = 1'b0;
            for (b = 0; b < N; b = b + 1) begin
                lowest_oh[b] = v[b] & ~seen;
                seen         = seen | v[b];
            end
        end
    endfunction
    function [VC_ID_W-1:0] enc_oh;                        // number of the set bit of a one-hot (0 when zero)
        input [N-1:0] v;
        integer b;
        begin
            enc_oh = {VC_ID_W{1'b0}};
            for (b = 0; b < N; b = b + 1)
                if (v[b]) enc_oh = enc_oh | b[VC_ID_W-1:0];
        end
    endfunction
    wire [N-1:0]       free_oh  = lowest_oh(is_free);     // N = 8 bits
    wire [VC_ID_W-1:0] free_slot = enc_oh(free_oh);
    wire               any_free  = |is_free;
    wire [VC_ID_W-1:0] clean_slot;
    wire               any_clean;
    // oldest clean slot = least recently inserted (LRU drop)
    l1d_age_matrix #(.N(N), .IDX_W(VC_ID_W)) u_age (
        .clk             (clk),
        .rst             (rst),
        .allocate_valid  (insert_valid),
        .allocate_index  (insert_slot),
        .candidate_mask  (is_clean),
        .older_than_flat (),
        .oldest_onehot   (),
        .oldest_index    (clean_slot),
        .any_candidate   (any_clean)
    );
    assign victim_slot_available   = any_free || any_clean;
    assign victim_slot_index = any_free ? free_slot : clean_slot;

    // ---------------- writeback selection ----------------
    // ---- writeback selection: a WBPEND line not sent yet has priority over a dirty VALID line ----
    wire [N-1:0] pend_oh  = lowest_oh(is_pend);           // N = 8 bits
    wire [N-1:0] dirty_oh = lowest_oh(is_dirty);          // N = 8 bits
    wire         any_pend  = |is_pend;
    wire         any_dirty = |is_dirty;

    reg                wb_act;                            // a line is being offered on the write channel
    reg [VC_ID_W-1:0]  wb_slot;                           // the slot of that line
    reg [N-1:0]        wb_oh;                             // TIMING OPT (V-2): the same slot as one-hot bits, N = 8 bits
    // start a new writeback: a WBPEND line not sent yet, or (under pressure /
    // while draining) the first VALID dirty line
    // start a new writeback when none is active and: a WBPEND line is waiting, or (no free slot left, or draining) a dirty VALID line exists
    wire pressure  = !any_free || drain_enable;
    wire wb_start  = !wb_act && (any_pend || (pressure && any_dirty));
    wire [N-1:0]       wb_pick_oh = any_pend ? pend_oh : dirty_oh;   // N = 8 bits
    wire [VC_ID_W-1:0] wb_pick    = enc_oh(wb_pick_oh);
    // TIMING OPT (V-7): "a write-back starts on slot v in this cycle" (= wb_start && wb_pick_oh[v]) written per slot as one
    // sum of products, without the one-hot mux and the AND with wb_start: the lowest pending slot, or (no pending slot, under pressure)
    // the lowest dirty VALID slot. Equal to the old term in every cycle (any_pend = 1: wb_start = !wb_act and the pick is the pending one;
    // any_pend = 0: wb_start = !wb_act && pressure && any_dirty, and a dirty pick implies any_dirty).
    reg  [N-1:0]       wb_set;                            // N = 8 bits
    reg                pend_below, dirty_below;           // a lower slot is pending / dirty
    integer            v;
    always @* begin
        pend_below = 1'b0;  dirty_below = 1'b0;
        for (v = 0; v < N; v = v + 1) begin
            wb_set[v]   = !wb_act && ((is_pend[v] && !pend_below) || (!any_pend && pressure && is_dirty[v] && !dirty_below));
            pend_below  = pend_below  | is_pend[v];
            dirty_below = dirty_below | is_dirty[v];
        end
    end
    // TIMING OPT (V-2): the write-back line and data by AND-OR with wb_oh (a register next to wb_slot that always holds the same slot)
    reg  [LINE_ADDR_W-1:0] wb_la;                         // LINE_ADDR_W = 58 bits
    reg  [LINE_W-1:0]      wb_data;                       // LINE_W = 512 bits
    integer w;
    always @* begin
        wb_la = {LINE_ADDR_W{1'b0}};  wb_data = {LINE_W{1'b0}};
        for (w = 0; w < N; w = w + 1) begin
            wb_la   = wb_la   | ({LINE_ADDR_W{wb_oh[w]}} & la[w]);
            wb_data = wb_data | ({LINE_W{wb_oh[w]}}      & dmem[w]);
        end
    end

    assign writeback_req_valid = wb_act;
    assign writeback_req_line_addr  = wb_la;
    assign writeback_req_slot_id   = wb_slot;
    assign writeback_req_data  = wb_data;

    // ---------------- state update ----------------
    // ---- the state update (clocked). Later statements override earlier ones for the same slot, e.g. an insert beats the drain. ----
    // ---- the slot state and line address after this clock edge (the same statements and order as the clocked block below), for V-5 ----
    // TIMING OPT (V-7): st_n is now also the D input of st (one assignment per slot in the clocked block below instead of seven
    // prioritised writes), and it is built so that the late write-back start (wb_set: all slot states -> any pending / dirty / free ->
    // lowest slot) meets only the last AND-OR. The old order of the statements was: B response, drain, write-back start, swap, snoop
    // invalidate, release, insert, the later one winning. The last four come from the inputs only, so they are combined first (st_ovr / ovr);
    // the write-back start wins over the first two (st_base) and loses to the last four. Same next state in every case.
    // TIMING OPT (VC-D): the look-ahead match uses (st_n != FREE) = wbe | (st_o != FREE) (the write-back start only makes a slot
    // WBPEND, never FREE), written so that the late wb_set meets only the last AND-OR: match_n = (m & st_o != FREE) | (m & !ovr & wb_set).
    // TIMING OPT (VC-E): iss ("the write was handed to the write channel") written once per slot from iss_n. The old writes were:
    // hand-over sets it, a write-back start clears it (the two never in the same cycle: a start needs !wb_act), an insert clears it (wins).
    // So iss_n = (insert ? 0 : hand-over | iss) & !wb_set, with the late wb_set in the last AND. Same values in every cycle.
    reg  [2:0]             st_n [0:N-1];                  // 3 bits per slot
    reg  [N-1:0]           match_n;                       // N = 8 bits
    reg  [N-1:0]           iss_n;                         // N = 8 bits
    reg  [2:0]             st_base, st_ovr, st_o;         // 3 bits each
    reg                    ovr, wbe, h_swp, h_snp, h_rel, h_ins, m_ln, h_hand;
    wire                   eq_ins = (insert_line_addr == lookup_line_addr_next);
    integer sn;
    always @* begin
        for (sn = 0; sn < N; sn = sn + 1) begin
            // hold, B response, drain: flops and inputs
            st_base = st[sn];
            if (writeback_done_valid && (writeback_done_slot_id == sn))     st_base = VC_FREE;
            if (drain_enable && (st[sn] == VC_VALID) && !dty[sn])           st_base = VC_FREE;
            // swap, snoop invalidate, release, insert: inputs only (the last one that hits this slot wins)
            h_swp = swap_start_valid && (swap_start_slot == sn);
            h_snp = snoop_hit_valid && snoop_invalidate && (snoop_hit_slot == sn);
            h_rel = release_valid && (release_slot == sn);
            h_ins = insert_valid && (insert_slot == sn);
            ovr    = h_swp || h_snp || h_rel || h_ins;
            st_ovr = h_ins ? (insert_as_writeback_pending ? VC_WBPEND : VC_VALID) : ((h_rel || h_snp) ? VC_FREE : VC_MOVING);
            st_o   = ovr ? st_ovr : st_base;
            // the late write-back start, in the last AND-OR
            wbe      = wb_set[sn] && !ovr;
            st_n[sn] = ({3{wbe}} & VC_WBPEND) | ({3{!wbe}} & st_o);
            // VC-F: the look-ahead address match only (the slot's line after this edge equals lookup_line_addr_next)
            m_ln        = h_ins ? eq_ins : (la[sn] == lookup_line_addr_next);
            match_n[sn] = m_ln;
            // VC-E: iss after this edge, the late wb_set in the last AND
            h_hand    = wb_act && writeback_req_ready && (wb_slot == sn);
            iss_n[sn] = (h_ins ? 1'b0 : (h_hand || iss[sn])) && !wb_set[sn];
        end
    end

    integer s;
    always @(posedge clk) begin
        if (rst) begin
            lk_addr_q <= {N{1'b0}};
            for (s = 0; s < N; s = s + 1) begin
                st[s]  <= VC_FREE;
                dty[s] <= 1'b0;
                shr[s] <= 1'b0;
                iss[s] <= 1'b0;
            end
            wb_act  <= 1'b0;
            wb_slot <= {VC_ID_W{1'b0}};
            wb_oh   <= {{(N-1){1'b0}}, 1'b1};
            slot_freed_pulses   <= {N{1'b0}};
        end else begin
            slot_freed_pulses <= {N{1'b0}};
            lk_addr_q <= match_n;                          // VC-F: address part only
            // TIMING OPT (V-7): the slot states from st_n (B response, drain, write-back start, swap, snoop invalidate, release, insert)
            for (s = 0; s < N; s = s + 1) begin
                st[s]  <= st_n[s];
                iss[s] <= iss_n[s];                        // VC-E: hand-over sets it, a start or an insert clears it
            end
            // write response: the line is in memory, the slot is free (state: st_n)
            if (writeback_done_valid)
                slot_freed_pulses[writeback_done_slot_id] <= 1'b1;
            // writeback engine (state WBPEND and iss: st_n / iss_n)
            if (wb_act && writeback_req_ready)
                wb_act <= 1'b0;
            else if (wb_start)
                wb_act <= 1'b1;
            // TIMING OPT (VC-A): the slot of the next write-back loads in every cycle without an active write-back (it is read only
            // while wb_act: hand-over, and the write-back pins, which l1d_bank.v uses only with writeback_req_valid). At a start it takes the
            // same slot as before; the write-back address / slot / data pins differ from the old code only while writeback_req_valid is 0.
            if (!wb_act) begin
                wb_slot <= wb_pick;
                wb_oh   <= wb_pick_oh;
            end
            // snoop read on a VALID slot: shared and clean (an invalidating snoop frees the slot: st_n)
            if (snoop_hit_valid && !snoop_invalidate) begin
                shr[snoop_hit_slot] <= 1'b1;
                dty[snoop_hit_slot] <= 1'b0;
            end
            // insert a victim (its state: st_n, where the insert beats the drain and the others for the same slot)
            if (insert_valid) begin
                la[insert_slot]   <= insert_line_addr;
                dty[insert_slot]  <= insert_dirty;
                shr[insert_slot]  <= insert_shared;
                dmem[insert_slot] <= insert_line_data;     // (iss cleared: iss_n)
            end
        end
    end

    // empty: every slot FREE
    // all_slots_free: every slot is FREE (used by flush / clean to know when the victim cache is empty)
    assign all_slots_free = ~|in_use;

// ---- simulation-only trace: inserts, swaps, writebacks, B responses, protocol checks and STUCK reports ----
`ifdef L1D_DEBUG
    // TIMING OPT (V-5): the look-ahead is exact only if the bank looks up next cycle the line it gave as lookup_line_addr_next
    reg [LINE_ADDR_W-1:0] dbg_next_q;
    reg                   dbg_next_v;
    always @(posedge clk) begin
        dbg_next_q <= lookup_line_addr_next;
        dbg_next_v <= !rst;
        if (!rst && dbg_next_v && (lookup_line_addr !== dbg_next_q))
            $display("[%0t] L1D VC %m ERROR lookup_line_addr %h is not last cycle's lookup_line_addr_next %h (V-5 look-ahead broken)",
                     $time, lookup_line_addr, dbg_next_q);
    end
    // ======================================================================
    // Debug trace (simulation only): inserts, swaps, writebacks, B responses,
    // protocol checks and STUCK reports.
    // ======================================================================
    function [8*7-1:0] dbg_vname;
        input [2:0] s;
        begin
            case (s)
                VC_FREE:   dbg_vname = "FREE";
                VC_VALID:  dbg_vname = "VALID";
                VC_MOVING: dbg_vname = "MOVING";
                VC_WBPEND: dbg_vname = "WBPEND";
                default:   dbg_vname = "?";
            endcase
        end
    endfunction

    integer dbg_age [0:N-1];
    integer dbg_wbw, dbg_k;
    initial begin
        dbg_wbw = 0;
        for (dbg_k = 0; dbg_k < N; dbg_k = dbg_k + 1) dbg_age[dbg_k] = 0;
    end

    always @(posedge clk) begin
        if (!rst) begin
            if (insert_valid)
                $display("[%0t] L1D VC   %m insert slot %0d line=%h dirty=%b as %s (old state %0s)",
                         $time, insert_slot, {insert_line_addr, {OFFSET_W{1'b0}}}, insert_dirty,
                         insert_as_writeback_pending ? "WBPEND" : "VALID", dbg_vname(st[insert_slot]));
            if (swap_start_valid)
                $display("[%0t] L1D VC   %m swap start slot %0d line=%h -> MOVING",
                         $time, swap_start_slot, {la[swap_start_slot], {OFFSET_W{1'b0}}});
            if (release_valid)
                $display("[%0t] L1D VC   %m slot %0d released (swap installed into an empty way)", $time, release_slot);
            if (snoop_hit_valid)
                $display("[%0t] L1D VC   %m snoop %s slot %0d line=%h (was %0s dirty=%b)", $time,
                         snoop_invalidate ? "invalidates" : "reads", snoop_hit_slot, {la[snoop_hit_slot], {OFFSET_W{1'b0}}},
                         dbg_vname(st[snoop_hit_slot]), dty[snoop_hit_slot]);
            if (snoop_hit_valid && st[snoop_hit_slot] != VC_VALID)
                $display("[%0t] L1D VC   %m ERROR snoop operation on slot %0d which is not VALID", $time, snoop_hit_slot);
            if (wb_start && !(wb_act && writeback_req_ready))
                $display("[%0t] L1D VC   %m writeback start slot %0d line=%h (%s)",
                         $time, wb_pick, {la[wb_pick], {OFFSET_W{1'b0}}},
                         any_pend ? "WBPEND line" : (drain_enable ? "drain" : "no free slot"));
            if (wb_act && writeback_req_ready)
                $display("[%0t] L1D VC   %m writeback slot %0d handed to the AXI master", $time, wb_slot);
            if (writeback_done_valid) begin
                if (st[writeback_done_slot_id] != VC_WBPEND)
                    $display("[%0t] L1D VC   %m ERROR B for slot %0d, which is %0s, not WBPEND (wrong BID from memory?)",
                             $time, writeback_done_slot_id, dbg_vname(st[writeback_done_slot_id]));
                else
                    $display("[%0t] L1D VC   %m B slot %0d -> FREE", $time, writeback_done_slot_id);
            end
            // writeback offered but not taken
            if (wb_act && !writeback_req_ready) begin
                dbg_wbw = dbg_wbw + 1;
                if (dbg_wbw % `L1D_DBG_WD == 0)
                    $display("[%0t] L1D VC   %m STUCK writeback slot %0d offered for %0d cycles, AXI write channel busy",
                             $time, wb_slot, dbg_wbw);
            end else dbg_wbw = 0;
            // slots waiting for their B response
            for (dbg_k = 0; dbg_k < N; dbg_k = dbg_k + 1) begin
                if (st[dbg_k] == VC_WBPEND || st[dbg_k] == VC_MOVING) begin
                    dbg_age[dbg_k] = dbg_age[dbg_k] + 1;
                    if (dbg_age[dbg_k] % `L1D_DBG_WD == 0)
                        $display("[%0t] L1D VC   %m STUCK slot %0d in %0s for %0d cycles line=%h sent=%b (WBPEND: waiting for B; MOVING: waiting for its swap install)",
                                 $time, dbg_k, dbg_vname(st[dbg_k]), dbg_age[dbg_k],
                                 {la[dbg_k], {OFFSET_W{1'b0}}}, iss[dbg_k]);
                end else begin
                    dbg_age[dbg_k] = 0;
                end
            end
        end
    end
`endif

endmodule

`default_nettype wire
