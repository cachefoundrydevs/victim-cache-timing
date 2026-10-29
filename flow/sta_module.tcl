# Post-synthesis timing of ONE module (ideal clock, no wires). Called by flow/run_timing.sh.
# Environment: LEF_FILES LIB_FILES NETLIST TOP SDC_FILE CLK_PERIOD_PS REPORT_PREFIX
foreach f $::env(LEF_FILES) { read_lef $f }
foreach f $::env(LIB_FILES) { read_liberty $f }
read_verilog $::env(NETLIST)
link_design $::env(TOP)
read_sdc $::env(SDC_FILE)
set prefix $::env(REPORT_PREFIX)

# worst setup slack (ps) of one path class, "na" if the class has no path.
# Uses report_checks in summary format and takes the last number of the last line (find_timing_paths crashed some OpenROAD builds).
proc class_slack {from_spec to_spec} {
    set cmd [list report_checks -path_delay max -format summary -digits 1]
    if {$from_spec ne ""} { lappend cmd -from $from_spec }
    if {$to_spec   ne ""} { lappend cmd -to $to_spec }
    if {[catch { sta::redirect_string_begin; eval $cmd; set txt [sta::redirect_string_end] } err]} { return "na" }
    set slack "na"
    foreach line [split $txt "\n"] {
        if {[regexp {(-?[0-9]+\.[0-9]+)\s*$} $line -> v]} { set slack $v }
    }
    return $slack
}

set regs_ck [all_registers -clock_pins]
set regs_d  [all_registers -data_pins]
set has_regs [expr {[llength $regs_ck] > 0}]
set ins  [all_inputs]
set outs [all_outputs]

set s_all [class_slack "" ""]
if {$has_regs} {
    set s_r2r   [class_slack $regs_ck $regs_d]
    set s_in2r  [class_slack $ins     $regs_d]
    set s_r2out [class_slack $regs_ck $outs]
} else { set s_r2r na; set s_in2r na; set s_r2out na }
set s_in2out [class_slack $ins $outs]

puts "RESULT top=$::env(TOP) period_ps=$::env(CLK_PERIOD_PS) slack_all=$s_all slack_r2r=$s_r2r slack_in2reg=$s_in2r slack_reg2out=$s_r2out slack_in2out=$s_in2out regs=$has_regs"

report_checks -path_delay max -group_path_count 1 -fields {slew cap fanout} -digits 1 > ${prefix}_worst_path.rpt
catch { report_design_area } msg; puts $msg
catch { report_cell_usage } msg; puts $msg
exit
