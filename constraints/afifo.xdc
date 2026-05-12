# ==============================================================================
# XDC Constraints for Asynchronous FIFO (AFIFO)
# Target: Xilinx 7-Series / UltraScale / UltraScale+
# Reference: Cummings SNUG 2002 – Asynchronous FIFO Design
#
# IMPORTANT: Replace clock net names and pin locations to match your design.
# Run "report_clock_interaction" and "report_cdc" after implementation to
# verify all CDC paths are correctly constrained.
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. PRIMARY CLOCKS
#    Replace [get_ports ...] net names with actual port names in your design.
# ------------------------------------------------------------------------------

# Write clock – example: 100 MHz
create_clock -period 10.000 -name wr_clk -waveform {0.000 5.000} \
    [get_ports wr_clk]

# Read clock – example: ~59 MHz (async, no phase relationship with wr_clk)
create_clock -period 17.000 -name rd_clk -waveform {0.000 8.500} \
    [get_ports rd_clk]

# Declare the two clocks as asynchronous to each other.
# This suppresses false timing paths between the domains.
set_clock_groups -asynchronous \
    -group [get_clocks wr_clk] \
    -group [get_clocks rd_clk]

# ------------------------------------------------------------------------------
# 2. CDC PATH CONSTRAINTS – Gray-code pointer synchronizer chains
#
#    The 2-FF synchronizer stages are identified by their hierarchical paths.
#    Adjust the instance paths to match your top-level hierarchy.
#
#    Cummings method: only ONE bit changes per transition in gray-code, so a
#    single-cycle max_delay constraint (≈ destination clock period) is safe.
# ------------------------------------------------------------------------------

# -- Write Gray Pointer → Read Domain synchronizer (stage 1 FF) --
#    Source: wr_ptr_gray registers in write domain
#    Dest  : wr_ptr_gray_s1 registers in read domain
set_max_delay -datapath_only \
    -from [get_cells -hierarchical -filter {NAME =~ *wr_ptr_gray_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *wr_ptr_gray_s1_reg*}] \
    17.000
    # Use destination (rd_clk) period

# -- Read Gray Pointer → Write Domain synchronizer (stage 1 FF) --
#    Source: rd_ptr_gray registers in read domain
#    Dest  : rd_ptr_gray_s1 registers in write domain
set_max_delay -datapath_only \
    -from [get_cells -hierarchical -filter {NAME =~ *rd_ptr_gray_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *rd_ptr_gray_s1_reg*}] \
    10.000
    # Use destination (wr_clk) period

# ------------------------------------------------------------------------------
# 3. FALSE PATH on RESET SYNCHRONIZATION
#    Async resets cross no timing paths; declare false_path to avoid warnings.
# ------------------------------------------------------------------------------
set_false_path -from [get_ports wr_rst_n] -to [all_registers]
set_false_path -from [get_ports rd_rst_n] -to [all_registers]

# ------------------------------------------------------------------------------
# 4. BLOCK RAM PLACEMENT (optional – uncomment and adjust for timing closure)
#    Forces the dual-port BRAM to a specific RAMB column when needed.
# ------------------------------------------------------------------------------
# set_property LOC RAMB36_X0Y0 [get_cells -hierarchical -filter {NAME =~ *u_mem*}]

# ------------------------------------------------------------------------------
# 5. SYNCHRONIZER PBLOCK (optional – place synchronizer FFs close together)
#    Reduces routing delay on the critical CDC capture flip-flop.
# ------------------------------------------------------------------------------
# create_pblock pblock_wr2rd_sync
# add_cells_to_pblock [get_pblocks pblock_wr2rd_sync] \
#     [get_cells -hierarchical -filter {NAME =~ *wr_ptr_gray_s*_reg*}]
# resize_pblock [get_pblocks pblock_wr2rd_sync] -add {SLICE_X0Y0:SLICE_X3Y3}

# create_pblock pblock_rd2wr_sync
# add_cells_to_pblock [get_pblocks pblock_rd2wr_sync] \
#     [get_cells -hierarchical -filter {NAME =~ *rd_ptr_gray_s*_reg*}]
# resize_pblock [get_pblocks pblock_rd2wr_sync] -add {SLICE_X0Y4:SLICE_X3Y7}

# ------------------------------------------------------------------------------
# 6. I/O CONSTRAINTS (example – replace with actual FPGA pin assignments)
# ------------------------------------------------------------------------------
# set_property PACKAGE_PIN  E3  [get_ports wr_clk]
# set_property IOSTANDARD   LVCMOS33 [get_ports wr_clk]

# set_property PACKAGE_PIN  D4  [get_ports rd_clk]
# set_property IOSTANDARD   LVCMOS33 [get_ports rd_clk]

# set_property PACKAGE_PIN  C12 [get_ports wr_rst_n]
# set_property IOSTANDARD   LVCMOS33 [get_ports wr_rst_n]

# set_property PACKAGE_PIN  D12 [get_ports rd_rst_n]
# set_property IOSTANDARD   LVCMOS33 [get_ports rd_rst_n]

# ------------------------------------------------------------------------------
# 7. TIMING EXCEPTION DOCUMENTATION
#    The following paths are intentionally unconstrained / false:
#
#    a) wr_ptr_gray_reg* → wr_ptr_gray_s1_reg*  (gray CDC, max_delay applied)
#    b) rd_ptr_gray_reg* → rd_ptr_gray_s1_reg*  (gray CDC, max_delay applied)
#    c) *_s1_reg* → *_s2_reg*                   (synchronizer stage 2,
#                                                 covered by rd_clk/wr_clk period)
#    d) Reset ports                              (false_path declared above)
#
#    All other paths are covered by set_clock_groups -asynchronous.
# ------------------------------------------------------------------------------
