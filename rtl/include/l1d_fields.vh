// ============================================================================
// l1d_fields.vh  -  widths and bit positions DERIVED from the settings
// ============================================================================
// IN SIMPLE WORDS
//   l1d_defines.vh holds the settings (SETS = 64, WAYS = 4 ...). This file turns them
//   into the numbers the modules really need: how many bits is a tag? where does the
//   set number sit inside an address? how wide is a request packet? Nothing here is
//   typed twice - change a setting and every width follows.
//
// HOW TO USE IT
//   Include it INSIDE a module body, once, after the parameter list:
//       module l1d_xxx #(`L1D_PARAMS) ( ... );
//           `include "l1d_encodings.vh"
//           `include "l1d_fields.vh"
//   It only declares localparams (named constants), so it creates no hardware.
//   It has no include guard on purpose: every module needs its own copy of the
//   constants (a guard would hide the file from every module after the first one).
//   The including module must declare the parameters of `L1D_PARAMS.
//   Constraints: NUM_BANKS, SETS, WAYS, LINE_BYTES, MSHR_ENTRIES and VC_SLOTS are
//   powers of two and at least 2.
//
// THE ADDRESS, WITH A WORKED EXAMPLE (defaults: 64-bit address, 64-byte line, 4 banks, 64 sets)
//
//        63                          14 13      8 7    6 5          0
//       +------------------------------+---------+------+------------+
//       |            tag               |   set   | bank |   offset   |      TAG_W = 50, INDEX_W = 6,
//       +------------------------------+---------+------+------------+      BANK_W = 2, OFFSET_W = 6
//
//   Address 0x8000_1A48:  offset = 0x08 (byte 8 of the line)   bank = 1   set = 26   tag = 0x20000
//   - offset  picks the byte inside the 64-byte line
//   - bank    picks one of the 4 banks (so neighbouring lines go to different banks)
//   - set     picks the row inside the bank's arrays (tag RAM, state flops, PLRU bits)
//   - tag     is stored in the tag RAM and compared to see whether the line is the right one
//   A "line address" is the address WITHOUT the offset: {tag, set, bank} = 58 bits.
//
// THE PACKETS (several fields packed into one bus; the first field named is the highest bit)
//   Request packet  REQ_W = 139 bits:  | seq | amo | rd_wr | cacheable | size | master_id | idx | addr | data |
//                                         1     1      1        1        2        2        3     64     64
//        amo / seq: 1/0 = LR (load-reserved, rd_wr = 0) or SC (store-conditional, rd_wr = 1)
//                   1/1 = AMO read (rd_wr = 0) or AMO write (rd_wr = 1)        0/x = plain load / store
//        idx = the CPU's ROB index; it travels with the request and comes back with the response
//   Response packet RESP_W = 72 bits:  | rd_wr | size | master_id | idx | data |
//   Snoop answer    SNPR_W = 572 bits: | present | dirty | line address | line data |
// ============================================================================
// BANK_W/OFFSET_W/INDEX_W are bit counts ($clog2(n) = the number of bits needed to count n things);
// TAG_W is what is left of the address. *_LSB is the number of the lowest bit of that field.
localparam OFFSET_W    = $clog2(LINE_BYTES);
localparam BANK_W      = $clog2(NUM_BANKS);
localparam INDEX_W     = $clog2(SETS);
localparam TAG_W       = ADDR_W - INDEX_W - BANK_W - OFFSET_W;
localparam OFFSET_LSB  = 0;
localparam BANK_LSB    = OFFSET_W;
localparam INDEX_LSB   = OFFSET_W + BANK_W;
localparam TAG_LSB     = OFFSET_W + BANK_W + INDEX_W;
localparam LINE_ADDR_W = ADDR_W - OFFSET_W;           // address of a line (tag, index, bank)
// The same fields inside a line address (line = addr[ADDR_W-1:OFFSET_W]):
// Where the same fields sit inside a LINE address (the address without its 6 offset bits): the bank
// is now the lowest field, because the offset is gone.
localparam LA_BANK_LSB = 0;
localparam LA_SET_LSB  = BANK_W;
localparam LA_TAG_LSB  = BANK_W + INDEX_W;

// Line and data
// LINE_W = bits in a line (512). WDATA_BYTES = bytes of the CPU store data (8). GRANULES = how many such
// words fit in one line (8). WAY_W = bits needed to number the ways.
localparam LINE_W      = LINE_BYTES * 8;
localparam WAY_W       = $clog2(WAYS);
localparam WDATA_BYTES = WRITE_DATA_WIDTH / 8;
localparam GRANULES    = LINE_BYTES / WDATA_BYTES;    // 64-bit words per line
localparam GRAN_W      = $clog2(GRANULES);
localparam GRAN_LSB    = $clog2(WDATA_BYTES);          // address bit where the word number starts

// Request packet (input queue -> bank selector -> bank), LSB first:
//   | seq | amo | rd_wr | cacheable | size | master_id | idx | addr | data |
//   amo / seq (v2): 1/0 = LR (read) or SC (write); 1/1 = AMO read or AMO write.
// The fields are packed from the lowest bit up: data first, then addr, idx, ... The address of a request
// packet p is p[REQ_ADDR_LSB +: ADDR_W]  ("ADDR_W bits starting at bit REQ_ADDR_LSB").
localparam REQ_DATA_LSB  = 0;
localparam REQ_ADDR_LSB  = REQ_DATA_LSB + WRITE_DATA_WIDTH;
localparam REQ_IDX_LSB   = REQ_ADDR_LSB + ADDR_W;
localparam REQ_MID_LSB   = REQ_IDX_LSB  + IDX_BITS;
localparam REQ_SIZE_LSB  = REQ_MID_LSB  + MASTER_ID_BITS;
localparam REQ_CACHE_BIT = REQ_SIZE_LSB + MEM_SIZE_BITS;
localparam REQ_RDWR_BIT  = REQ_CACHE_BIT + 1;
localparam REQ_AMO_BIT   = REQ_RDWR_BIT + 1;
localparam REQ_SEQ_BIT   = REQ_AMO_BIT + 1;
localparam REQ_W         = REQ_SEQ_BIT + 1;

// Response packet (bank -> response merger -> final_r_*), LSB first:
//   | rd_wr | size | master_id | idx | data |
// Same idea for the response: p[RESP_IDX_LSB +: IDX_BITS] is the ROB index of the answered request.
localparam RESP_DATA_LSB = 0;
localparam RESP_IDX_LSB  = RESP_DATA_LSB + WRITE_DATA_WIDTH;
localparam RESP_MID_LSB  = RESP_IDX_LSB  + IDX_BITS;
localparam RESP_SIZE_LSB = RESP_MID_LSB  + MASTER_ID_BITS;
localparam RESP_RDWR_BIT = RESP_SIZE_LSB + MEM_SIZE_BITS;
localparam RESP_W        = RESP_RDWR_BIT + 1;

// Snoop response packet (bank -> l1d_snoop_ctrl -> snpr_*), LSB first:
//   | present | dirty | line address | line data |
localparam SNPR_DATA_LSB  = 0;
localparam SNPR_LINE_LSB  = SNPR_DATA_LSB + LINE_W;
localparam SNPR_DIRTY_BIT = SNPR_LINE_LSB + LINE_ADDR_W;
localparam SNPR_PRES_BIT  = SNPR_DIRTY_BIT + 1;
localparam SNPR_W         = SNPR_PRES_BIT + 1;
localparam SNPR_CNT_W     = $clog2(SNP_RESP_DEPTH + 1);     // snoop response FIFO free count
localparam SNP_ID_W       = (SNP_BUF_DEPTH > 2) ? $clog2(SNP_BUF_DEPTH) : 1;  // snoop buffer entry number

// MSHR, victim cache and AXI ids
// Widths of the numbers that name an MSHR entry, a victim-cache slot, a non-cacheable entry.
// AXI id = { non-cacheable flag, bank number, sub id }. The sub id is the MSHR entry (cacheable read), the
// victim-cache slot (writeback) or 0 (non-cacheable). The memory returns the id with R / B, which is how a
// data beat finds its way back to the right bank and entry.
localparam MSHR_ID_W   = $clog2(MSHR_ENTRIES);
localparam VC_ID_W     = $clog2(VC_SLOTS);
localparam NC_ID_W     = (MSHR_NC_ENTRIES > 1) ? $clog2(MSHR_NC_ENTRIES) : 1;
localparam AXI_SUBID_W = (MSHR_ID_W >= VC_ID_W)
                         ? ((MSHR_ID_W >= NC_ID_W) ? MSHR_ID_W : NC_ID_W)
                         : ((VC_ID_W   >= NC_ID_W) ? VC_ID_W   : NC_ID_W);
// AXI id = { nc, bank, sub-id }; l1d_top's AXI_ID_W parameter must be at least this.
localparam AXI_ID_MIN_W = 1 + BANK_W + AXI_SUBID_W;

// Per-bank bookkeeping
// SEAT_W = bits to number the seats; RCNT_W = bits of the response-FIFO free count; WID_W = width of "the thing
// a waiting seat waits on" (an MSHR entry number or a victim-cache slot number, whichever is wider).
localparam SEAT_W      = (LSU_BUF_DEPTH > 1) ? $clog2(LSU_BUF_DEPTH) : 1;  // LSU Request Buffer seat number
localparam RCNT_W      = $clog2(RESP_FIFO_DEPTH + 1);                       // response FIFO free count
localparam WID_W       = (MSHR_ID_W >= VC_ID_W) ? MSHR_ID_W : VC_ID_W;     // id a waiting seat waits on
localparam SET_WAY_W   = INDEX_W + WAY_W;                                   // data array address {set, way}

// AXI bursts
// Burst arithmetic: a 64-byte line over a 128-bit (16-byte) bus = 4 beats; ARLEN/AWLEN = beats - 1 = 3.
localparam AXI_STRB_W  = AXI_DATA_W / 8;
localparam AXI_BEATS   = LINE_W / AXI_DATA_W;          // beats per line (4 at 128 bits)
localparam AXI_LEN     = AXI_BEATS - 1;                // ARLEN / AWLEN for a line
localparam AXI_SIZE    = $clog2(AXI_STRB_W);           // ARSIZE / AWSIZE for a full beat
localparam BEAT_W      = (AXI_BEATS > 1) ? $clog2(AXI_BEATS) : 1;
localparam AXI_OFF_W   = $clog2(AXI_STRB_W);           // byte lane bits inside one AXI beat
