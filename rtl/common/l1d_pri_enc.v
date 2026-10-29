// ============================================================================
// l1d_pri_enc.v  -  priority encoder: "which is the first one that is set?"
// ============================================================================
// IN SIMPLE WORDS
//   You give it a row of N request bits. It tells you the NUMBER of the lowest bit
//   that is 1 (lowest_set_index) and whether any bit is set at all (any_set).
//   Example, N = 8:   request_bits = 8'b0101_1000  ->  lowest_set_index = 3, any_set = 1
//                     request_bits = 8'b0000_0000  ->  lowest_set_index = 0, any_set = 0
//   Always check any_set: index 0 is also what you get when nothing is set.
//
// WHERE IT IS USED (52 copies in the original design)
//   - "first FREE place": free request-buffer seat (call it with request_bits = ~occupied),
//     free MSHR entry, free victim-cache slot, free snoop-buffer entry
//   - "which one matched": turns the one-hot match vector of a CAM or of the tag compare into a number
//     (hit way, MSHR entry that already has the line, victim slot that has the line)
//   - the oldest-candidate number of l1d_age_matrix
//
// PORTS (new name, old name, meaning)
//   request_bits                         (was req)                      one bit per candidate; a 1 means the candidate is asking
//   lowest_set_index                     (was idx)                      number of the lowest set bit (0 when no bit is set)
//   any_set                              (was any)                      1 when at least one request bit is set
//
// WHAT KIND OF LOGIC IS IT?
//   Pure combinational (no clock, no memory): the answer follows the inputs in the same cycle.
//   If several bits are set the LOWEST wins, so a multiple hit would be hidden; the callers
//   only ever give one-hot or "free" vectors.
//
// VERILOG WORDS USED IN THIS FILE
//   always @*          "recompute whenever any input changes" = combinational logic written like a program
//   for (...)          here the loop is NOT run in time: the tools unroll it into N copies of hardware
//   |request_bits      reduction OR: 1 if at least one bit is 1
//   i[IDX_W-1:0]       the low IDX_W bits of the integer i
//   output reg         an output assigned inside an always block must be declared "reg"; here it is
//                      still plain logic (no flip-flop), because the block has no clock
// ============================================================================

`default_nettype none

module l1d_pri_enc #(
    parameter N     = 4,
    parameter IDX_W = (N > 1) ? $clog2(N) : 1
) (
    input  wire [N-1:0]     request_bits,                 // one bit per candidate; a 1 means the candidate is asking
    output reg  [IDX_W-1:0] lowest_set_index,             // number of the lowest set bit (0 when no bit is set)
    output wire             any_set                       // 1 when at least one request bit is set
);

    // i is only a counter used to build the logic (the loop is unrolled by the synthesis tool).
    integer i;
    // Start with 0, then scan from the highest bit down to bit 0. A later (lower) hit overwrites an earlier
    // (higher) one, so the LOWEST set bit is the one that remains.
    always @* begin
        lowest_set_index = {IDX_W{1'b0}};
        // scan from the top so the lowest set bit is the one that remains
        for (i = N - 1; i >= 0; i = i - 1)
            if (request_bits[i]) lowest_set_index = i[IDX_W-1:0];
    end

    // any_set = at least one bit is set (reduction OR of all request bits)
    assign any_set = |request_bits;

endmodule

`default_nettype wire
