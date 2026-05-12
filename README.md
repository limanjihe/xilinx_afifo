# Asynchronous FIFO — Cummings Method (Xilinx FPGA)

## 文件结构

```
afifo/
├── rtl/
│   ├── afifo.v        ← 顶层模块（双时钟域 FIFO 控制器）
│   ├── afifo_mem.v    ← 双端口 Block RAM（Xilinx BRAM 推断）
│   └── gray2bin.v     ← 格雷码→二进制 组合逻辑转换器
├── sim/
│   └── tb_afifo.v     ← 自校验仿真测试台
├── constraints/
│   └── afifo.xdc      ← Vivado XDC 约束（时钟/CDC/I/O）
├── run.tcl            ← Vivado 2020.2 Non-Project 全流程脚本
└── README.md
```

---

## 设计方法：Cummings SNUG 2002

### 核心原理

| 问题 | 解决方案 |
|------|---------|
| 跨时钟域指针传输 | 格雷码（每次只变1 bit，消除多 bit 亚稳态） |
| 亚稳态抑制 | 2级寄存器同步器（两端各一条同步链） |
| Full 判断 | 写域中：写指针 vs 同步后的读指针（格雷码比较） |
| Empty 判断 | 读域中：读指针 == 同步后的写指针（格雷码相等） |
| 存储器 | 双端口 BRAM（`ram_style = "block"` 属性强制推断） |

### 格雷码 Full/Empty 条件

```
Empty : rd_ptr_gray  == wr_ptr_gray_s2          (所有位相等)

Full  : wr_ptr_gray  == { ~rd_ptr_gray_s2[N:N-1],
                            rd_ptr_gray_s2[N-2:0] }
        (最高两位取反，其余相等)
```

---

## 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `DATA_WIDTH` | 8 | 数据位宽 |
| `ADDR_WIDTH` | 4 | 地址位宽，FIFO 深度 = 2^ADDR_WIDTH = 16 |

---

## 端口说明

### 写时钟域
| 信号 | 方向 | 说明 |
|------|------|------|
| `wr_clk` | in | 写时钟 |
| `wr_rst_n` | in | 异步低电平复位 |
| `wr_en` | in | 写使能（full 时忽略） |
| `wr_data[W-1:0]` | in | 写数据 |
| `wr_full` | out | FIFO 满标志 |
| `wr_count[A:0]` | out | 写域视角的数据条数 |

### 读时钟域
| 信号 | 方向 | 说明 |
|------|------|------|
| `rd_clk` | in | 读时钟 |
| `rd_rst_n` | in | 异步低电平复位 |
| `rd_en` | in | 读使能（empty 时忽略） |
| `rd_data[W-1:0]` | out | 读数据（BRAM 同步输出，rd_en 后 1 拍有效） |
| `rd_empty` | out | FIFO 空标志 |
| `rd_count[A:0]` | out | 读域视角的数据条数 |

---

## XDC 约束要点

1. **`create_clock`** — 分别声明 `wr_clk` 和 `rd_clk`
2. **`set_clock_groups -asynchronous`** — 告知 Vivado 两时钟无相位关系
3. **`set_max_delay -datapath_only`** — 约束格雷码跨域路径（仅数据路径，值 = 目标时钟周期）
4. **`set_false_path`** — 复位信号无需时序分析

---

## Vivado 2020.2 Non-Project 构建流程

### 快速开始

```bash
# 完整流程（综合 → 实现 → 报告 → 比特流）
vivado -mode batch -source run.tcl

# 指定器件型号，只运行综合
vivado -mode batch -source run.tcl -tclargs xc7k325tffg900-2 synth

# 指定器件，从综合检查点继续实现（跳过综合）
vivado -mode batch -source run.tcl -tclargs xc7a35tcpg236-1 impl

# 交互模式（出错后可在 Tcl 控制台检查状态）
vivado -mode tcl -source run.tcl
```

### 脚本结构

| 节 | 内容 |
|----|------|
| §0 全局配置 | 器件型号、目录路径、流程开关——**只需修改这一节** |
| §1 工具函数 | `banner` / `elapsed` / `check_timing` 辅助函数 |
| §2 创建输出目录 | `output_products/{synth,impl,reports,bitstream}` |
| §3 仿真（可选） | XSim behavioral，`RUN_SIM=0` 默认关闭 |
| §4 综合 | `read_verilog` → `synth_design` → `opt_design` → 保存检查点 |
| §5 实现 | `place_design` → `phys_opt_design` → `route_design` → `phys_opt_design` → 保存检查点 |
| §6 报告 | timing / utilization / power / DRC / CDC / methodology |
| §7 比特流 | `write_bitstream`，生成 `.bit` + `.bin` |
| §8 导出硬件 | `write_hw_platform`（注释，按需启用供 Vitis 使用） |
| §9 完成汇总 | 打印总耗时与输出目录结构 |

### 流程开关

在 `run.tcl` 顶部 §0 配置节中修改：

```tcl
set RUN_SYNTH  1   ;# 1=运行综合，0=从检查点恢复
set RUN_IMPL   1   ;# 1=运行实现
set RUN_TIMING 1   ;# 1=生成时序报告
set RUN_REPORT 1   ;# 1=生成全套报告
set RUN_BITGEN 1   ;# 1=生成比特流
set RUN_SIM    0   ;# 1=运行 XSim 行为仿真
```

### 检查点恢复机制

脚本在每个主要阶段结束后自动保存 `.dcp` 检查点：

```
output_products/
├── synth/     afifo_synth.dcp   ← opt_design 之后
├── impl/      afifo_impl.dcp    ← 布线 + phys_opt 之后
├── reports/   *.rpt             ← 所有报告
└── bitstream/ afifo.bit/.bin    ← 最终比特流
```

设置 `RUN_SYNTH=0` 时脚本自动从 `synth/afifo_synth.dcp` 恢复，无需重跑综合。

### 实现策略

```tcl
set SYNTH_STRATEGY "Vivado Synthesis Defaults"
set IMPL_STRATEGY  "Performance_ExplorePostRoutePhysOpt"
```

两轮 `phys_opt_design`（布局后 + 布线后）可显著改善时序余量。如时序紧张可改为 `Performance_ExploreWithRemap`。

---

## 仿真

### Icarus Verilog（独立仿真）

```bash
iverilog -o sim.vvp \
    rtl/gray2bin.v \
    rtl/afifo_mem.v \
    rtl/afifo.v \
    sim/tb_afifo.v
vvp sim.vvp
gtkwave tb_afifo.vcd
```

### Vivado XSim（通过 run.tcl）

将 `run.tcl` 中 `RUN_SIM` 置为 `1` 后执行，或在 Vivado Tcl 控制台：

```tcl
set_property top tb_afifo [current_fileset -simset]
launch_simulation -mode behavioral
```

---

## CDC 验证

实现后报告已由 `run.tcl §6` 自动生成，也可手动执行：

```tcl
report_clock_interaction -file clock_interaction.rpt -delay_type min_max
report_cdc               -file cdc_report.rpt        -details
report_timing_summary    -file timing_summary.rpt    -warn_on_violation
```

所有 CDC 路径应显示 **No Issues** 或被 `set_max_delay -datapath_only` 约束覆盖。

---

## 设计注意事项与常见陷阱

### 一、复位（Reset）

**坑：两个时钟域的复位必须分开，且需要去除亚稳态**

异步 FIFO 有两个独立的时钟域，复位信号若直接跨域使用，释放时会产生亚稳态。
正确做法是：每个时钟域有自己的 `rst_n`，若系统只有一个全局复位，需在各域内用 2FF 同步器同步复位的**释放沿**（assert 可以异步，deassert 必须同步）。

```
             全局 rst_n
                 │
        ┌────────┴────────┐
        │                 │
   2FF(wr_clk)       2FF(rd_clk)
        │                 │
   wr_rst_n_sync     rd_rst_n_sync
```

**坑：复位释放顺序不当导致指针错位**

若写域先出复位、读域后出复位（或反之），两域的初始指针值（均为 0）在格雷码比较中仍正确，但若复位期间有写操作发生，读端可能读到脏数据。建议：复位期间门控写使能（`wr_en & ~wr_rst_busy`）。

---

### 二、格雷码指针宽度

**坑：指针位宽必须是 `ADDR_WIDTH + 1`，不能只用 `ADDR_WIDTH`**

额外的 MSB 用于区分"满"和"空"两种状态——两者的低 `ADDR_WIDTH` 位地址相同（均回到同一地址），只有 MSB 不同才能区分绕回。若去掉 MSB，空和满条件将无法区分，产生误判。

```
深度 = 8 (ADDR_WIDTH=3)，指针需 4 bit：
  空: wr_ptr == rd_ptr         → 0000 == 0000 ✓
  满: wr 比 rd 多绕一圈        → 1000 vs 0000（MSB 不同）
  若只用 3 bit: 0000 vs 000 → 无法区分满/空 ✗
```

---

### 三、FIFO 深度必须是 2 的幂

**坑：深度设为非 2 的幂时，格雷码序列不连续，Full/Empty 判断逻辑失效**

Cummings 方法的格雷码 Full/Empty 公式严格依赖于"指针绕回到 0 时恰好差 2^N"的性质。深度若为非 2 的幂（如 12），指针不会在 2^N 边界绕回，格雷码 MSB 翻转时机不对，满标志永远不会正确触发。

若必须使用非 2 的幂深度，需换用基于二进制指针比较的满/空逻辑（放弃格雷码直接比较），并重新设计 CDC 路径。

---

### 四、同步器级数与 MTBF

**坑：只用 1 级同步器，MTBF（平均无故障时间）极低**

2 级同步器在 100–200 MHz 时钟下 MTBF 通常已满足大多数应用（>10^10 年量级）。但在以下场景需要考虑 3 级：

- 时钟频率 > 500 MHz
- 对可靠性有极高要求（航空、医疗）
- 源时钟与目标时钟频率比 > 4:1（数据变化太快，捕获窗口极小）

**坑：同步器 FF 被工具优化合并或重定时（retiming）**

必须在同步器 FF 上添加约束，防止工具将两级 FF 合并为一级，或将逻辑推入同步链：

```tcl
# 方法1：在 XDC 中声明 max_delay（已在 afifo.xdc 中实现）
set_max_delay -datapath_only -from [...] -to [...] <dest_period>

# 方法2：在 RTL 中添加综合属性（防止 FF 被吸收）
(* ASYNC_REG = "TRUE" *) reg [N:0] wr_ptr_gray_s1, wr_ptr_gray_s2;
(* ASYNC_REG = "TRUE" *) reg [N:0] rd_ptr_gray_s1, rd_ptr_gray_s2;
```

`ASYNC_REG = "TRUE"` 是 Xilinx 推荐的必加属性，Vivado 会将这两级 FF 放置在同一 Slice 内，最小化布线延迟，同时在 `report_cdc` 中正确识别该路径。

---

### 五、Full/Empty 标志的保守性

**坑：Full 标志比实际满早触发（保守），Empty 标志比实际空早触发（保守）**

这是 Cummings 方法的固有特性，也是其安全性的来源：

- **Full 保守**：写域看到的读指针是经过 2 拍同步后的"旧"值，实际上读端可能已经多读了若干数据，FIFO 并不真正满。效果：FIFO 实际有效深度略小于标称深度（最多少 2 个位置）。
- **Empty 保守**：读域看到的写指针是同步后的"旧"值，实际写端可能已多写了数据。效果：可能有数据可读但 `rd_empty` 仍为 1（最多延迟 2 拍）。

这两种情况都是**安全**的（不会造成数据损坏），但会略微降低吞吐效率，设计容量时应留有余量。

---

### 六、BRAM 读延迟

**坑：BRAM 为同步读，rd_en 拉高后数据在下一个时钟沿才有效**

本设计使用 Xilinx Block RAM，读操作有 1 拍寄存延迟。调用方必须在 `rd_en` 有效后的**下一个 `rd_clk` 上升沿**才能采样 `rd_data`。

若调用方期望"异步读"（组合输出），需将 `afifo_mem.v` 改为分布式 RAM（`ram_style = "distributed"`），但这会消耗 LUT 资源，且对大深度 FIFO 不合适。

```
时序示意：
rd_clk  ___/‾\_/‾\_/‾\_/‾\_
rd_en   ____/‾‾‾‾‾\______
rd_data ─────────[valid]──   ← 延迟 1 拍
```

---

### 七、写使能/读使能门控

**坑：上层逻辑在 `wr_full=1` 时仍发送 `wr_en`，导致数据丢失（写被静默丢弃）**

本设计内部已做 `wr_en & ~wr_full` 门控，但数据**不会**给出任何错误指示。上层应在握手逻辑中处理背压：

```verilog
// 正确的握手：只在非满时写
assign upstream_ready = ~wr_full;
always @(posedge wr_clk) begin
    if (upstream_valid && upstream_ready) begin
        // 此时写入是安全的
    end
end
```

同理，`rd_en` 在 `rd_empty=1` 时发出会读到上一次的残留数据（BRAM 保持上次输出），不会产生 X 态，但数据无意义。

---

### 八、跨时钟域的 `wr_count` / `rd_count`

**坑：计数值在不同时钟域下并非精确值，不可用于精确流控**

`wr_count = wr_ptr_bin - rd_ptr_bin_sync`，其中 `rd_ptr_bin_sync` 是经过 2 拍同步的旧值，因此 `wr_count` 是一个**下界估计**（实际可用空间 ≥ 显示值）。同理 `rd_count` 是可读数据的**下界估计**。

若需要精确计数（如 DMA 描述符、包边界检测），应在单一时钟域内维护计数器，或使用握手协议传递精确事件。

---

### 九、仿真与综合不一致

**坑：`initial` 块初始化在 FPGA 综合时通常被忽略（BRAM 初始内容为 0 或未定义）**

`afifo_mem.v` 中的 `initial` 块仅用于仿真，综合后 BRAM 的初始内容取决于器件（7 系列上电后为全 0，UltraScale 同样）。若需要特定初始内容，使用 `.coe` 文件或 `$readmemh` 配合 `INIT` 属性。

**坑：仿真中格雷码同步路径时序"太好"，掩盖了实际亚稳态问题**

RTL 仿真中 FF 捕获是理想的（无建立/保持时间），因此同步器在仿真中看起来总是正确的。亚稳态问题只能在门级仿真（带 SDF 反标）或通过静态时序分析（STA）发现，不能依赖 RTL 仿真验证 CDC 安全性。

---

### 十、常见错误速查

| 现象 | 根因 | 排查方法 |
|------|------|---------|
| FIFO 读出数据错误/乱序 | 指针位宽不足；格雷码转换错误 | 检查 `ADDR_WIDTH+1` 位宽；仿真打印指针 |
| `wr_full` 永不拉高 | Full 比较逻辑 MSB 取反错误 | 检查 `{~s2[N:N-1], s2[N-2:0]}` 拼接 |
| `rd_empty` 永不为 0 | 同步器未正确连接；时钟未驱动 | 检查 `wr_ptr_gray_s2` 路径 |
| 时序报告 CDC 路径违例 | 缺少 `ASYNC_REG` 属性或 `set_max_delay` | 补充 XDC 约束，添加 `ASYNC_REG` |
| BRAM 未被推断（用了 LUT RAM）| `ram_style` 属性未生效；深度太小 | 检查综合报告 `ram_style`；深度 < 64 时 Vivado 可能自动选 LUTRAM |
| 复位后第一次读到脏数据 | 复位释放期间写入了无效数据 | 复位期间门控 `wr_en` |
| 吞吐率低于预期 | Full/Empty 保守性导致气泡 | 增大 FIFO 深度；检查上层流控逻辑 |
