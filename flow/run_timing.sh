#!/usr/bin/env bash
# ASAP7 timing of l1d_victim_cache: Yosys + ABC through OpenROAD-flow-scripts ("make synth"), then OpenSTA on that netlist with an ideal
# clock, no wires, input / output delays 0, clock uncertainty 5 % of the period. With SIZED=1 also the ORFS floorplan step (gate sizing and
# pin swapping by OpenROAD's repair_timing, still without placement and wires) and STA again on the repaired netlist.
#   bash flow/run_timing.sh <rtl dir holding l1d_victim_cache.v and l1d_age_matrix.v> <period in ps> <output dir>
# Writes <output dir>/result.txt (one RESULT line), results/ (logs, worst path) and violations.txt (failing groups and worst paths).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RTL=$(cd "$1" && pwd)
PERIOD=$2
mkdir -p "$3"; OUT=$(cd "$3" && pwd)
M=l1d_victim_cache
FLOW_HOME=${FLOW_HOME:-/OpenROAD-flow-scripts/flow}
[ -f "$FLOW_HOME/Makefile" ] || { echo "ERROR: OpenROAD-flow-scripts not found (set FLOW_HOME)"; exit 1; }
if [ -z "${OPENROAD:-}" ] || [ -d "${OPENROAD:-}" ]; then
    OPENROAD=$(command -v openroad || echo "$FLOW_HOME/../tools/install/OpenROAD/bin/openroad")
fi
export OPENROAD
export CLK_PERIOD_PS=$PERIOD

W=$OUT/work_$M
rm -rf "$W"; mkdir -p "$W" "$OUT/results"
FILES="$RTL/l1d_victim_cache.v $RTL/l1d_age_matrix.v $ROOT/rtl/common/l1d_pri_enc.v $ROOT/rtl/common/l1d_cam.v"
SDC=$W/$M.sdc
cat > "$SDC" <<EOF
set_units -time ps -capacitance fF
create_clock -name clk -period $PERIOD [get_ports clk]
set_clock_uncertainty [expr {0.05 * $PERIOD}] [get_clocks clk]
set in_ports [lsearch -all -inline -not -exact [all_inputs] [get_ports clk]]
set_input_delay 0 -clock clk \$in_ports
set_output_delay 0 -clock clk [all_outputs]
EOF
cat > "$W/config.mk" <<EOF
export PLATFORM            = asap7
export DESIGN_NAME         = $M
export VERILOG_FILES       = $FILES
export VERILOG_INCLUDE_DIRS = $ROOT/rtl/include
export SDC_FILE            = $SDC
export CORE_UTILIZATION    = 40
export SYNTH_HIERARCHICAL  = 0
EOF

echo "=== $M at $PERIOD ps: synthesis ==="
( cd "$FLOW_HOME" && make DESIGN_CONFIG="$W/config.mk" WORK_HOME="$W" synth ) > "$OUT/results/synth_$M.log" 2>&1
NET=$(find "$W" -name '1_2_yosys.v' -o -name '1_synth.v' | head -1)
[ -n "$NET" ] || { echo "synthesis failed:"; tail -20 "$OUT/results/synth_$M.log"; echo "RESULT period=$PERIOD status=SYNTH_FAIL" > "$OUT/result.txt"; exit 1; }

STDLIBS=$(sed -n 's/^read_liberty //p' "$OUT/results/synth_$M.log" | sort -u | tr '\n' ' ')
[ -z "$STDLIBS" ] && STDLIBS=$(find "$FLOW_HOME/platforms/asap7/lib/NLDM" -name '*RVT_FF*' \( -name '*.lib' -o -name '*.lib.gz' \) | sort | tr '\n' ' ')
TECH=$(find "$W" -name '*tech*.lef' | head -1); [ -z "$TECH" ] && TECH=$(find "$FLOW_HOME/platforms/asap7/lef" -name '*tech*.lef' | head -1)
LEFS="$TECH $(find "$FLOW_HOME/platforms/asap7/lef" -name '*sc7p5t*_R_1x*.lef' | sort | head -1)"

sta() {   # $1 = netlist, $2 = report prefix; prints the worst slack
    LEF_FILES="$LEFS" LIB_FILES="$STDLIBS" NETLIST="$1" TOP="$M" SDC_FILE="$SDC" REPORT_PREFIX="$2" \
        "$OPENROAD" -no_init -exit "$ROOT/flow/sta_module.tcl" > "$2.sta.log" 2>&1
    sed -n 's/^RESULT.*slack_all=\([^ ]*\).*/\1/p' "$2.sta.log" | tail -1
}
SA=$(sta "$NET" "$OUT/results/$M")
AREA=$(sed -n 's/^Design area \([0-9.]*\) u.*/\1/p' "$OUT/results/$M.sta.log" | head -1)
CRIT=$(awk -v p="$PERIOD" -v s="$SA" 'BEGIN{ if (s=="" || s=="na") print "-"; else printf "%.1f", p-s }')
echo "  synthesis only: worst slack $SA ps, critical delay $CRIT ps, area $AREA um2"
LINE="RESULT period=$PERIOD synth_slack=$SA synth_crit=$CRIT area=$AREA"

echo "=== $M at $PERIOD ps: violated paths ==="
OUT="$OUT" FLOW_HOME="$FLOW_HOME" bash "$ROOT/flow/show_violations.sh" "$M" "${N:-1}" "${G:-8}" > "$OUT/violations.txt" 2>&1
sed -n '/=== 1. summary/,/=== 3. the/p' "$OUT/violations.txt" | sed '$d'

if [ "${SIZED:-0}" = 1 ]; then
    echo "=== $M at $PERIOD ps: ORFS floorplan step (gate sizing / pin swap) ==="
    ( cd "$FLOW_HOME" && make DESIGN_CONFIG="$W/config.mk" WORK_HOME="$W" floorplan ) > "$OUT/results/floorplan_$M.log" 2>&1
    ODB=$(find "$W" -name '2_1_floorplan.odb' | head -1)
    if [ -n "$ODB" ]; then
        printf 'read_db $::env(ODB)\nwrite_verilog $::env(OUTV)\n' > "$W/odb2v.tcl"
        ODB="$ODB" OUTV="$W/sized.v" "$OPENROAD" -no_init -exit "$W/odb2v.tcl" > "$OUT/results/odb2v.log" 2>&1
        FPLOG=$(find "$W" -name '2_1_floorplan.log' | head -1)
        [ -n "$FPLOG" ] && grep -E "RSZ-0051|RSZ-0043|RSZ-0098|RSZ-0062" "$FPLOG" | sed 's/^/  | /'
        ZS=$(sta "$W/sized.v" "$OUT/results/${M}_sized")
        ZC=$(awk -v p="$PERIOD" -v s="$ZS" 'BEGIN{ if (s=="" || s=="na") print "-"; else printf "%.1f", p-s }')
        echo "  after sizing:   worst slack $ZS ps, critical delay $ZC ps"
        LINE="$LINE sized_slack=$ZS sized_crit=$ZC"
    else
        echo "  floorplan step failed (see results/floorplan_$M.log)"; LINE="$LINE sized_slack=FP_FAIL"
    fi
fi
echo "$LINE" > "$OUT/result.txt"
cat "$OUT/result.txt"
