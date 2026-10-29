#!/usr/bin/env bash
# Prints the VIOLATED paths of one module that flow/run_timing.sh has already synthesized (ORFS machine).
#   usage:  show_violations.sh l1d_victim_cache [N] [G]
#           N = number of worst violated paths printed in full, each to a different endpoint (default 5)
#           G = number of failing register groups; the worst path of each group is printed in full (default 8)
# Output (also saved to flow_out_modules/results/violations_<module>.txt):
#   1. summary: how many endpoints violate, worst slack, total negative slack
#   2. the failing groups (register / port name with bit and instance numbers removed): endpoints, worst slack
#   3. the N worst violated paths in full (every gate: fanout, slew, delay, arrival, net name)
#   4. for each of the G worst groups: the worst path to that group in full
# Needs flow_out_modules/work_<module> from an earlier flow/run_timing.sh / run_timing.sh run.
set -u
M=${1:?module name, for example l1d_victim_cache}
NP=${2:-5}
NG=${3:-8}
SLACK_MAX=${SLACK_MAX:-0}
HERE=$(cd "$(dirname "$0")" && pwd)
VER=$(cd "$HERE/../../.." && pwd)
OUT=${OUT:-$VER/flow_out_modules}
W="$OUT/work_$M"
[ -d "$W" ] || { echo "ERROR: $W not found. Run run_timing.sh (or flow/run_timing.sh) for $M first."; exit 1; }

if [ -z "${FLOW_HOME:-}" ]; then
    if [ -f /OpenROAD-flow-scripts/flow/Makefile ]; then FLOW_HOME=/OpenROAD-flow-scripts/flow
    else FLOW_HOME=$(dirname "$(find / -path '*/flow/Makefile' -not -path '/proc/*' 2>/dev/null | head -1)"); fi
fi
OPENROAD=${OPENROAD:-$(command -v openroad || find "$FLOW_HOME/.." -name openroad -type f -perm -u+x 2>/dev/null | head -1)}
NET=$(find "$W" -name '1_2_yosys.v' -o -name '1_synth.v' | head -1)
[ -n "$NET" ] || { echo "ERROR: no synthesized netlist in $W"; exit 1; }
SDC="$W/$M.sdc"
STDLIBS=$(sed -n 's/^read_liberty //p' "$OUT/results/synth_$M.log" | grep -v 'l1d_macro' | sort -u | tr '\n' ' ')
[ -z "$STDLIBS" ] && STDLIBS=$(find "$FLOW_HOME/platforms/asap7/lib/NLDM" -name '*RVT_FF*' \( -name '*.lib' -o -name '*.lib.gz' \) | sort | tr '\n' ' ')
LIBS="$STDLIBS"
TECH=$(find "$W" -name '*tech*.lef' | head -1); [ -z "$TECH" ] && TECH=$(find "$FLOW_HOME/platforms/asap7/lef" -name '*tech*.lef' | head -1)
LEFS="$TECH $(find "$FLOW_HOME/platforms/asap7/lef" -name "*sc7p5t*_R_1x*.lef" | sort | head -1)"

P="$OUT/results/violations_$M"
SAVE="$P.txt"
HDR="$P.hdr.tcl"
cat > "$HDR" <<'EOF'
foreach f $::env(LEF_FILES) { read_lef $f }
foreach f $::env(LIB_FILES) { read_liberty $f }
read_verilog $::env(NETLIST)
link_design $::env(TOP)
read_sdc $::env(SDC_FILE)
EOF

run_sta() {   # $1 = tcl file; environment for the header
    LEF_FILES="$LEFS" LIB_FILES="$LIBS" NETLIST="$NET" TOP="$M" SDC_FILE="$SDC" "$OPENROAD" -no_init -exit "$1" 2>&1
}

# ---- step 1: every violated endpoint (one line each) and the N worst paths in full ----
T1="$P.step1.tcl"
{ cat "$HDR"
  echo "report_checks -path_delay max -slack_max $SLACK_MAX -group_path_count 20000 -unique_paths_to_endpoint -format end -digits 1 > ${P}_endpoints.rpt"
  echo "report_checks -path_delay max -slack_max $SLACK_MAX -group_path_count $NP -unique_paths_to_endpoint -fields {fanout net} -digits 1 > ${P}_worstN_full.rpt"
  echo "exit"; } > "$T1"
run_sta "$T1" > "${P}_step1.log"
EP="${P}_endpoints.rpt"
[ -s "$EP" ] || { echo "no violated paths in $M (slack >= $SLACK_MAX ps everywhere) - or the STA failed, see ${P}_step1.log"; exit 0; }

{
echo "######## violated paths of $M (slack < $SLACK_MAX ps) ########"
echo
echo "=== 1. summary ==="
awk '/\(VIOLATED\)/ { s=$(NF-1); n++; t+=s; if (n==1 || s+0 < w+0) w=s }
     END { printf "violated endpoints: %d   worst slack: %.1f ps   total negative slack: %.1f ps\n", n, w, t }' "$EP"

echo
echo "=== 2. failing groups (name with [bit] and instance numbers removed), worst first ==="
awk '/\(VIOLATED\)/ { s=$(NF-1); e=$1; gsub(/\[[0-9]+\]/, "[]", e); gsub(/_[0-9]+_/, "_N_", e); n[e]++; if (!(e in w) || s+0 < w[e]+0) w[e]=s }
     END { for (e in n) printf "%6d endpoints  worst %8.1f ps  %s\n", n[e], w[e], e }' "$EP" | sort -k4,4n

echo
echo "=== 3. the $NP worst violated paths, in full ==="
cat "${P}_worstN_full.rpt"
} > "$SAVE"

# ---- step 2: the worst path of each of the G worst groups ----
# endpoint line: "<name> (<cell or output>)   required  arrival  slack (VIOLATED)"; the group key is the name without numbers
awk '/\(VIOLATED\)/ { s=$(NF-1); e=$1; k=e; gsub(/\[[0-9]+\]/, "[]", k); gsub(/_[0-9]+_/, "_N_", k);
                       if (!(k in w) || s+0 < w[k]+0) { w[k]=s; ep[k]=e } }
     END { for (k in w) printf "%s %s\n", w[k], ep[k] }' "$EP" | sort -n | head -"$NG" > "${P}_groups_worst_endpoint.txt"

T2="$P.step2.tcl"
{ cat "$HDR"
  while read -r slack name; do
      # the name as printed by STA; try a port, then a pin
      # braces: the name holds $ and [ ] which Tcl must not substitute
      echo "puts \"\""
      echo "puts {######## group worst endpoint $name  (slack $slack ps) ########}"
      echo "set e {}"
      echo "catch { set e [get_ports -quiet {$name}] }"
      echo "if {[llength \$e] == 0} { catch { set e [get_pins -quiet {$name}] } }"
      echo "if {[llength \$e] == 0} { puts \"endpoint not found by name\" } else { report_checks -path_delay max -to \$e -fields {fanout net} -digits 1 }"
  done < "${P}_groups_worst_endpoint.txt"
  echo "exit"; } > "$T2"
{ echo; echo "=== 4. the worst path of each of the $NG worst groups, in full ==="; run_sta "$T2"; } >> "$SAVE"

cat "$SAVE"
echo
echo "(saved: $SAVE ; endpoint list: $EP)"
