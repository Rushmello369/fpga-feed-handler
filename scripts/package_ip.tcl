#=============================================================================
# package_ip.tcl  --  Package feed_handler as a reusable Vivado IP.
#
# Run from the Vivado Tcl console:
#     cd C:/fpga-feed-handler
#     source scripts/package_ip.tcl
#
# Output IP repository (fixed, git-tracked):
#     C:/fpga-feed-handler/ip_repo/feed_handler/component.xml
#
# Safe to re-run: it wipes the temp project and the IP folder each time.
#=============================================================================

set repo_root C:/fpga-feed-handler
set ip_dir    $repo_root/ip_repo/feed_handler
set tmp_proj  $repo_root/vivado/_pkg_tmp
set part      xc7z020clg400-1

# ---- clean previous output -------------------------------------------------
catch {close_project}
file delete -force $tmp_proj
file delete -force $ip_dir
file mkdir $ip_dir

# ---- scratch project just for packaging ------------------------------------
create_project pkg_feed_handler $tmp_proj -part $part -force

add_files -norecurse [list \
    $repo_root/rtl/fm24_pkg.sv \
    $repo_root/rtl/msg_parser.sv \
    $repo_root/rtl/book_update.sv \
    $repo_root/rtl/priority_encoder.sv \
    $repo_root/rtl/tob_tracker.sv \
    $repo_root/rtl/latency_counter.sv \
    $repo_root/rtl/top.sv \
    $repo_root/rtl/feed_handler.sv ]

set_property file_type SystemVerilog [get_files *.sv]
set_property top feed_handler [current_fileset]
update_compile_order -fileset sources_1

# ---- package: auto-infers AXI4-Lite (s_axi) and AXI4-Stream (s_axis) -------
ipx::package_project -root_dir $ip_dir -vendor user.org -library user \
    -taxonomy /UserIP -import_files -set_current true

set core [ipx::current_core]
set_property name         feed_handler $core
set_property display_name feed_handler $core
set_property description  "Cut-through feed parser + limit order book" $core
set_property version      1.0 $core
set_property core_revision 1 $core

# ---- tie each AXI interface to the clock (and the active-low reset) --------
ipx::associate_bus_interfaces -busif s_axi  -clock aclk $core
ipx::associate_bus_interfaces -busif s_axis -clock aclk $core

# ---- finalize --------------------------------------------------------------
ipx::create_xgui_files $core
ipx::update_checksums  $core
ipx::check_integrity   $core
ipx::save_core         $core

# ---- report what got packaged (verification) -------------------------------
puts "============================================================"
puts " feed_handler packaged at:"
puts "   $ip_dir/component.xml"
puts " Bus interfaces detected:"
foreach bif [ipx::get_bus_interfaces -of_objects $core] {
    puts [format "   %-8s  %s" \
        [get_property name $bif] [get_property bus_type_vlnv $bif]]
}
puts "============================================================"

close_project
file delete -force $tmp_proj
puts "DONE. Add this repo in your impl project: $repo_root/ip_repo"
