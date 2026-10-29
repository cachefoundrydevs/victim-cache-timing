// ============================================================================
// l1d_cam.v  -  content-addressable match ("is my key stored anywhere?")
// ============================================================================
// IN SIMPLE WORDS
//   N lockers each hold a key (here: the line address of a cache line). You hand the CAM one
//   search key and in the SAME cycle it tells you which lockers hold exactly that key
//   (match_onehot, one bit per locker). A locker that is not in use (stored_valid = 0) never matches.
//       match_onehot[i] = stored_valid[i] && (stored_keys[i] == search_key)
//   An ordinary memory is asked "what is at address 5?"; a CAM is asked "where is the key 0x1234?".
//
// WHERE IT IS USED (8 copies: 4 banks x 2)
//   - l1d_mshr          "is this line already being fetched?"  (stored keys = the line of every busy MSHR entry)
//   - l1d_victim_cache  "is this line in the victim cache?"     (stored keys = the line of every slot in use)
//   Both feed l1d_pri_enc to turn the one-hot match into an entry number.
//
// PORTS (new name, old name, meaning)
//   stored_keys                          (was keys)                     the N stored keys laid end to end
//   stored_valid                         (was valid)                    which stored keys are in use
//   search_key                           (was key)                      the key looked for
//   match_onehot                         (was match)                    bit i = 1 when stored key i is valid and equals search_key
//
// COST
//   N comparators of KEY_W (= 58) bits per CAM, evaluated in Stage 2 together with the decision logic that
//   uses the result - one of the longest paths of the bank.
//
// VERILOG WORDS USED IN THIS FILE
//   stored_keys[g*KEY_W +: KEY_W]   "the KEY_W bits starting at bit g*KEY_W" = key number g of the wide bus
//   genvar + generate for           builds one comparator per stored key when the design is compiled
//   ==                              equality compare (true when every bit is equal)
// ============================================================================

`default_nettype none

module l1d_cam #(
    parameter N     = 8,
    parameter KEY_W = 16
) (
    input  wire [N*KEY_W-1:0] stored_keys,                // the N stored keys laid end to end
    input  wire [N-1:0]       stored_valid,               // which stored keys are in use
    input  wire [KEY_W-1:0]   search_key,                 // the key looked for
    output wire [N-1:0]       match_onehot                // bit i = 1 when stored key i is valid and equals search_key
);

    // one comparator per stored key; label g_cmp names the generated copies (g_cmp[0], g_cmp[1], ...)
    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : g_cmp
            assign match_onehot[g] = stored_valid[g] && (stored_keys[g*KEY_W +: KEY_W] == search_key);
        end
    endgenerate

endmodule

`default_nettype wire
