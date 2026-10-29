// ============================================================================
// l1d_age_matrix.v  -  who arrived first?  (remembers the allocation order of N entries)
// ============================================================================
// IN SIMPLE WORDS
//   N places (seats, slots) get filled and freed over time. This block remembers, for every
//   pair of places (i, j), whether i was allocated BEFORE j. From that it can name the OLDEST
//   one among any chosen group (the candidates) in the same cycle.
//
//   older[i][j] = 1   means   entry i was allocated before entry j     (i is older than j)
//
//   When entry k is allocated (allocate_valid = 1, allocate_index = k):
//       row k    is cleared  -> k is older than nobody (k is now the youngest)
//       column k is set      -> everybody else is older than k
//   A freed entry needs no action: when it is allocated again it is simply the youngest again.
//
//   Worked example, N = 4. Entries 2, 0 and 3 are allocated in this order:
//        alloc 2:  column 2 set for rows 0,1,3     ("0,1,3 are older than 2" - only entries in use matter)
//        alloc 0:  row 0 cleared, column 0 set for rows 1,2,3     -> older[2][0] = 1: 2 is older than 0
//        alloc 3:  row 3 cleared, column 3 set for rows 0,1,2     -> 0 and 2 are both older than 3
//        Oldest of {0,2,3} = 2 (nobody in that group is older than 2).   Oldest of {0,3} = 0.
//   (Only the entries that are in use matter; the `candidate_mask` selects them.)
//
// WHERE IT IS USED (3 users in the original design)
//   - l1d_lsu_req_buf  oldest READY request that the inflight tracker does not block
//   - l1d_snoop_buf    oldest snoop that may go
//   - l1d_victim_cache which clean slot to drop first. NOTE: this "LRU" is really insertion order,
//                      because the age is written only when a line is inserted, not when it is hit.
//   The matrix itself (older_than_flat) is also read by l1d_inflight_tracker.
//
// PORTS (new name, old name, meaning)
//   allocate_valid                       (was alloc)                    1 = entry allocate_index is allocated (becomes the youngest) this cycle
//   allocate_index                       (was alloc_idx)                number of the entry being allocated
//   candidate_mask                       (was mask)                     entries that take part in the "who is oldest" choice
//   older_than_flat                      (was older_flat)               bit [i*N+j] = 1 means entry i is older than entry j
//   oldest_onehot                        (was oldest)                   one-hot oldest candidate (zero when no candidate)
//   oldest_index                         (was oldest_idx)               number of the oldest candidate
//   any_candidate                        (was any)                      1 when at least one candidate exists
//
// HOW IT WORKS
//   - `older` is the N x N flip-flop matrix, updated at the clock edge on allocation.
//   - oldest_onehot[a] is combinational: candidate a is the oldest if NO other candidate b is older than a.
//   - l1d_pri_enc turns that one-hot into a number (oldest_index) and gives any_candidate.
//   The candidate_mask must contain only entries that are filled; this is not checked.
//
// VERILOG WORDS USED IN THIS FILE
//   reg [N-1:0] older [0:N-1]   an array of N rows, each row N bits: older[i][j] is bit j of row i
//   older_than_flat[g*N +: N]   "the N bits starting at bit g*N": row g copied into one wide bus
//   genvar + generate for       repeats a line of hardware for g = 0 .. N-1 when the design is built
// ============================================================================

`default_nettype none

// TIMING OPT (Tier 1): two optional features, both OFF by default so that the
// other user (l1d_victim_cache) is unchanged:
//   ONEHOT_ALLOC = 1  the entry being allocated is given as a ONE-HOT vector allocate_onehot (the caller picks the free entry as one-hot
//                     bits), not as a number: no decode of a number in the matrix update. allocate_index is then unused.
//   ONEHOT_ENC   = 1  oldest_index is an OR-encode of oldest_onehot instead of the priority chain of l1d_pri_enc. Exact because oldest_onehot is
//                     one-hot or zero: the matrix is a strict order among the allocated entries and the candidates are allocated entries.
//                     A simulation check prints an ERROR if oldest_onehot is ever not one-hot (then keep ONEHOT_ENC = 0).
module l1d_age_matrix #(
    parameter N     = 8,
    parameter IDX_W = (N > 1) ? $clog2(N) : 1,
    parameter ONEHOT_ALLOC = 0,
    parameter ONEHOT_ENC   = 0
) (
    input  wire             clk,                          // clock: all registers change on its rising edge
    input  wire             rst,                          // synchronous reset, active high (control state goes to its idle value)
    input  wire             allocate_valid,               // 1 = entry allocate_index is allocated (becomes the youngest) this cycle
    input  wire [IDX_W-1:0] allocate_index,               // number of the entry being allocated
    input  wire [N-1:0]     allocate_onehot,              // the same entry as one-hot bits (used only with ONEHOT_ALLOC = 1)
    input  wire [N-1:0]     candidate_mask,           // candidates for "oldest"
    output wire [N*N-1:0]   older_than_flat,              // bit [i*N+j] = 1 means entry i is older than entry j
    output reg  [N-1:0]     oldest_onehot,                // one-hot oldest candidate (zero when no candidate)
    output wire [IDX_W-1:0] oldest_index,                 // number of the oldest candidate
    output wire             any_candidate                 // 1 when at least one candidate exists
);

    // the matrix: older[i][j] = 1 means entry i was allocated before entry j
    reg [N-1:0] older [0:N-1];              // older[i][j]
    integer i;

    // ---- update on allocation (clocked) ----
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < N; i = i + 1)
                older[i] <= {N{1'b0}};
        end else if (allocate_valid) begin
            for (i = 0; i < N; i = i + 1) begin
                if (ONEHOT_ALLOC != 0) begin
                    if (allocate_onehot[i]) older[i] <= {N{1'b0}};        // row k: younger than all
                    else                    older[i] <= older[i] | allocate_onehot;   // column k: all older than k
                end else begin
                    if (i == allocate_index) older[i] <= {N{1'b0}};       // row k: younger than all
                    else                older[i][allocate_index] <= 1'b1; // column k: all older than k
                end
            end
        end
    end

    // ---- copy the matrix into the one-bit-per-pair output bus (row g at [g*N +: N]) ----
    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : g_flat
            assign older_than_flat[g*N +: N] = older[g];
        end
    endgenerate

    // ---- choose the oldest candidate (combinational) ----
    // candidate a is oldest if no other candidate b is older than a
    integer a;
    integer b;
    always @* begin
        for (a = 0; a < N; a = a + 1) begin
            oldest_onehot[a] = candidate_mask[a];
            for (b = 0; b < N; b = b + 1)
                if (b != a && candidate_mask[b] && older[b][a])
                    oldest_onehot[a] = 1'b0;
        end
    end

    // number of the oldest candidate, and "is there any candidate"
    generate
        if (ONEHOT_ENC != 0) begin : g_oh_enc
            // OR-encode: bit k of the number = OR of the one-hot bits whose number has bit k set (no priority chain)
            reg [IDX_W-1:0] idx_or;
            integer e;
            always @* begin
                idx_or = {IDX_W{1'b0}};
                for (e = 0; e < N; e = e + 1)
                    if (oldest_onehot[e]) idx_or = idx_or | e[IDX_W-1:0];
            end
            assign oldest_index  = idx_or;
            assign any_candidate = |oldest_onehot;
        end else begin : g_pri_enc
            l1d_pri_enc #(.N(N), .IDX_W(IDX_W)) u_enc (
                .request_bits     (oldest_onehot),
                .lowest_set_index (oldest_index),
                .any_set          (any_candidate)
            );
        end
    endgenerate

    // synopsys translate_off
    // simulation check for ONEHOT_ENC: the oldest candidate must be one-hot or zero
    always @(posedge clk) begin
        if (ONEHOT_ENC != 0 && !rst && ((oldest_onehot & (oldest_onehot - 1'b1)) != {N{1'b0}}) && (oldest_onehot !== {N{1'bx}}))
            $display("[%0t] L1D AGE %m ERROR oldest_onehot is not one-hot (%b): keep ONEHOT_ENC = 0 for this user", $time, oldest_onehot);
    end
    // synopsys translate_on

endmodule

`default_nettype wire
