# ==============================================================================
# run.tcl  —  Vivado 2020.2  Non-Project Mode  全流程脚本
# 设计  : Asynchronous FIFO (Cummings Method)
# 用法  : vivado -mode batch -source run.tcl
#         vivado -mode tcl   -source run.tcl      (交互模式，出错可检查)
#         vivado -mode batch -source run.tcl -tclargs xc7a35tcpg236-1 impl
# ==============================================================================

# ------------------------------------------------------------------------------
# 0. 全局配置  ── 根据实际情况修改这一节
# ------------------------------------------------------------------------------
set PART        "xc7a35tcpg236-1"           ;# 目标器件
set TOP         "afifo"                      ;# 顶层模块名
set BOARD_PART  ""                           ;# 可选: e.g. "digilentinc.com:arty-a7-35:part0:1.1"

# 目录结构（相对于本脚本所在目录）
set SCRIPT_DIR  [file dirname [file normalize [info script]]]
set RTL_DIR     "$SCRIPT_DIR/rtl"
set SIM_DIR     "$SCRIPT_DIR/sim"
set XDC_DIR     "$SCRIPT_DIR/constraints"
set OUTPUT_DIR  "$SCRIPT_DIR/output_products"

# 运行控制：set 为 1 则执行该步骤
set RUN_SYNTH   1
set RUN_IMPL    1
set RUN_TIMING  1
set RUN_REPORT  1
set RUN_BITGEN  1          ;# 需要 RUN_IMPL=1 才有效
set RUN_SIM     0          ;# 需要安装 xsim；batch 仿真独立运行

# 综合策略 / 实现策略
set SYNTH_STRATEGY  "Vivado Synthesis Defaults"
set IMPL_STRATEGY   "Performance_ExplorePostRoutePhysOpt"

# 命令行参数覆盖（可选）
if {[llength $argv] >= 1} { set PART    [lindex $argv 0] }
if {[llength $argv] >= 2} {
    set step [lindex $argv 1]
    if {$step eq "synth"} { set RUN_IMPL 0; set RUN_BITGEN 0 }
    if {$step eq "impl" } { set RUN_SYNTH 0 }
}

# ------------------------------------------------------------------------------
# 1. 工具函数
# ------------------------------------------------------------------------------
proc banner {msg} {
    set line [string repeat "=" 72]
    puts "\n$line"
    puts "  $msg"
    puts "$line"
}

proc elapsed {start} {
    set sec [expr {int([clock seconds] - $start)}]
    return [format "%02d:%02d:%02d" \
        [expr {$sec/3600}] [expr {($sec%3600)/60}] [expr {$sec%60}]]
}

proc check_timing {wns whs tns ths} {
    set ok 1
    if {$wns < 0} { puts "  [WARNING] WNS = ${wns} ns  (SETUP VIOLATION)"; set ok 0 }
    if {$whs < 0} { puts "  [WARNING] WHS = ${whs} ns  (HOLD  VIOLATION)"; set ok 0 }
    if {$ok}      { puts "  [INFO]    Timing MET  WNS=$wns  WHS=$whs" }
    return $ok
}

# ------------------------------------------------------------------------------
# 2. 创建输出目录
# ------------------------------------------------------------------------------
foreach d [list $OUTPUT_DIR \
               $OUTPUT_DIR/synth \
               $OUTPUT_DIR/impl \
               $OUTPUT_DIR/reports \
               $OUTPUT_DIR/bitstream \
               $OUTPUT_DIR/sim] {
    file mkdir $d
}

set T0 [clock seconds]
banner "Vivado 2020.2  Non-Project Flow  |  PART: $PART  |  TOP: $TOP"

# ==============================================================================
# 3. 仿真（可选，Non-Project XSim）
# ==============================================================================
if {$RUN_SIM} {
    banner "STEP 0: Behavioral Simulation (XSim)"
    set t [clock seconds]

    # 读入仿真源
    read_verilog -sv [glob $RTL_DIR/*.v]
    read_verilog      $SIM_DIR/tb_afifo.v

    # 详细仿真分析
    set_property top tb_afifo [current_fileset -simset]
    launch_simulation -simset [current_fileset -simset] -mode behavioral

    puts "  [INFO] Sim done in [elapsed $t]"
}

# ==============================================================================
# 4. 综合
# ==============================================================================
if {$RUN_SYNTH} {
    banner "STEP 1: Synthesis"
    set t [clock seconds]

    # -- 4.1 读入设计源 --
    read_verilog [list \
        $RTL_DIR/gray2bin.v  \
        $RTL_DIR/afifo_mem.v \
        $RTL_DIR/afifo.v     \
    ]

    # -- 4.2 读入约束 --
    read_xdc $XDC_DIR/afifo.xdc

    # -- 4.3 综合 --
    # 常用 synth_design 选项说明：
    #   -flatten_hierarchy rebuilt  重建层级（便于报告）
    #   -gated_clock_conversion off 关闭门控时钟转换
    #   -bufg 12                    最多推断 12 个 BUFG
    #   -fanout_limit 10000         扇出限制
    #   -directive $SYNTH_STRATEGY  综合策略
    synth_design \
        -top              $TOP          \
        -part             $PART         \
        -flatten_hierarchy rebuilt      \
        -gated_clock_conversion off     \
        -bufg             12            \
        -fanout_limit     10000         \
        -no_lc                          \
        -fsm_extraction   auto          \
        -keep_equivalent_registers      \
        -directive        "Default"

    # -- 4.4 综合后优化 --
    opt_design

    # -- 4.5 综合检查点 --
    set dcp_synth $OUTPUT_DIR/synth/${TOP}_synth.dcp
    write_checkpoint -force $dcp_synth
    puts "  [INFO] Synth checkpoint: $dcp_synth"

    # -- 4.6 综合报告 --
    report_utilization  -file $OUTPUT_DIR/reports/utilization_synth.rpt \
                        -hierarchical
    report_timing_summary -file $OUTPUT_DIR/reports/timing_synth.rpt \
                          -warn_on_violation -max_paths 10
    report_clocks         -file $OUTPUT_DIR/reports/clocks_synth.rpt
    report_clock_interaction \
                          -file $OUTPUT_DIR/reports/clock_interaction_synth.rpt \
                          -delay_type min_max
    report_cdc            -file $OUTPUT_DIR/reports/cdc_synth.rpt \
                          -details -severity {Critical Warning}
    report_drc            -file $OUTPUT_DIR/reports/drc_synth.rpt

    puts "  [INFO] Synthesis done in [elapsed $t]"
}

# ==============================================================================
# 5. 实现
# ==============================================================================
if {$RUN_IMPL} {
    banner "STEP 2: Implementation"
    set t [clock seconds]

    # 如果跳过了综合，从检查点恢复
    if {!$RUN_SYNTH} {
        set dcp_synth $OUTPUT_DIR/synth/${TOP}_synth.dcp
        if {![file exists $dcp_synth]} {
            error "Synth checkpoint not found: $dcp_synth\n  Run with RUN_SYNTH=1 first."
        }
        open_checkpoint $dcp_synth
        puts "  [INFO] Restored synth checkpoint: $dcp_synth"
    }

    # -- 5.1 布局 --
    place_design -directive $IMPL_STRATEGY

    # -- 5.2 布局后物理优化 --
    phys_opt_design -directive AggressiveExplore

    # -- 5.3 布线 --
    route_design -directive $IMPL_STRATEGY

    # -- 5.4 布线后优化 --
    phys_opt_design -directive AggressiveExplore

    # -- 5.5 实现检查点 --
    set dcp_impl $OUTPUT_DIR/impl/${TOP}_impl.dcp
    write_checkpoint -force $dcp_impl
    puts "  [INFO] Impl checkpoint: $dcp_impl"

    puts "  [INFO] Implementation done in [elapsed $t]"
}

# ==============================================================================
# 6. 时序 & 实现报告
# ==============================================================================
if {$RUN_REPORT && $RUN_IMPL} {
    banner "STEP 3: Reports"
    set t [clock seconds]

    # 如果只跑报告，从实现检查点恢复
    if {!$RUN_IMPL} {
        set dcp_impl $OUTPUT_DIR/impl/${TOP}_impl.dcp
        open_checkpoint $dcp_impl
    }

    # 时序汇总
    report_timing_summary \
        -file           $OUTPUT_DIR/reports/timing_impl.rpt \
        -warn_on_violation \
        -max_paths      20 \
        -delay_type     min_max

    # 详细 setup/hold 路径
    report_timing \
        -file           $OUTPUT_DIR/reports/timing_paths.rpt \
        -sort_by        slack \
        -max_paths      50 \
        -delay_type     max \
        -path_type      full_clock_expanded

    # 资源利用
    report_utilization \
        -file           $OUTPUT_DIR/reports/utilization_impl.rpt \
        -hierarchical

    # 功耗
    report_power \
        -file           $OUTPUT_DIR/reports/power.rpt

    # DRC
    report_drc \
        -file           $OUTPUT_DIR/reports/drc_impl.rpt

    # 时钟交互（验证 CDC 约束）
    report_clock_interaction \
        -file           $OUTPUT_DIR/reports/clock_interaction_impl.rpt \
        -delay_type     min_max \
        -significant_only

    # CDC 专项报告
    report_cdc \
        -file           $OUTPUT_DIR/reports/cdc_impl.rpt \
        -details

    # 方法学检查
    report_methodology \
        -file           $OUTPUT_DIR/reports/methodology.rpt

    # 读取 WNS/WHS 并打印摘要
    if {[catch {
        set timing [report_timing_summary -return_string -no_header]
        set wns_line [regexp -line -inline {WNS.*} $timing]
        puts "  [INFO] $wns_line"
    }]} {
        puts "  [INFO] (Timing summary parse skipped)"
    }

    puts "  [INFO] Reports done in [elapsed $t]"
}

# ==============================================================================
# 7. 比特流生成
# ==============================================================================
if {$RUN_BITGEN && $RUN_IMPL} {
    banner "STEP 4: Bitstream Generation"
    set t [clock seconds]

    # 配置比特流属性（根据需要修改）
    set_property BITSTREAM.CONFIG.SPI_BUSWIDTH    4       [current_design]
    set_property BITSTREAM.CONFIG.CONFIGRATE      33      [current_design]
    set_property BITSTREAM.GENERAL.COMPRESS       TRUE    [current_design]
    set_property BITSTREAM.CONFIG.UNUSEDPIN       Pulldown [current_design]

    write_bitstream \
        -force \
        -bin_file \
        $OUTPUT_DIR/bitstream/${TOP}.bit

    # 同时输出可用于 hw_manager 的 ltx 探针文件（如有 ILA）
    # write_debug_probes -force $OUTPUT_DIR/bitstream/${TOP}.ltx

    puts "  [INFO] Bitstream: $OUTPUT_DIR/bitstream/${TOP}.bit"
    puts "  [INFO] Bitstream done in [elapsed $t]"
}

# ==============================================================================
# 8. 导出硬件描述（给 Vitis / SDK 使用，可选）
# ==============================================================================
# write_hw_platform -fixed -force \
#     -file $OUTPUT_DIR/${TOP}.xsa \
#     -include_bit

# ==============================================================================
# 9. 完成汇总
# ==============================================================================
banner "DONE  —  Total elapsed: [elapsed $T0]"
puts ""
puts "  输出目录结构:"
puts "    $OUTPUT_DIR/"
puts "    ├── synth/          综合检查点 (.dcp)"
puts "    ├── impl/           实现检查点 (.dcp)"
puts "    ├── reports/        所有报告   (.rpt)"
puts "    └── bitstream/      比特流     (.bit / .bin)"
puts ""

# batch 模式自动退出；tcl 模式保持会话
if {[string match "*batch*" [info nameofexecutable]] || \
    [catch {info level -1}]} {
    # 已在 batch 模式下，Vivado 会自动退出
} else {
    puts "  [提示] 交互模式下请手动输入 exit 退出。"
}
