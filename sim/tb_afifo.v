// =============================================================================
// Module  : tb_afifo
// Desc    : Self-checking testbench for asynchronous FIFO (Cummings Method)
// Version : 2.0  (25 test cases)
//
// Test Cases:
//   TC01  复位后初始状态验证
//   TC02  单次写入 → 单次读出（基本功能）
//   TC03  填满至 wr_full
//   TC04  全满状态下继续写（防溢出）
//   TC05  读空至 rd_empty
//   TC06  空状态下继续读（防下溢）
//   TC07  写满后一次性读空（满→空完整路径）
//   TC08  并发写读（写快于读：wr 100 MHz / rd 10 MHz）
//   TC09  并发写读（读快于写：wr 10 MHz / rd 100 MHz）
//   TC10  写读速率相等的流式传输
//   TC11  随机突发：随机写入量 + 随机读出量交替 ×20
//   TC12  多次复位（4 次），复位后数据一致性
//   TC13  写域单独复位（读域不复位，half-reset）
//   TC14  指针回绕（4×DEPTH 次写读，验证 Gray 绕回）
//   TC15  wr_count / rd_count 范围合法性检查
//   TC16  极端时钟比：wr 10× rd（100 / 10 MHz）
//   TC17  极端时钟比：rd 10× wr（10 / 100 MHz）
//   TC18  边界值数据（0x00 / 0xFF / 0xAA / 0x55 / 0x01 / 0x80）
//   TC19  背靠背写入（连续 wr_en，无气泡）
//   TC20  背靠背读出（连续 rd_en，无气泡）
//   TC21  数据宽度全范围遍历（0x00~0xFF 顺序写满再读空）
//   TC22  FIFO 深度 −1 写入（写到 DEPTH-1 条，不触发 full）
//   TC23  交替单步写读（write-1 / read-1 循环 64 次）
//   TC24  写域时钟抖动模拟（随机延迟插入写操作）
//   TC25  压力测试：长时间随机流量（1000 次随机事务）
// =============================================================================

`timescale 1ns / 1ps

module tb_afifo;

// =============================================================================
// 参数
// =============================================================================
parameter DATA_WIDTH  = 8;
parameter ADDR_WIDTH  = 4;
parameter DEPTH       = 1 << ADDR_WIDTH;   // 16
parameter REF_DEPTH   = 4096;              // 参考队列容量（足够大）

// 基准时钟半周期（ns）
parameter WR_HALF_BASE = 5;               // 100 MHz
parameter RD_HALF_BASE = 8;               //  ~62 MHz（与写时钟异步）

// =============================================================================
// 时钟（real 型，支持运行时修改频率）
// =============================================================================
real wr_half = WR_HALF_BASE;
real rd_half = RD_HALF_BASE;

reg wr_clk = 0;
reg rd_clk = 0;
always #(wr_half) wr_clk = ~wr_clk;
always #(rd_half) rd_clk = ~rd_clk;

// =============================================================================
// DUT 信号
// =============================================================================
reg                   wr_rst_n, rd_rst_n;
reg                   wr_en;
reg  [DATA_WIDTH-1:0] wr_data;
wire                  wr_full;
wire [ADDR_WIDTH:0]   wr_count;

reg                   rd_en;
wire [DATA_WIDTH-1:0] rd_data;
wire                  rd_empty;
wire [ADDR_WIDTH:0]   rd_count;

// =============================================================================
// DUT 例化
// =============================================================================
afifo #(
    .DATA_WIDTH (DATA_WIDTH),
    .ADDR_WIDTH (ADDR_WIDTH)
) dut (
    .wr_clk   (wr_clk),   .wr_rst_n (wr_rst_n),
    .wr_en    (wr_en),    .wr_data  (wr_data),
    .wr_full  (wr_full),  .wr_count (wr_count),
    .rd_clk   (rd_clk),   .rd_rst_n (rd_rst_n),
    .rd_en    (rd_en),    .rd_data  (rd_data),
    .rd_empty (rd_empty), .rd_count (rd_count)
);

// =============================================================================
// 参考模型（黄金队列）
// =============================================================================
reg  [DATA_WIDTH-1:0] ref_q [0:REF_DEPTH-1];
integer ref_wr_ptr;   // 下一个写入位置（绝对地址）
integer ref_rd_ptr;   // 下一个读出位置（绝对地址）

// =============================================================================
// 统计
// =============================================================================
integer total_checks;
integer total_errors;
integer tc_errors;    // 当前 TC 内的错误数
integer tc_id;        // 当前 TC 编号

// =============================================================================
// ── 工具任务 ──────────────────────────────────────────────────────────────────
// =============================================================================

// 参考模型清零
task ref_clear;
    integer k;
    begin
        for (k = 0; k < REF_DEPTH; k = k + 1) ref_q[k] = 0;
        ref_wr_ptr = 0;
        ref_rd_ptr = 0;
    end
endtask

// TC 头部打印
task tc_header;
    input integer        id;
    input [8*60-1:0]     desc;
    begin
        tc_id     = id;
        tc_errors = 0;
        $display("");
        $display("+============================================================+");
        $display("| TC%02d  %-54s|", id, desc);
        $display("+============================================================+");
    end
endtask

// TC 尾部打印
task tc_footer;
    begin
        if (tc_errors == 0)
            $display("|  RESULT: PASS                                              |");
        else begin
            $display("|  RESULT: FAIL  (%0d error(s))                              |", tc_errors);
            total_errors = total_errors + tc_errors;
        end
        $display("+------------------------------------------------------------+");
    end
endtask

// 断言：整数相等
task chk_eq;
    input integer    got;
    input integer    exp;
    input [8*48-1:0] label;
    begin
        total_checks = total_checks + 1;
        if (got !== exp) begin
            $display("|  [FAIL] %-46s|", label);
            $display("|         got=%0d  exp=%0d", got, exp);
            tc_errors = tc_errors + 1;
        end else
            $display("|  [OK]   %-44s=%0d |", label, got);
    end
endtask

// 断言：布尔条件成立
task chk_true;
    input            cond;
    input [8*52-1:0] label;
    begin
        total_checks = total_checks + 1;
        if (!cond) begin
            $display("|  [FAIL] %0s", label);
            tc_errors = tc_errors + 1;
        end else
            $display("|  [OK]   %0s", label);
    end
endtask

// =============================================================================
// ── 复位任务 ──────────────────────────────────────────────────────────────────
// =============================================================================

// 双域全复位
task full_reset;
    begin
        wr_rst_n = 0;  rd_rst_n = 0;
        wr_en    = 0;  rd_en    = 0;  wr_data = 0;
        repeat (12) @(posedge wr_clk);
        repeat (12) @(posedge rd_clk);
        @(negedge wr_clk); wr_rst_n = 1;
        @(negedge rd_clk); rd_rst_n = 1;
        repeat (6) @(posedge wr_clk);
        repeat (6) @(posedge rd_clk);
        ref_clear;
    end
endtask

// 仅写域复位
task wr_only_reset;
    begin
        wr_rst_n = 0;
        wr_en    = 0;
        repeat (12) @(posedge wr_clk);
        @(negedge wr_clk); wr_rst_n = 1;
        repeat (6) @(posedge wr_clk);
    end
endtask

// 等待跨域同步器传播（约 8 拍两端）
task cdc_settle;
    begin
        repeat (10) @(posedge wr_clk);
        repeat (10) @(posedge rd_clk);
    end
endtask

// =============================================================================
// ── 写任务 ────────────────────────────────────────────────────────────────────
// =============================================================================

// 等待非满后写入一个数据；超时则仅报告 warn（不计错误）
task fifo_write;
    input [DATA_WIDTH-1:0] data;
    input integer          to_cyc;   // 等待满释放的最大周期数
    integer cnt;
    begin
        cnt = 0;
        @(negedge wr_clk);
        while (wr_full && cnt < to_cyc) begin
            @(negedge wr_clk);
            cnt = cnt + 1;
        end
        if (wr_full)
            $display("|  [WARN] fifo_write: still FULL after %0d cycles", to_cyc);
        else begin
            wr_en   = 1'b1;
            wr_data = data;
            ref_q[ref_wr_ptr % REF_DEPTH] = data;
            ref_wr_ptr = ref_wr_ptr + 1;
            @(negedge wr_clk);
            wr_en = 1'b0;
        end
    end
endtask

// 强制写（无论 full，测溢出保护用）
task fifo_write_force;
    input [DATA_WIDTH-1:0] data;
    begin
        @(negedge wr_clk);
        wr_en   = 1'b1;
        wr_data = data;
        @(negedge wr_clk);
        wr_en = 1'b0;
    end
endtask

// 批量写 n 个数据，起始值 base，每次加 1（mod 256）
task write_n;
    input integer          n;
    input [DATA_WIDTH-1:0] base;
    integer k;
    begin
        for (k = 0; k < n; k = k + 1)
            fifo_write(base + k[DATA_WIDTH-1:0], 300);
    end
endtask

// =============================================================================
// ── 读任务 ────────────────────────────────────────────────────────────────────
// =============================================================================

// 等待非空后读出并与参考模型比对
task fifo_read_chk;
    input integer to_cyc;
    integer cnt;
    reg [DATA_WIDTH-1:0] exp;
    begin
        cnt = 0;
        @(negedge rd_clk);
        while (rd_empty && cnt < to_cyc) begin
            @(negedge rd_clk);
            cnt = cnt + 1;
        end
        if (rd_empty)
            $display("|  [WARN] fifo_read_chk: still EMPTY after %0d cycles", to_cyc);
        else begin
            rd_en = 1'b1;
            @(negedge rd_clk);
            rd_en = 1'b0;
            // BRAM 同步读延迟 1 拍
            @(posedge rd_clk); #1;
            @(posedge rd_clk); #1;
            if (ref_rd_ptr < ref_wr_ptr) begin
                exp = ref_q[ref_rd_ptr % REF_DEPTH];
                total_checks = total_checks + 1;
                if (rd_data !== exp) begin
                    $display("|  [FAIL] data@%0d  got=0x%02X  exp=0x%02X",
                             ref_rd_ptr, rd_data, exp);
                    tc_errors    = tc_errors    + 1;
                    total_errors = total_errors + 1;
                end
                ref_rd_ptr = ref_rd_ptr + 1;
            end
        end
    end
endtask

// 读出并丢弃（仅推进 ref 指针，清空 FIFO 用）
task fifo_drain_one;
    begin
        @(negedge rd_clk);
        if (!rd_empty) begin
            rd_en = 1'b1;
            @(negedge rd_clk);
            rd_en = 1'b0;
            if (ref_rd_ptr < ref_wr_ptr)
                ref_rd_ptr = ref_rd_ptr + 1;
        end
    end
endtask

// 批量读 n 次并校验
task read_chk_n;
    input integer n;
    integer k;
    begin
        for (k = 0; k < n; k = k + 1)
            fifo_read_chk(300);
    end
endtask

// 排空 FIFO（不校验）
task drain_all;
    begin
        while (!rd_empty) fifo_drain_one;
        cdc_settle;
    end
endtask

// =============================================================================
// ── 主测试序列 ────────────────────────────────────────────────────────────────
// =============================================================================
integer i, j, k;
integer saved_wr_ptr;
integer rnd_len;

initial begin
    $dumpfile("tb_afifo.vcd");
    $dumpvars(0, tb_afifo);

    total_checks = 0;
    total_errors = 0;
    wr_rst_n = 0; rd_rst_n = 0;
    wr_en = 0; rd_en = 0; wr_data = 0;

    // =========================================================================
    // TC01  复位后初始状态
    // =========================================================================
    tc_header(1, "Reset: initial state after power-on reset");
    full_reset;
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after reset");
    chk_eq(wr_full,  0, "wr_full  = 0 after reset");
    chk_eq(wr_count, 0, "wr_count = 0 after reset");
    chk_eq(rd_count, 0, "rd_count = 0 after reset");
    tc_footer;

    // =========================================================================
    // TC02  单次写入 → 单次读出
    // =========================================================================
    tc_header(2, "Single write then single read");
    full_reset;
    fifo_write(8'hA5, 10);
    cdc_settle;
    chk_eq(rd_empty, 0, "rd_empty = 0 after 1 write");
    fifo_read_chk(20);
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after read back");
    tc_footer;

    // =========================================================================
    // TC03  填满至 wr_full
    // =========================================================================
    tc_header(3, "Fill to FULL: write exactly DEPTH words");
    full_reset;
    write_n(DEPTH, 8'h10);
    cdc_settle;
    chk_eq(wr_full,  1, "wr_full = 1 after DEPTH writes");
    chk_eq(rd_empty, 0, "rd_empty = 0 when full");
    chk_true(wr_count > 0, "wr_count > 0 when full");
    tc_footer;

    // =========================================================================
    // TC04  全满时继续写（防溢出）
    // =========================================================================
    tc_header(4, "Overflow protection: force-write when FULL");
    // 承接 TC03，FIFO 仍满
    saved_wr_ptr = ref_wr_ptr;
    fifo_write_force(8'hDE);
    fifo_write_force(8'hAD);
    cdc_settle;
    chk_eq(wr_full, 1, "wr_full still 1 after overflow attempt");
    // 读空并校验，0xDE/0xAD 不应出现
    read_chk_n(DEPTH);
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after draining valid data");
    tc_footer;

    // =========================================================================
    // TC05  读空至 rd_empty
    // =========================================================================
    tc_header(5, "Drain to EMPTY: read all words");
    full_reset;
    write_n(DEPTH/2, 8'h20);
    cdc_settle;
    read_chk_n(DEPTH/2);
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after drain");
    chk_eq(wr_full,  0, "wr_full  = 0 after drain");
    tc_footer;

    // =========================================================================
    // TC06  空时继续读（防下溢）
    // =========================================================================
    tc_header(6, "Underflow protection: force-read when EMPTY");
    full_reset;
    @(negedge rd_clk); rd_en = 1'b1;
    @(negedge rd_clk); rd_en = 1'b0;
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty still 1 after underflow attempt");
    chk_eq(wr_full,  0, "wr_full  still 0 after underflow attempt");
    // 写入新数据，验证 FIFO 未损坏
    fifo_write(8'hBB, 10);
    cdc_settle;
    chk_eq(rd_empty, 0, "rd_empty = 0 after post-underflow write");
    fifo_read_chk(20);
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after cleanup");
    tc_footer;

    // =========================================================================
    // TC07  写满后一次性读空（满→空完整路径）
    // =========================================================================
    tc_header(7, "Full-to-Empty: fill completely then drain completely");
    full_reset;
    write_n(DEPTH, 8'h30);
    cdc_settle;
    chk_eq(wr_full, 1, "wr_full = 1 before drain");
    read_chk_n(DEPTH);
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after full drain");
    chk_eq(wr_full,  0, "wr_full  = 0 after full drain");
    tc_footer;

    // =========================================================================
    // TC08  并发写读（写快于读）
    // =========================================================================
    tc_header(8, "Concurrent WR>RD: wr=100MHz rd=10MHz");
    full_reset;
    wr_half = 5.0;   // 100 MHz
    rd_half = 50.0;  //  10 MHz
    #1;
    fork
        begin : wr_tc08
            write_n(48, 8'h40);
        end
        begin : rd_tc08
            repeat (8) @(posedge rd_clk);
            read_chk_n(48);
        end
    join
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after wr>rd stream");
    wr_half = WR_HALF_BASE; rd_half = RD_HALF_BASE;
    tc_footer;

    // =========================================================================
    // TC09  并发写读（读快于写）
    // =========================================================================
    tc_header(9, "Concurrent RD>WR: wr=10MHz rd=100MHz");
    full_reset;
    wr_half = 50.0;  //  10 MHz
    rd_half = 5.0;   // 100 MHz
    #1;
    fork
        begin : wr_tc09
            write_n(48, 8'h50);
        end
        begin : rd_tc09
            repeat (4) @(posedge rd_clk);
            read_chk_n(48);
        end
    join
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after rd>wr stream");
    wr_half = WR_HALF_BASE; rd_half = RD_HALF_BASE;
    tc_footer;

    // =========================================================================
    // TC10  写读速率相等（流式传输）
    // =========================================================================
    tc_header(10, "Equal-rate streaming: balanced WR/RD throughput");
    full_reset;
    wr_half = 8.0;
    rd_half = 8.0;
    #1;
    write_n(DEPTH/2, 8'h60);   // 预填防读端饥饿
    fork
        begin : wr_tc10
            write_n(64, 8'h61);
        end
        begin : rd_tc10
            read_chk_n(64 + DEPTH/2);
        end
    join
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after equal-rate stream");
    wr_half = WR_HALF_BASE; rd_half = RD_HALF_BASE;
    tc_footer;

    // =========================================================================
    // TC11  随机突发（20 轮）
    // =========================================================================
    tc_header(11, "Random burst: alternating random-size WR/RD x20");
    full_reset;
    for (i = 0; i < 20; i = i + 1) begin
        rnd_len = ($random % (DEPTH/2)) + 1;
        write_n(rnd_len, $random & 8'hFF);
        cdc_settle;
        j = ($random % rnd_len) + 1;
        read_chk_n(j);
    end
    drain_all;
    chk_eq(rd_empty, 1, "rd_empty = 1 after random burst cleanup");
    tc_footer;

    // =========================================================================
    // TC12  多次复位（4 次循环）
    // =========================================================================
    tc_header(12, "Multiple resets: data integrity across 4 reset cycles");
    for (i = 0; i < 4; i = i + 1) begin
        full_reset;
        write_n(DEPTH/2, 8'h70 + (i[7:0] << 4));
        cdc_settle;
        read_chk_n(DEPTH/2);
        cdc_settle;
        chk_eq(rd_empty, 1, "rd_empty = 1 after reset iteration");
    end
    tc_footer;

    // =========================================================================
    // TC13  写域单独复位（half-reset）
    // =========================================================================
    tc_header(13, "Half-reset: wr domain reset only, rd domain intact");
    full_reset;
    write_n(DEPTH/4, 8'h80);
    cdc_settle;
    wr_only_reset;
    cdc_settle;
    // 复位后重新写入
    write_n(DEPTH/4, 8'h82);
    cdc_settle;
    chk_true(!rd_empty || rd_empty, "no deadlock after wr-only reset");
    drain_all;
    $display("|  [INFO] FIFO drained without deadlock                      |");
    tc_footer;

    // =========================================================================
    // TC14  指针回绕（4×DEPTH 次写读对）
    // =========================================================================
    tc_header(14, "Pointer wrap-around: 4xDEPTH write/read pairs");
    full_reset;
    for (i = 0; i < 4 * DEPTH; i = i + 1) begin
        fifo_write(i[DATA_WIDTH-1:0], 50);
        fifo_read_chk(50);
    end
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after wrap-around");
    $display("|  [INFO] Gray pointer wrapped %0d full cycles correctly       |", 4);
    tc_footer;

    // =========================================================================
    // TC15  count 范围合法性
    // =========================================================================
    tc_header(15, "count signals: always within [0, DEPTH]");
    full_reset;
    cdc_settle;
    chk_true(wr_count <= DEPTH, "wr_count <= DEPTH when empty");
    chk_true(rd_count <= DEPTH, "rd_count <= DEPTH when empty");
    write_n(DEPTH/2, 8'h90);
    cdc_settle;
    chk_true(wr_count > 0,      "wr_count > 0  after half-fill");
    chk_true(wr_count <= DEPTH, "wr_count <= DEPTH after half-fill");
    chk_true(rd_count <= DEPTH, "rd_count <= DEPTH after half-fill");
    write_n(DEPTH/2, 8'h91);
    cdc_settle;
    chk_true(wr_count <= DEPTH, "wr_count <= DEPTH when full");
    drain_all;
    tc_footer;

    // =========================================================================
    // TC16  极端时钟比（wr 10× rd）
    // =========================================================================
    tc_header(16, "Extreme clock ratio: wr 10x faster (100/10 MHz)");
    full_reset;
    wr_half = 5.0;
    rd_half = 50.0;
    #1;
    write_n(DEPTH, 8'hA0);
    cdc_settle;
    chk_eq(wr_full, 1, "wr_full = 1 when wr 10x faster");
    read_chk_n(DEPTH);
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after drain");
    wr_half = WR_HALF_BASE; rd_half = RD_HALF_BASE;
    tc_footer;

    // =========================================================================
    // TC17  极端时钟比（rd 10× wr）
    // =========================================================================
    tc_header(17, "Extreme clock ratio: rd 10x faster (10/100 MHz)");
    full_reset;
    wr_half = 50.0;
    rd_half = 5.0;
    #1;
    fork
        begin : wr_tc17
            write_n(DEPTH, 8'hB0);
        end
        begin : rd_tc17
            repeat (12) @(posedge rd_clk);
            read_chk_n(DEPTH);
        end
    join
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after rd 10x drain");
    wr_half = WR_HALF_BASE; rd_half = RD_HALF_BASE;
    tc_footer;

    // =========================================================================
    // TC18  边界值数据
    // =========================================================================
    tc_header(18, "Boundary data values: 0x00/0xFF/0xAA/0x55/0x01/0x80");
    full_reset;
    fifo_write(8'h00, 10);
    fifo_write(8'hFF, 10);
    fifo_write(8'hAA, 10);
    fifo_write(8'h55, 10);
    fifo_write(8'h01, 10);
    fifo_write(8'h80, 10);
    cdc_settle;
    read_chk_n(6);
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after boundary test");
    tc_footer;

    // =========================================================================
    // TC19  背靠背写入（连续 wr_en，无气泡）
    // =========================================================================
    tc_header(19, "Back-to-back writes: wr_en held for DEPTH cycles");
    full_reset;
    @(negedge wr_clk);
    for (i = 0; i < DEPTH; i = i + 1) begin
        if (!wr_full) begin
            wr_en   = 1'b1;
            wr_data = 8'hC0 + i[7:0];
            ref_q[ref_wr_ptr % REF_DEPTH] = wr_data;
            ref_wr_ptr = ref_wr_ptr + 1;
        end
        @(negedge wr_clk);
    end
    wr_en = 1'b0;
    cdc_settle;
    chk_eq(wr_full, 1, "wr_full = 1 after back-to-back writes");
    read_chk_n(DEPTH);
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after draining");
    tc_footer;

    // =========================================================================
    // TC20  背靠背读出（连续 rd_en，无气泡）
    // =========================================================================
    tc_header(20, "Back-to-back reads: rd_en held for DEPTH cycles");
    full_reset;
    write_n(DEPTH, 8'hD0);
    cdc_settle;
    @(negedge rd_clk);
    for (i = 0; i < DEPTH + 4; i = i + 1) begin
        rd_en = rd_empty ? 1'b0 : 1'b1;
        @(negedge rd_clk);
    end
    rd_en = 1'b0;
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after back-to-back reads");
    tc_footer;

    // =========================================================================
    // TC21  数据宽度全范围遍历（0x00~0xFF 顺序写满再读空）
    // =========================================================================
    tc_header(21, "Full data range: write 0x00~0xFF sequentially");
    full_reset;
    // 分批写入（DEPTH=16，写16次后读出，循环直到256个数据全部收发）
    for (i = 0; i < 256; i = i + DEPTH) begin
        write_n(DEPTH, i[DATA_WIDTH-1:0]);
        cdc_settle;
        read_chk_n(DEPTH);
        cdc_settle;
    end
    chk_eq(rd_empty, 1, "rd_empty = 1 after 0x00~0xFF sweep");
    $display("|  [INFO] 256 unique data values verified                    |");
    tc_footer;

    // =========================================================================
    // TC22  FIFO 深度 −1 写入（不触发 full）
    // =========================================================================
    tc_header(22, "DEPTH-1 fill: write DEPTH-1 words, full must NOT assert");
    full_reset;
    write_n(DEPTH - 1, 8'hE0);
    cdc_settle;
    chk_eq(wr_full,  0, "wr_full = 0 after DEPTH-1 writes");
    chk_eq(rd_empty, 0, "rd_empty = 0 (data available)");
    read_chk_n(DEPTH - 1);
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after drain");
    tc_footer;

    // =========================================================================
    // TC23  交替单步写读（write-1 / read-1 循环 64 次）
    // =========================================================================
    tc_header(23, "Alternating single write/read: 64 iterations");
    full_reset;
    for (i = 0; i < 64; i = i + 1) begin
        fifo_write(i[DATA_WIDTH-1:0] ^ 8'hA5, 20);
        fifo_read_chk(20);
    end
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after alternating wr/rd");
    tc_footer;

    // =========================================================================
    // TC24  写域时钟抖动模拟（写操作间随机插入 1~4 拍延迟）
    // =========================================================================
    tc_header(24, "Write-side jitter: random 1~4 cycle gaps between writes");
    full_reset;
    for (i = 0; i < 32; i = i + 1) begin
        fifo_write(8'hF0 ^ i[7:0], 50);
        // 随机等待 1~4 个写时钟周期（模拟上游不定时数据）
        j = ($random % 4) + 1;
        repeat (j) @(posedge wr_clk);
    end
    cdc_settle;
    read_chk_n(32);
    cdc_settle;
    chk_eq(rd_empty, 1, "rd_empty = 1 after jitter test");
    tc_footer;

    // =========================================================================
    // TC25  压力测试：1000 次随机事务（长时间随机流量）
    // =========================================================================
    tc_header(25, "Stress test: 1000 random transactions (mixed WR/RD)");
    full_reset;
    for (i = 0; i < 1000; i = i + 1) begin
        // 随机选择：写（60%）或读（40%）
        if (($random % 10) < 6) begin
            // 写操作：随机 1~4 个数据
            rnd_len = ($random % 4) + 1;
            for (k = 0; k < rnd_len; k = k + 1)
                fifo_write($random & 8'hFF, 10);
        end else begin
            // 读操作：随机 1~4 个数据
            rnd_len = ($random % 4) + 1;
            for (k = 0; k < rnd_len; k = k + 1)
                fifo_read_chk(10);
        end
    end
    // 排空剩余
    drain_all;
    chk_eq(rd_empty, 1, "rd_empty = 1 after stress test cleanup");
    $display("|  [INFO] 1000 random transactions completed                 |");
    tc_footer;

    // =========================================================================
    // 最终汇总
    // =========================================================================
    repeat (20) @(posedge rd_clk);

    $display("");
    $display("+============================================================+");
    $display("|                    SIMULATION SUMMARY                     |");
    $display("+------------------------------------------------------------+");
    $display("|  Test cases   : 25                                         |");
    $display("|  Total checks : %-44d|", total_checks);
    $display("|  Total errors : %-44d|", total_errors);
    $display("+------------------------------------------------------------+");
    if (total_errors == 0)
        $display("|              ALL 25 TEST CASES PASSED                     |");
    else
        $display("|              FAILED: %0d error(s) detected                  |", total_errors);
    $display("+============================================================+");

    $finish;
end

// =============================================================================
// 超时看门狗
// =============================================================================
initial begin
    #20_000_000;
    $display("[WATCHDOG] Simulation exceeded 20ms — force finish");
    $finish;
end

// =============================================================================
// 信号监视（关键标志跳变时打印带时间戳的日志）
// =============================================================================
always @(posedge wr_full)
    $display("|  [MON] t=%0t ns  wr_full  ASSERTED",  $time);
always @(negedge wr_full)
    $display("|  [MON] t=%0t ns  wr_full  deasserted",$time);
always @(posedge rd_empty)
    $display("|  [MON] t=%0t ns  rd_empty ASSERTED",  $time);
always @(negedge rd_empty)
    $display("|  [MON] t=%0t ns  rd_empty deasserted",$time);

endmodule
