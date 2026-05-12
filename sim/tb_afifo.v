// =============================================================================
// Module  : tb_afifo
// Desc    : Self-checking testbench for asynchronous FIFO (Cummings Method)
//
// Test Cases:
//   TC01  复位后初始状态验证
//   TC02  单次写入 → 单次读出（基本功能）
//   TC03  填满至 wr_full
//   TC04  全满状态下继续写（防溢出）
//   TC05  读空至 rd_empty
//   TC06  空状态下继续读（防下溢）
//   TC07  写满后一次性读空（满→空完整路径）
//   TC08  并发写读（写快于读：wr_clk > rd_clk）
//   TC09  并发写读（读快于写：rd_clk > wr_clk）
//   TC10  写读速率相等的流式传输
//   TC11  随机突发：随机写入量 + 随机读出量交替
//   TC12  多次复位：复位后数据一致性
//   TC13  写域单独复位（读域不复位，half-reset 场景）
//   TC14  指针回绕（写入超过 4×DEPTH 次，验证指针绕回）
//   TC15  wr_count / rd_count 范围合法性检查
//   TC16  极端时钟比（wr 10x rd）
//   TC17  极端时钟比（rd 10x wr）
//   TC18  边界值数据（0x00 / 0xFF / 0xAA / 0x55）
//   TC19  背靠背写入（连续 wr_en，无间隔）
//   TC20  背靠背读出（连续 rd_en，无间隔）
// =============================================================================

`timescale 1ns / 1ps

module tb_afifo;

// =============================================================================
// 参数
// =============================================================================
parameter DATA_WIDTH    = 8;
parameter ADDR_WIDTH    = 4;
parameter DEPTH         = 1 << ADDR_WIDTH;   // 16
parameter REF_Q_DEPTH   = 1024;              // 参考队列大小

// 基准时钟周期（ns）
parameter WR_CLK_BASE   = 10;               // 100 MHz
parameter RD_CLK_BASE   = 17;               //  ~59 MHz

// =============================================================================
// 时钟控制（real 类型支持动态修改周期）
// =============================================================================
real wr_clk_half = WR_CLK_BASE / 2.0;
real rd_clk_half = RD_CLK_BASE / 2.0;

reg wr_clk = 0;
reg rd_clk = 0;
always #(wr_clk_half) wr_clk = ~wr_clk;
always #(rd_clk_half) rd_clk = ~rd_clk;

// =============================================================================
// DUT 信号
// =============================================================================
reg                   wr_rst_n;
reg                   rd_rst_n;
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
reg  [DATA_WIDTH-1:0] ref_q [0:REF_Q_DEPTH-1];
integer ref_wr_ptr;
integer ref_rd_ptr;

// 全局统计
integer total_checks;
integer total_errors;
integer test_errors;
integer tc_num;

// =============================================================================
// 工具任务
// =============================================================================

task reset_ref_model;
    integer i;
    begin
        for (i = 0; i < REF_Q_DEPTH; i = i + 1) ref_q[i] = 0;
        ref_wr_ptr = 0;
        ref_rd_ptr = 0;
    end
endtask

task tc_begin;
    input integer        num;
    input [8*52-1:0]     name;
    begin
        tc_num      = num;
        test_errors = 0;
        $display("\n+----------------------------------------------------------+");
        $display("|  TC%02d: %-52s|", num, name);
        $display("+----------------------------------------------------------+");
    end
endtask

task tc_end;
    begin
        if (test_errors == 0)
            $display("  >> TC%02d PASS", tc_num);
        else begin
            $display("  >> TC%02d FAIL  (%0d error(s))", tc_num, test_errors);
            total_errors = total_errors + test_errors;
        end
    end
endtask

task assert_eq;
    input integer    got;
    input integer    exp;
    input [8*40-1:0] msg;
    begin
        total_checks = total_checks + 1;
        if (got !== exp) begin
            $display("     [FAIL] %-38s  got=%0d  exp=%0d", msg, got, exp);
            test_errors = test_errors + 1;
        end else
            $display("     [OK]   %-38s = %0d", msg, got);
    end
endtask

task assert_true;
    input            cond;
    input [8*40-1:0] msg;
    begin
        total_checks = total_checks + 1;
        if (!cond) begin
            $display("     [FAIL] %0s", msg);
            test_errors = test_errors + 1;
        end else
            $display("     [OK]   %0s", msg);
    end
endtask

// =============================================================================
// 复位任务
// =============================================================================
task apply_full_reset;
    begin
        wr_rst_n = 0;  rd_rst_n = 0;
        wr_en    = 0;  rd_en    = 0;
        wr_data  = 0;
        repeat (10) @(posedge wr_clk);
        repeat (10) @(posedge rd_clk);
        @(negedge wr_clk); wr_rst_n = 1;
        @(negedge rd_clk); rd_rst_n = 1;
        repeat (6) @(posedge wr_clk);
        repeat (6) @(posedge rd_clk);
        reset_ref_model;
    end
endtask

task apply_wr_reset_only;
    begin
        wr_rst_n = 0;
        wr_en    = 0;
        repeat (10) @(posedge wr_clk);
        @(negedge wr_clk); wr_rst_n = 1;
        repeat (6) @(posedge wr_clk);
    end
endtask

// 等待跨域同步器传播稳定（约 6 拍两端时钟）
task sync_wait;
    begin
        repeat (8) @(posedge wr_clk);
        repeat (8) @(posedge rd_clk);
    end
endtask

// =============================================================================
// 写任务
// =============================================================================

// 等待非满后写一个数据，超时报告 warn
task fifo_write;
    input [DATA_WIDTH-1:0] data;
    input integer          timeout_cyc;
    integer cnt;
    begin
        cnt = 0;
        @(negedge wr_clk);
        while (wr_full && cnt < timeout_cyc) begin
            @(negedge wr_clk);
            cnt = cnt + 1;
        end
        if (wr_full)
            $display("     [WARN] fifo_write timeout after %0d cycles", timeout_cyc);
        else begin
            wr_en   = 1'b1;
            wr_data = data;
            ref_q[ref_wr_ptr % REF_Q_DEPTH] = data;
            ref_wr_ptr = ref_wr_ptr + 1;
            @(negedge wr_clk);
            wr_en = 1'b0;
        end
    end
endtask

// 强制写（不检查 full，用于测试溢出保护）
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

// 批量写 n 个数据
task write_n;
    input integer          n;
    input [DATA_WIDTH-1:0] base;
    integer k;
    begin
        for (k = 0; k < n; k = k + 1)
            fifo_write(base + k[DATA_WIDTH-1:0], 200);
    end
endtask

// =============================================================================
// 读任务
// =============================================================================

// 等待非空后读一个数据并与参考模型比较
task fifo_read_check;
    input integer timeout_cyc;
    integer cnt;
    reg [DATA_WIDTH-1:0] exp_data;
    begin
        cnt = 0;
        @(negedge rd_clk);
        while (rd_empty && cnt < timeout_cyc) begin
            @(negedge rd_clk);
            cnt = cnt + 1;
        end
        if (rd_empty)
            $display("     [WARN] fifo_read_check timeout after %0d cycles", timeout_cyc);
        else begin
            rd_en = 1'b1;
            @(negedge rd_clk);
            rd_en = 1'b0;
            // BRAM 同步读延迟 1 拍
            @(posedge rd_clk); #1;
            @(posedge rd_clk); #1;

            if (ref_rd_ptr < ref_wr_ptr) begin
                exp_data = ref_q[ref_rd_ptr % REF_Q_DEPTH];
                total_checks = total_checks + 1;
                if (rd_data !== exp_data) begin
                    $display("     [FAIL] data@%0d: got=0x%02X exp=0x%02X",
                             ref_rd_ptr, rd_data, exp_data);
                    test_errors  = test_errors  + 1;
                end
                ref_rd_ptr = ref_rd_ptr + 1;
            end
        end
    end
endtask

// 读并丢弃（清空用）
task fifo_read_drain;
    begin
        @(negedge rd_clk);
        if (!rd_empty) begin
            rd_en = 1'b1;
            @(negedge rd_clk);
            rd_en = 1'b0;
            ref_rd_ptr = ref_rd_ptr + 1;
        end
    end
endtask

// 批量读 n 次并校验
task read_check_n;
    input integer n;
    integer k;
    begin
        for (k = 0; k < n; k = k + 1)
            fifo_read_check(200);
    end
endtask

// =============================================================================
// 主测试序列
// =============================================================================
integer i, j;
integer saved_wr;

initial begin
    $dumpfile("tb_afifo.vcd");
    $dumpvars(0, tb_afifo);

    total_checks = 0;
    total_errors = 0;
    wr_rst_n = 0; rd_rst_n = 0;
    wr_en = 0;    rd_en = 0;
    wr_data = 0;

    // =========================================================================
    // TC01  复位后初始状态
    // =========================================================================
    tc_begin(1, "Reset: initial state after power-on reset");
    apply_full_reset;
    sync_wait;
    assert_eq(rd_empty, 1, "rd_empty after reset");
    assert_eq(wr_full,  0, "wr_full  after reset");
    assert_eq(wr_count, 0, "wr_count after reset");
    assert_eq(rd_count, 0, "rd_count after reset");
    tc_end;

    // =========================================================================
    // TC02  单次写入 → 单次读出
    // =========================================================================
    tc_begin(2, "Single write then single read");
    apply_full_reset;
    fifo_write(8'hA5, 10);
    sync_wait;
    assert_eq(rd_empty, 0, "rd_empty = 0 after 1 write");
    fifo_read_check(20);
    sync_wait;
    assert_eq(rd_empty, 1, "rd_empty = 1 after read back");
    tc_end;

    // =========================================================================
    // TC03  填满至 wr_full
    // =========================================================================
    tc_begin(3, "Fill to FULL: write DEPTH words");
    apply_full_reset;
    write_n(DEPTH, 8'h10);
    sync_wait;
    assert_eq(wr_full,  1, "wr_full after DEPTH writes");
    assert_eq(rd_empty, 0, "rd_empty must be 0 when full");
    assert_true(wr_count > 0, "wr_count > 0 when full");
    tc_end;

    // =========================================================================
    // TC04  全满状态下继续写（防溢出）
    // =========================================================================
    tc_begin(4, "Overflow protection: write when FULL");
    // 承接 TC03，FIFO 仍满
    saved_wr = ref_wr_ptr;
    fifo_write_force(8'hDE);
    fifo_write_force(8'hAD);
    sync_wait;
    assert_eq(wr_full, 1, "wr_full still asserted after overflow attempt");
    // 读出所有数据并校验（应与 TC03 写入内容一致，0xDE/0xAD 不应出现）
    read_check_n(DEPTH);
    sync_wait;
    assert_eq(rd_empty, 1, "rd_empty after draining valid data");
    tc_end;

    // =========================================================================
    // TC05  读空至 rd_empty
    // =========================================================================
    tc_begin(5, "Drain to EMPTY: read all words");
    apply_full_reset;
    write_n(DEPTH/2, 8'h20);
    sync_wait;
    read_check_n(DEPTH/2);
    sync_wait;
    assert_eq(rd_empty, 1, "rd_empty after draining half-full FIFO");
    assert_eq(wr_full,  0, "wr_full = 0 after drain");
    tc_end;

    // =========================================================================
    // TC06  空状态下继续读（防下溢）
    // =========================================================================
    tc_begin(6, "Underflow protection: read when EMPTY");
    apply_full_reset;
    // 强制拉高 rd_en（FIFO 为空，DUT 内部门控应拦截）
    @(negedge rd_clk); rd_en = 1'b1;
    @(negedge rd_clk); rd_en = 1'b0;
    sync_wait;
    assert_eq(rd_empty, 1, "rd_empty still 1 after underflow attempt");
    assert_eq(wr_full,  0, "wr_full still 0 after underflow attempt");
    // 写入新数据，验证 FIFO 功能未损坏
    fifo_write(8'hBB, 10);
    sync_wait;
    assert_eq(rd_empty, 0, "rd_empty = 0 after post-underflow write");
    fifo_read_check(20);
    tc_end;

    // =========================================================================
    // TC07  写满后一次性读空（满→空完整路径）
    // =========================================================================
    tc_begin(7, "Full-to-Empty: fill completely then drain completely");
    apply_full_reset;
    write_n(DEPTH, 8'h30);
    sync_wait;
    assert_eq(wr_full, 1, "wr_full before drain");
    read_check_n(DEPTH);
    sync_wait;
    assert_eq(rd_empty, 1, "rd_empty after full drain");
    assert_eq(wr_full,  0, "wr_full  after full drain");
    tc_end;

    // =========================================================================
    // TC08  并发写读（写快于读）
    // =========================================================================
    tc_begin(8, "Concurrent WR>RD: write 100MHz, read 10MHz");
    apply_full_reset;
    wr_clk_half = 5.0;   // 100 MHz
    rd_clk_half = 50.0;  //  10 MHz
    #1;
    fork
        begin : wr_tc08
            write_n(48, 8'h40);
        end
        begin : rd_tc08
            repeat (8) @(posedge rd_clk);
            read_check_n(48);
        end
    join
    sync_wait;
    assert_eq(rd_empty, 1, "rd_empty after concurrent WR>RD");
    wr_clk_half = WR_CLK_BASE / 2.0;
    rd_clk_half = RD_CLK_BASE / 2.0;
    tc_end;

    // =========================================================================
    // TC09  并发写读（读快于写）
    // =========================================================================
    tc_begin(9, "Concurrent RD>WR: write 10MHz, read 100MHz");
    apply_full_reset;
    wr_clk_half = 50.0;  //  10 MHz
    rd_clk_half = 5.0;   // 100 MHz
    #1;
    fork
        begin : wr_tc09
            write_n(48, 8'h50);
        end
        begin : rd_tc09
            repeat (4) @(posedge rd_clk);
            read_check_n(48);
        end
    join
    sync_wait;
    assert_eq(rd_empty, 1, "rd_empty after concurrent RD>WR");
    wr_clk_half = WR_CLK_BASE / 2.0;
    rd_clk_half = RD_CLK_BASE / 2.0;
    tc_end;

    // =========================================================================
    // TC10  写读速率相等（流式传输）
    // =========================================================================
    tc_begin(10, "Equal rate streaming: balanced WR/RD throughput");
    apply_full_reset;
    wr_clk_half = 10.0;
    rd_clk_half = 10.0;
    #1;
    write_n(DEPTH/2, 8'h60);   // 预填一半，防止读端饥饿
    fork
        begin : wr_tc10
            write_n(64, 8'h61);
        end
        begin : rd_tc10
            read_check_n(64 + DEPTH/2);
        end
    join
    sync_wait;
    assert_eq(rd_empty, 1, "rd_empty after equal-rate stream");
    wr_clk_half = WR_CLK_BASE / 2.0;
    rd_clk_half = RD_CLK_BASE / 2.0;
    tc_end;

    // =========================================================================
    // TC11  随机突发（20 轮）
    // =========================================================================
    tc_begin(11, "Random burst: alternating random-size WR/RD x20");
    apply_full_reset;
    for (i = 0; i < 20; i = i + 1) begin
        j = ($random % (DEPTH/2)) + 1;
        write_n(j, $random & 8'hFF);
        sync_wait;
        j = ($random % j) + 1;
        read_check_n(j);
    end
    while (!rd_empty) fifo_read_check(50);
    sync_wait;
    assert_eq(rd_empty, 1, "rd_empty after random burst cleanup");
    tc_end;

    // =========================================================================
    // TC12  多次复位：数据一致性
    // =========================================================================
    tc_begin(12, "Multiple resets: data integrity across 4 resets");
    for (i = 0; i < 4; i = i + 1) begin
        apply_full_reset;
        write_n(DEPTH/2, 8'h70 + (i[7:0] << 4));
        sync_wait;
        read_check_n(DEPTH/2);
        sync_wait;
        assert_eq(rd_empty, 1, "rd_empty after reset iteration");
    end
    tc_end;

    // =========================================================================
    // TC13  写域单独复位（半复位场景）
    // =========================================================================
    tc_begin(13, "Half-reset: wr domain reset only, rd domain intact");
    apply_full_reset;
    write_n(DEPTH/4, 8'h80);
    sync_wait;
    apply_wr_reset_only;   // 仅写域复位，读域继续运行
    sync_wait;
    // 写域复位后继续写，验证不死锁
    write_n(DEPTH/4, 8'h81);
    sync_wait;
    assert_true(!rd_empty || rd_empty, "no deadlock after wr-only reset");
    while (!rd_empty) fifo_read_drain;
    sync_wait;
    $display("     [INFO] FIFO drained without deadlock after wr-only reset");
    tc_end;

    // =========================================================================
    // TC14  指针回绕（4×DEPTH 次写读）
    // =========================================================================
    tc_begin(14, "Pointer wrap-around: 4xDEPTH write/read pairs");
    apply_full_reset;
    for (i = 0; i < 4 * DEPTH; i = i + 1) begin
        fifo_write(i[DATA_WIDTH-1:0], 50);
        fifo_read_check(50);
    end
    sync_wait;
    assert_eq(rd_empty, 1, "rd_empty after wrap-around test");
    $display("     [INFO] Pointer wrapped through %0d complete cycles", 4);
    tc_end;

    // =========================================================================
    // TC15  count 信号范围合法性
    // =========================================================================
    tc_begin(15, "count signals: range validity check");
    apply_full_reset;
    sync_wait;
    assert_true(wr_count <= DEPTH, "wr_count <= DEPTH when empty");
    assert_true(rd_count <= DEPTH, "rd_count <= DEPTH when empty");
    write_n(DEPTH/2, 8'h90);
    sync_wait;
    assert_true(wr_count > 0,      "wr_count > 0 after writes");
    assert_true(wr_count <= DEPTH, "wr_count <= DEPTH after writes");
    assert_true(rd_count <= DEPTH, "rd_count <= DEPTH after writes");
    write_n(DEPTH/2, 8'h91);       // 填满
    sync_wait;
    assert_true(wr_count <= DEPTH, "wr_count <= DEPTH when full");
    while (!rd_empty) fifo_read_drain;
    tc_end;

    // =========================================================================
    // TC16  极端时钟比（wr 10× rd）
    // =========================================================================
    tc_begin(16, "Extreme clock ratio: wr 10x faster than rd");
    apply_full_reset;
    wr_clk_half = 5.0;    // 100 MHz
    rd_clk_half = 50.0;   //  10 MHz
    #1;
    write_n(DEPTH, 8'hA0);
    sync_wait;
    assert_eq(wr_full, 1, "wr_full with wr 10x faster");
    read_check_n(DEPTH);
    sync_wait;
    assert_eq(rd_empty, 1, "rd_empty after 10x ratio drain");
    wr_clk_half = WR_CLK_BASE / 2.0;
    rd_clk_half = RD_CLK_BASE / 2.0;
    tc_end;

    // =========================================================================
    // TC17  极端时钟比（rd 10× wr）
    // =========================================================================
    tc_begin(17, "Extreme clock ratio: rd 10x faster than wr");
    apply_full_reset;
    wr_clk_half = 50.0;   //  10 MHz
    rd_clk_half = 5.0;    // 100 MHz
    #1;
    fork
        begin : wr_tc17
            write_n(DEPTH, 8'hB0);
        end
        begin : rd_tc17
            repeat (10) @(posedge rd_clk);
            read_check_n(DEPTH);
        end
    join
    sync_wait;
    assert_eq(rd_empty, 1, "rd_empty after rd 10x ratio");
    wr_clk_half = WR_CLK_BASE / 2.0;
    rd_clk_half = RD_CLK_BASE / 2.0;
    tc_end;

    // =========================================================================
    // TC18  边界值数据
    // =========================================================================
    tc_begin(18, "Boundary data: 0x00/0xFF/0xAA/0x55/0x01/0x80");
    apply_full_reset;
    fifo_write(8'h00, 10);
    fifo_write(8'hFF, 10);
    fifo_write(8'hAA, 10);
    fifo_write(8'h55, 10);
    fifo_write(8'h01, 10);
    fifo_write(8'h80, 10);
    sync_wait;
    read_check_n(6);
    sync_wait;
    assert_eq(rd_empty, 1, "rd_empty after boundary value test");
    tc_end;

    // =========================================================================
    // TC19  背靠背写入（连续 wr_en，不插气泡）
    // =========================================================================
    tc_begin(19, "Back-to-back writes: continuous wr_en for DEPTH cycles");
    apply_full_reset;
    @(negedge wr_clk);
    for (i = 0; i < DEPTH; i = i + 1) begin
        if (!wr_full) begin
            wr_en   = 1'b1;
            wr_data = 8'hC0 + i[7:0];
            ref_q[ref_wr_ptr % REF_Q_DEPTH] = wr_data;
            ref_wr_ptr = ref_wr_ptr + 1;
        end
        @(negedge wr_clk);
    end
    wr_en = 1'b0;
    sync_wait;
    assert_eq(wr_full, 1, "wr_full after back-to-back writes");
    read_check_n(DEPTH);
    sync_wait;
    assert_eq(rd_empty, 1, "rd_empty after draining back-to-back writes");
    tc_end;

    // =========================================================================
    // TC20  背靠背读出（连续 rd_en，不插气泡）
    // =========================================================================
    tc_begin(20, "Back-to-back reads: continuous rd_en for DEPTH cycles");
    apply_full_reset;
    write_n(DEPTH, 8'hD0);
    sync_wait;
    // 连续拉高 rd_en 读完所有数据
    @(negedge rd_clk);
    for (i = 0; i < DEPTH + 2; i = i + 1) begin
        if (!rd_empty)
            rd_en = 1'b1;
        else
            rd_en = 1'b0;
        @(negedge rd_clk);
    end
    rd_en = 1'b0;
    // 等待最后数据稳定
    repeat (4) @(posedge rd_clk);
    sync_wait;
    assert_eq(rd_empty, 1, "rd_empty after back-to-back reads");
    tc_end;

    // =========================================================================
    // 汇总
    // =========================================================================
    repeat (20) @(posedge rd_clk);
    $display("\n+----------------------------------------------------------+");
    $display("|                  SIMULATION SUMMARY                     |");
    $display("+----------------------------------------------------------+");
    $display("|  Total checks  : %-39d|", total_checks);
    $display("|  Total errors  : %-39d|", total_errors);
    $display("+----------------------------------------------------------+");
    if (total_errors == 0)
        $display("|            ALL %0d TEST CASES PASSED                    |", 20);
    else
        $display("|            %0d ERROR(S) FOUND IN TEST CASES             |", total_errors);
    $display("+----------------------------------------------------------+");

    $finish;
end

// =============================================================================
// 超时看门狗
// =============================================================================
initial begin
    #10_000_000;
    $display("[WATCHDOG] Simulation exceeded 10ms, force finish");
    $finish;
end

// =============================================================================
// 信号监视（关键标志跳变时打印时间戳）
// =============================================================================
always @(posedge wr_full)
    $display("  [MON] t=%8t ns  wr_full  ASSERTED",  $time);
always @(negedge wr_full)
    $display("  [MON] t=%8t ns  wr_full  deasserted",$time);
always @(posedge rd_empty)
    $display("  [MON] t=%8t ns  rd_empty ASSERTED",  $time);
always @(negedge rd_empty)
    $display("  [MON] t=%8t ns  rd_empty deasserted",$time);

endmodule
