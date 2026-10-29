// Formal wrapper for l1d_victim_cache: free inputs, except the lookup address follows the bank's pipeline: the line looked up in a cycle is
// the lookup_line_addr_next of the previous cycle (bank: s2_line <= s1_line at every edge). Every output is compared in every cycle;
// the write-back address / slot / data only while writeback_req_valid (VC-A: the bank reads them only then).
`default_nettype none
`include "l1d_defines.vh"
module fv_wrap #(`L1D_PARAMS) (
    input  wire clk, input wire rst,
    input  wire [57:0] lookup_next,
    input  wire insert_valid, input wire [2:0] insert_slot, input wire [57:0] insert_line_addr, input wire [511:0] insert_line_data,
    input  wire insert_dirty, input wire insert_shared, input wire insert_as_writeback_pending,
    input  wire swap_start_valid, input wire [2:0] swap_start_slot, input wire release_valid, input wire [2:0] release_slot,
    input  wire snoop_hit_valid, input wire [2:0] snoop_hit_slot, input wire snoop_invalidate, input wire drain_enable,
    input  wire writeback_req_ready, input wire writeback_done_valid, input wire [2:0] writeback_done_slot_id,
    output wire lookup_hit, output wire [2:0] lookup_slot, output wire [2:0] lookup_slot_state, output wire [511:0] lookup_line_data,
    output wire lookup_dirty, output wire lookup_shared, output wire victim_slot_available, output wire [2:0] victim_slot_index,
    output wire writeback_req_valid, output wire [57:0] writeback_req_line_addr, output wire [2:0] writeback_req_slot_id,
    output wire [511:0] writeback_req_data, output wire all_slots_free, output wire [7:0] slot_freed_pulses
);
    reg [57:0] line_q;                                     // the bank's s2_line: last cycle's s1_line
    always @(posedge clk) line_q <= lookup_next;
    wire [57:0] wb_line;  wire [2:0] wb_slot;  wire [511:0] wb_data;
    assign writeback_req_line_addr = wb_line & {58{writeback_req_valid}};
    assign writeback_req_slot_id   = wb_slot & {3{writeback_req_valid}};
    assign writeback_req_data      = wb_data & {512{writeback_req_valid}};
    l1d_victim_cache #(`L1D_PARAMS_PASS) u (
        .clk(clk), .rst(rst),
`ifdef OPT
        .lookup_line_addr_next(lookup_next),
`endif
        .lookup_line_addr(line_q), .lookup_hit(lookup_hit), .lookup_slot(lookup_slot), .lookup_slot_state(lookup_slot_state),
        .lookup_line_data(lookup_line_data), .lookup_dirty(lookup_dirty), .lookup_shared(lookup_shared),
        .victim_slot_available(victim_slot_available), .victim_slot_index(victim_slot_index),
        .insert_valid(insert_valid), .insert_slot(insert_slot), .insert_line_addr(insert_line_addr), .insert_line_data(insert_line_data),
        .insert_dirty(insert_dirty), .insert_shared(insert_shared), .insert_as_writeback_pending(insert_as_writeback_pending),
        .swap_start_valid(swap_start_valid), .swap_start_slot(swap_start_slot), .release_valid(release_valid), .release_slot(release_slot),
        .snoop_hit_valid(snoop_hit_valid), .snoop_hit_slot(snoop_hit_slot), .snoop_invalidate(snoop_invalidate), .drain_enable(drain_enable),
        .writeback_req_valid(writeback_req_valid), .writeback_req_ready(writeback_req_ready), .writeback_req_line_addr(wb_line),
        .writeback_req_slot_id(wb_slot), .writeback_req_data(wb_data),
        .writeback_done_valid(writeback_done_valid), .writeback_done_slot_id(writeback_done_slot_id),
        .all_slots_free(all_slots_free), .slot_freed_pulses(slot_freed_pulses));
endmodule
`default_nettype wire
