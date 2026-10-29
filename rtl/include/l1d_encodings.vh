// ============================================================================
// l1d_encodings.vh  -  named constants shared by all the original design modules
// ============================================================================
// IN SIMPLE WORDS
//   Hardware only sees numbers. This file gives the numbers names, so the code can
//   say  ST_M  instead of  2'd3  and  SEAT_WMSHR  instead of  3'd3. Every family of
//   constants below is one "code book": request direction, access size, line state
//   (MESI), seat state, victim-cache slot state, what Stage 2 decides, and so on.
//
// HOW TO USE IT
//   `include it INSIDE a module body (like l1d_fields.vh). It only declares
//   localparams, so it creates no hardware, and it has no include guard on purpose.
//
// NOTES
//   - what are WMSHR / WANY / WVC / WNC?          (seat states, then "what Stage 2 decides")
//   - what are VALID / MOVING / WBPEND?           (victim cache slot states)
//   - what is a "token"?                          (refill / flush-clean token, kind of operation)
// ============================================================================
// Request direction and access size: the same codes as the CPU pins cpu_request_is_write and cpu_request_size.
localparam OP_READ  = 1'b0;
localparam OP_WRITE = 1'b1;

// Access size (mem_size_cpu)
localparam [1:0] SZ_8  = 2'd0;
localparam [1:0] SZ_16 = 2'd1;
localparam [1:0] SZ_32 = 2'd2;
localparam [1:0] SZ_64 = 2'd3;

// Master id (master_id_from_cpu)
localparam [1:0] MID_LSU = 2'd0;
localparam [1:0] MID_MMU = 2'd1;

// Line state, full MESI (v2). CHI names: M = UD, E = UC, S = SC, I.
//   S is always clean: a snoop read takes the data of an M line and leaves S.
// The four MESI states of a cache line. Every line is in exactly one of them:
//   I  Invalid    the way holds no line
//   S  Shared     a clean copy; other caches may also have it (it cannot be written without an upgrade)
//   E  Exclusive  a clean copy that only this cache has (a store turns it into M with no bus traffic)
//   M  Modified   a dirty copy that only this cache has (memory is stale; it must be written back)
localparam [1:0] ST_I = 2'd0;
localparam [1:0] ST_S = 2'd1;
localparam [1:0] ST_E = 2'd2;
localparam [1:0] ST_M = 2'd3;

// Events for the state logic (l1d_mesi_next)
// Events: what happened to a line. l1d_mesi_next turns (event, current state) into the next state.
localparam [3:0] EV_NONE      = 4'd0;
localparam [3:0] EV_LOAD_HIT  = 4'd1;   // load hit: state unchanged
localparam [3:0] EV_WRITE_HIT = 4'd2;   // store, SC, AMO write hit: E -> M; S -> I + unique fetch
localparam [3:0] EV_UNIQ_HIT  = 4'd3;   // LR or AMO read hit: E/M unchanged; S -> I + unique fetch
localparam [3:0] EV_INSTALL   = 4'd4;   // refill / swap installs a line in the given state
localparam [3:0] EV_SNP_READ  = 4'd5;   // another core reads: M/E/S -> S (M hands its data over)
localparam [3:0] EV_SNP_INV   = 4'd6;   // another core writes: -> I (M hands its data over)
localparam [3:0] EV_CLEAN     = 4'd7;   // clean walk: M -> E (written back), E and S unchanged
localparam [3:0] EV_FLUSH     = 4'd8;   // flush walk: -> I

// SC result in the response data word (AMO study option A)
localparam SC_OK   = 1'b0;
localparam SC_FAIL = 1'b1;

// Inflight Tracker entry type
// Entry types of the original inflight tracker. Not used by the the original design logic: the LSU buffer
// seats are the tracker entries.
localparam [2:0] TT_LOAD   = 3'd0;
localparam [2:0] TT_STORE  = 3'd1;
localparam [2:0] TT_REFILL = 3'd2;   // refill or victim-cache swap token
localparam [2:0] TT_MAINT  = 3'd3;   // flush / clean walk token

// Victim cache slot state
// Victim cache slot states:
//   FREE      empty slot
//   VALID     holds a line that was evicted from the cache; a hit on it starts a swap back
//   MOVING    its line was copied into an MSHR entry for a swap back; the slot is reserved for the victim of
//             that install, and requests that need it wait (SEAT_WANY)
//   WBPEND    a dirty line being written to memory; loads are still answered from it; it is freed only by the
//             AXI B response, and store-class requests wait for it (SEAT_WVC)
localparam [2:0] VC_FREE     = 3'd0;
localparam [2:0] VC_VALID    = 3'd1;
localparam [2:0] VC_MOVING   = 3'd2;  // being swapped back through an MSHR
localparam [2:0] VC_WBPEND   = 3'd3;  // dirty, writeback sent, waiting for the AXI B response
localparam [2:0] VC_RESERVED = 3'd4;  // not used in v2 (a snoop answers from the slot in place)

// Kind of operation travelling down a bank pipeline (S1, S2 registers)
// Kind of operation travelling down the bank pipeline (S1, S2 registers). A "token" is a request that is not
// from the CPU but made by the cache itself: the MSHR asks Priority Select for a refill slot, l1d_maint asks
// for a flush/clean slot, and a snoop comes from the snoop buffer.
localparam [1:0] K_LSU    = 2'd0;   // load or store from the LSU (cacheable or not)
localparam [1:0] K_REFILL = 2'd1;   // refill / swap token from the MSHR: installs a line
localparam [1:0] K_MAINT  = 2'd2;   // flush / clean token from l1d_maint: one set and way
localparam [1:0] K_SNOOP  = 2'd3;   // snoop from the snoop buffer: one pass, never tracked

// LSU Request Buffer seat state
// LSU Request Buffer seat states. A seat is the place of one waiting request:
//   EMPTY   free
//   READY   waiting for Priority Select to grant it
//   INFL    granted, travelling in the pipeline (S1..S3). It still owns its seat!
//   WMSHR   Stage 2 found the line already being fetched: wait until THAT MSHR entry is freed (line installed),
//           then retry (the retry will hit)
//   WANY    all MSHR entries were busy (or a victim-cache slot was MOVING): wait until ANY entry is freed
//   WVC     a store-class request found its line in a victim slot with a pending writeback: wait for the B response
//   WNC     the non-cacheable queue was full: wait until a place is free
//   OWNED   handed to an MSHR / NC entry; that entry will answer the CPU, and the seat is freed then
localparam [2:0] SEAT_EMPTY  = 3'd0;  // free
localparam [2:0] SEAT_READY  = 3'd1;  // waiting for a grant
localparam [2:0] SEAT_INFL   = 3'd2;  // granted, in the pipeline
localparam [2:0] SEAT_WMSHR  = 3'd3;  // waiting for one MSHR entry to be freed (its line installed)
localparam [2:0] SEAT_WANY   = 3'd4;  // waiting for any MSHR entry to be freed (MSHR was full)
localparam [2:0] SEAT_WVC    = 3'd5;  // waiting for one victim-cache slot to be freed (writeback B)
localparam [2:0] SEAT_WNC    = 3'd6;  // waiting for a free non-cacheable entry
localparam [2:0] SEAT_OWNED  = 3'd7;  // handed to an MSHR / NC entry, which will answer it

// What Stage 2 decides for an LSU request that does not answer now
// What Stage 2 decides for an LSU request. Each code becomes the matching waiting seat state above
// (ACT_WMSHR -> SEAT_WMSHR, ..., ACT_OWNED -> SEAT_OWNED). The "wait" codes come with the number of the MSHR
// entry or victim slot waited for (lsu_s2_action_wait_id).
localparam [2:0] ACT_NONE    = 3'd0;  // answered (response goes to S3) - seat freed when it leaves S3
localparam [2:0] ACT_WMSHR   = 3'd1;
localparam [2:0] ACT_WANY    = 3'd2;
localparam [2:0] ACT_WVC     = 3'd3;
localparam [2:0] ACT_WNC     = 3'd4;
localparam [2:0] ACT_OWNED   = 3'd5;

// Snoop buffer head state (l1d_snoop_buf)
// Snoop buffer entry states (l1d_snoop_buf): the snoop twin of the seat states.
localparam [1:0] SH_READY = 2'd0;   // head waiting for a grant
localparam [1:0] SH_INFL  = 2'd1;   // head in the pipeline
localparam [1:0] SH_WMSHR = 2'd2;   // head waits for one MSHR entry (line being installed)
localparam [1:0] SH_WVC   = 2'd3;   // head waits for one victim-cache slot (writeback B)

// What Stage 2 decides for a snoop
// What Stage 2 decides for a snoop: answered (leave the buffer), or wait for an MSHR install / a victim writeback.
localparam [1:0] SACT_DONE  = 2'd0; // answered: pop the head
localparam [1:0] SACT_WMSHR = 2'd1;
localparam [1:0] SACT_WVC   = 2'd2;

// Maintenance operation
// Maintenance operation of the flush/clean walk (clean = write back dirty lines, flush = also invalidate).
localparam MAINT_CLEAN = 1'b0;
localparam MAINT_FLUSH = 1'b1;

// AXI4
// AXI4 constants: burst type, response codes, cache attributes, protection.
localparam [1:0] AXI_BURST_FIXED = 2'b00;
localparam [1:0] AXI_BURST_INCR  = 2'b01;
localparam [1:0] AXI_BURST_WRAP  = 2'b10;
localparam [1:0] AXI_RESP_OKAY   = 2'b00;
localparam [1:0] AXI_RESP_EXOKAY = 2'b01;
localparam [1:0] AXI_RESP_SLVERR = 2'b10;
localparam [1:0] AXI_RESP_DECERR = 2'b11;
localparam [3:0] AXI_CACHE_WB    = 4'b1111; // cacheable refills and writebacks: write-back, read/write allocate
localparam [3:0] AXI_CACHE_DEV   = 4'b0000; // non-cacheable accesses: device, non-bufferable
localparam [2:0] AXI_PROT_DATA   = 3'b000;  // unprivileged, secure, data
