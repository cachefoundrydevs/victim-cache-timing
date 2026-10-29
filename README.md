# Victim cache: timing optimisation in ASAP7

An 8-slot, fully associative **victim cache** of an L1 data cache (Verilog-2005), and a **timing-optimised version of it with the same
function and the same cycle behaviour at its pins**. Every push runs, for each version: a lockstep simulation and a formal equivalence check
against the original, and an ASAP7 (7 nm predictive PDK) timing estimate with OpenROAD-flow-scripts at 250 ps (4 GHz) and 200 ps (5 GHz).

## 1. What the module does

When the cache needs room for a new line it evicts a line (the "victim"). Instead of losing it, the victim goes into this small buffer. If
the line is needed again soon (a conflict miss), it is found here and swapped back, which is much faster than a trip to memory.

| Slot state | Meaning |
|---|---|
| FREE | empty |
| VALID | holds an evicted line (clean or dirty). A lookup hit on it can start a swap back into the cache. |
| MOVING | its line is being swapped back; the slot is reserved for the victim of that install (or released if there is none) |
| WBPEND | a dirty line being written to memory; still found by lookups; freed by the write response |

Operations: **lookup** (is a line here? which slot, its state, data, dirty / shared bits), **victim-slot query** (a FREE slot, else the oldest
clean VALID slot, by an age matrix), **insert**, **swap start**, **release**, **snoop** (invalidate, or read: the slot becomes shared and clean),
**drain** (drop clean lines, write back dirty ones). A **write-back engine** sends one line at a time on a write channel: a pending line
first, else (no free slot, or draining) the lowest dirty VALID slot; several lines may wait for their write responses.

## 2. Files

| Path | Content |
|---|---|
| `rtl/ref/` | the **original** victim cache and age matrix (the reference) |
| `rtl/opt/` | the **optimised** versions (`l1d_age_matrix.v` keeps the original behaviour with its default parameters) |
| `rtl/common/` | CAM and priority encoder used by both |
| `rtl/include/` | parameters, encodings and derived widths |
| `variants/<name>/` | other versions to compare (each folder replaces `rtl/opt` files of the same name); measured side by side |
| `tb/tb_victim_cache_equiv.v` | lockstep test: same random, protocol-correct inputs for the original and the new version, every output compared in every cycle |
| `formal/` | formal equivalence (Yosys `sat`, bounded): every input sequence of N cycles after reset |
| `flow/` | ASAP7 timing of the module (synthesis, STA, failing groups, optional gate sizing) |
| `scripts/run_all.sh` | all checks for one version and a summary table |
| `.github/workflows/victim_cache.yml` | one parallel job per version, then a comparison table |

## 3. The optimisations (all cycle-neutral)

Rule for every change: **the same value on every output pin in every cycle**, proved by the lockstep test and the formal check. One
documented exception (VC-A): the write-back address / slot / data pins may differ while `writeback_req_valid` is 0, because the user of the
module reads them only together with the valid bit; the tests compare them only then.

| ID | Change | Why it is faster | Why it is exact |
|---|---|---|---|
| V-1 | lookup: the lowest matching slot as one-hot bits (prefix chain); state, data, dirty and shared picked by AND-OR | no encoder followed by a binary-index mux on 512-bit data | the same slot as the encoder; slot 0 is shown when nothing matches, as the old mux did with index 0 |
| V-2 | a one-hot copy `wb_oh` next to the write-back slot register; write-back line / data by AND-OR | no binary mux on 512 + 58 bits | `wb_oh` always holds the same slot as `wb_slot` |
| V-4 | the lowest free / pending / dirty slot as one-hot prefix picks | no encoder in the selection paths | the same lowest set bit |
| V-5 | the CAM match is computed one cycle **ahead** from a new input `lookup_line_addr_next` and the next slot states, and registered (`lk_match_q`) | the 58-bit compares end in a flop instead of starting the lookup outputs | requires the line looked up in a cycle to be the previous cycle's `lookup_line_addr_next` (the user's pipeline register does exactly this; the formal wrapper and the test model it) |
| V-7 | the slot state is written **once** per slot from its next value; the input-only overrides (swap, snoop, release, insert) are combined first, and the late write-back start meets only the last AND-OR; the start term written per slot as one sum of products | the slow write-back decision no longer passes the priority chain of the later writes | the same priority order (B response, drain, write-back start, swap, snoop invalidate, release, insert; the later one wins) |
| VC-D | the look-ahead match uses `(next state != FREE) = start | (other next state != FREE)` with the late start last | 4 gates after the start become 1-2 | a write-back start only turns a slot into WBPEND, never into FREE |
| VC-A | `wb_slot` / `wb_oh` load the pick in every cycle without an active write-back (not only on a start) | the enable no longer waits for the start decision | at a start the same slot is loaded; the registers are read only while a write-back is active |
| VC-E | the "write already sent" flag `iss` written once per slot, the start in the last AND | same as V-7 | hand-over and start never happen in the same cycle (a start needs no active write-back); an insert wins, as before |

Tried and **dropped** (measured or failed): state flag flops instead of the 3-bit state decodes (2.7 ps slower, twice); a look-ahead match
without the write-back start (exact only under extra protocol rules, which the random test kept breaking).

## 4. Results so far (critical delay, ps; lower is better; 250 ps = 4 GHz)

| Version | at 250 ps | after gate sizing | at 200 ps | Function |
|---|---|---|---|---|
| `original` (rtl/ref) | 346.2 | - | - | reference |
| `v1245` (V-1, V-2, V-4, V-5) | 301.8 | - | 299.3 | lockstep 3/3, formal 4 cycles |
| `v7` (+ V-7) | 294.6 | 284.8 | 292.1 | lockstep 3/3, formal 4 cycles |
| `opt` (+ VC-A, VC-D, VC-E) | measured by this repository's workflow | | | |

The remaining limit of every version is the one-cycle loop "all slot states -> any pending / dirty / free -> lowest slot -> next state". A
cure without extra cycles is what the variants explore; registering the write-back decision would add a cycle to the start of a write-back.

## 5. How the timing is measured (and how far to trust it)

`flow/run_timing.sh`: OpenROAD-flow-scripts `make synth` (Yosys + ABC) of this module alone, then OpenSTA on the netlist: ideal clock, **no
wires**, input / output delays 0, clock uncertainty 5 % of the period, about 15 ps setup. Critical delay = period - worst slack. With
`SIZED=1`, the ORFS floorplan step (OpenROAD `repair_timing`: gate sizing and pin swapping, still no wires) runs too.

These are **estimates**: real post-route Fmax is expected 15-30 % lower. The same code through the same flow repeats to the digit, but a
small change can move unrelated paths by 10-40 ps (synthesis maps the whole module differently), so only measured numbers count.

## 6. Run it

In the `openroad/orfs` Docker image (it has Yosys and OpenROAD; Icarus Verilog is installed if missing):

```bash
bash scripts/run_all.sh opt rtl/opt out/opt          # all checks + timing for rtl/opt
bash formal/run_formal.sh rtl/opt 6                    # a deeper formal check
SIZED=1 bash flow/run_timing.sh rtl/opt 250 out/t250   # timing only
```

To compare a new idea: copy `rtl/opt/l1d_victim_cache.v` to `variants/<name>/`, change it, push. The workflow runs every version in
parallel and shows the comparison table on the run's summary page. A version must keep the ports and the internal names the test reads
(`lk_match_q`), or run with `FUNC=0` (timing only).

No license is given: all rights reserved.
