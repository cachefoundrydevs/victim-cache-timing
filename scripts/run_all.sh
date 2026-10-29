#!/usr/bin/env bash
# Every check for ONE version of the victim cache, and a summary table:
#   1. lockstep simulation (Icarus Verilog): the version against the original (rtl/ref), 3 runs, every output compared in every cycle
#   2. formal equivalence (Yosys sat), 4 cycles after reset
#   3. ASAP7 timing at 250 ps (4 GHz, with gate sizing) and 200 ps (5 GHz), with the failing groups
#   bash scripts/run_all.sh <name> <rtl dir holding l1d_victim_cache.v and l1d_age_matrix.v> <output dir>
# Writes <output dir>/summary.md. Exit status 1 if a function check fails (the timing still runs, so the numbers are there to compare).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=$1
OPTD=$(cd "$2" && pwd)
mkdir -p "$3"; OUT=$(cd "$3" && pwd)
status=0

LS=" not run"; FM="not run"
if [ "${FUNC:-1}" = 1 ]; then      # FUNC=0: timing only (for a version without the ports / signals the tests use, e.g. the original)
# ---- 1. lockstep ----
mkdir -p "$OUT/lockstep"
REFB="$OUT/lockstep/ref"; mkdir -p "$REFB"
sed -E 's/\bl1d_victim_cache\b/l1d_victim_cache_ref/g; s/\bl1d_age_matrix\b/l1d_age_matrix_ref/g' "$ROOT/rtl/ref/l1d_victim_cache.v" > "$REFB/l1d_victim_cache_ref.v"
sed -E 's/\bl1d_age_matrix\b/l1d_age_matrix_ref/g' "$ROOT/rtl/ref/l1d_age_matrix.v" > "$REFB/l1d_age_matrix_ref.v"
LS=""   # (reset when the function checks run)
n=0
for defs in "" "-DSEED=5" "-DSEED=11 -DNCYC=600000"; do
    n=$((n+1)); log="$OUT/lockstep/run$n.log"
    if iverilog -g2012 -I"$ROOT/rtl/include" $defs -s tb_victim_cache_equiv -o "$OUT/lockstep/run$n.vvp" \
            "$OPTD/l1d_victim_cache.v" "$OPTD/l1d_age_matrix.v" "$ROOT/rtl/common/l1d_pri_enc.v" "$ROOT/rtl/common/l1d_cam.v" \
            "$REFB/l1d_victim_cache_ref.v" "$REFB/l1d_age_matrix_ref.v" "$ROOT/tb/tb_victim_cache_equiv.v" > "$log" 2>&1; then
        timeout 3000 vvp -n "$OUT/lockstep/run$n.vvp" >> "$log" 2>&1
    fi
    if grep -q "TEST PASSED" "$log"; then r="PASS"; else r="FAIL"; status=1; fi
    echo "lockstep run $n (${defs:-default}): $r"; tail -4 "$log" | sed 's/^/  | /'
    LS="$LS $r"
done

# ---- 2. formal ----
FM=$(bash "$ROOT/formal/run_formal.sh" "$OPTD" 4 "$OUT/formal" 2>&1 | tail -1)
echo "$FM"
case "$FM" in *EQUIVALENT*) ;; *) status=1 ;; esac

fi
# ---- 3. timing ----
SIZED=1 PATH_LOG=1 bash "$ROOT/flow/run_timing.sh" "$OPTD" 250 "$OUT/t250"
bash "$ROOT/flow/run_timing.sh" "$OPTD" 200 "$OUT/t200"
v() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" "$1" 2>/dev/null | head -1; }

# ---- summary ----
{
    echo "## Victim cache version \`$NAME\`"
    echo
    echo "| check | result |"
    echo "|---|---|"
    echo "| lockstep against the original (3 runs) |$LS |"
    echo "| formal equivalence | $FM |"
    echo "| timing at 250 ps (4 GHz), synthesis only | $(v "$OUT/t250/result.txt" synth_crit) ps (slack $(v "$OUT/t250/result.txt" synth_slack)) |"
    echo "| timing at 250 ps after gate sizing | $(v "$OUT/t250/result.txt" sized_crit) ps (slack $(v "$OUT/t250/result.txt" sized_slack)) |"
    echo "| timing at 200 ps (5 GHz), synthesis only | $(v "$OUT/t200/result.txt" synth_crit) ps (slack $(v "$OUT/t200/result.txt" synth_slack)) |"
    echo "| area | $(v "$OUT/t250/result.txt" area) um2 |"
    echo
    echo "Failing groups at 250 ps (worst first):"
    echo
    echo '```'
    sed -n '/=== 2. failing groups/,/=== 3. the/p' "$OUT/t250/violations.txt" | sed '1d;$d' | head -14
    echo '```'
} > "$OUT/summary.md"
cat "$OUT/summary.md"
exit $status
