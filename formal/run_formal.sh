#!/usr/bin/env bash
# Formal equivalence check (Yosys "sat", bounded model check) of an optimised victim cache against the original one (rtl/ref), both inside
# formal/fv_wrap_victim_cache.v. Both are reset in cycle 1; then every input is free for DEPTH cycles and every output must be equal in every
# cycle after the reset cycle (the write-back address / slot / data only while writeback_req_valid). "EQUIVALENT for N cycles" is a proof for
# every input sequence of that length, not a random test.
#   bash formal/run_formal.sh <rtl dir of the optimised version> [DEPTH (default 4)] [output dir]
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OPTD=$(cd "$1" && pwd)
D=${2:-4}
mkdir -p "${3:-$ROOT/build/formal}"; OUT=$(cd "${3:-$ROOT/build/formal}" && pwd)
if ! command -v yosys >/dev/null 2>&1; then
    for d in /OpenROAD-flow-scripts/tools/install/yosys/bin; do [ -x "$d/yosys" ] && export PATH="$d:$PATH"; done
fi
INC="-I$ROOT/rtl/include"
CMN="$ROOT/rtl/common/l1d_pri_enc.v $ROOT/rtl/common/l1d_cam.v"
RF="$ROOT/rtl/ref/l1d_victim_cache.v $ROOT/rtl/ref/l1d_age_matrix.v $CMN"
NF="$OPTD/l1d_victim_cache.v $OPTD/l1d_age_matrix.v $CMN"
W="$ROOT/formal/fv_wrap_victim_cache.v"
TOP=fv_wrap
Y="$OUT/victim_cache.ys"; L="$OUT/victim_cache.log"
{
    echo "read_verilog -DSYNTHESIS $INC $RF $W"
    echo "hierarchy -top $TOP"
    echo "setattr -mod -unset keep_hierarchy"
    echo "proc; flatten; opt_clean; memory -nomap; memory_map; opt -fast"
    echo "rename $TOP ref_top"
    echo "design -stash ref"
    echo "read_verilog -DSYNTHESIS -DOPT $INC $NF $W"
    echo "hierarchy -top $TOP"
    echo "setattr -mod -unset keep_hierarchy"
    echo "proc; flatten; opt_clean; memory -nomap; memory_map; opt -fast"
    echo "rename $TOP opt_top"
    echo "design -stash opt"
    echo "design -copy-from ref -as ref_top ref_top"
    echo "design -copy-from opt -as opt_top opt_top"
    echo "miter -equiv -flatten -make_outputs ref_top opt_top miter"
    echo "hierarchy -top miter"
    echo "opt -fast"
    echo "sat -verify -seq $D -set-at 1 in_rst 1 -set-init-zero -prove trigger 0 -prove-skip 1 -show-ports -timeout ${TMO:-7200} miter"
} > "$Y"
t0=$(date +%s)
if yosys -q -l "$L" "$Y" > /dev/null 2>&1; then
    echo "victim_cache: EQUIVALENT for $D cycles after reset ($(( $(date +%s) - t0 )) s)"
else
    echo "victim_cache: NOT PROVEN ($(( $(date +%s) - t0 )) s): $(grep -m1 -E 'failed|Timeout|ERROR' "$L")   log: $L"
    exit 1
fi
