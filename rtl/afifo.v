// =============================================================================
// Module  : afifo
// Author  : Cummings Method Implementation
// Desc    : Asynchronous FIFO for Xilinx FPGA
//           Reference: "Simulation and Synthesis Techniques for Asynchronous
//           FIFO Design" - Clifford E. Cummings, SNUG 2002
//
// Features:
//   - Dual clock domain (write clk / read clk)
//   - Gray-code pointers for metastability-safe CDC
//   - 2-stage synchronizer flip-flops
//   - Parameterizable depth and data width
//   - Full/Empty flags generated combinatorially from gray pointers
// =============================================================================

`timescale 1ns / 1ps

module afifo #(
    parameter DATA_WIDTH = 8,               // Data bus width
    parameter ADDR_WIDTH = 4                // Address width → depth = 2^ADDR_WIDTH
)(
    // Write clock domain
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,   // Active-low async reset
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output wire                  wr_full,
    output wire [ADDR_WIDTH:0]   wr_count,   // Number of words in FIFO (write domain)

    // Read clock domain
    input  wire                  rd_clk,
    input  wire                  rd_rst_n,   // Active-low async reset
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] rd_data,
    output wire                  rd_empty,
    output wire [ADDR_WIDTH:0]   rd_count    // Number of words in FIFO (read domain)
);

    // -------------------------------------------------------------------------
    // Local parameters
    // -------------------------------------------------------------------------
    localparam DEPTH = 1 << ADDR_WIDTH;     // FIFO depth

    // -------------------------------------------------------------------------
    // Internal signals
    // -------------------------------------------------------------------------
    // Binary pointers (registered)
    reg  [ADDR_WIDTH:0] wr_ptr_bin;         // Write pointer (binary), write domain
    reg  [ADDR_WIDTH:0] rd_ptr_bin;         // Read  pointer (binary), read  domain

    // Gray-code pointers
    reg  [ADDR_WIDTH:0] wr_ptr_gray;        // Write pointer (gray), write domain
    reg  [ADDR_WIDTH:0] rd_ptr_gray;        // Read  pointer (gray), read  domain

    // Synchronized gray pointers (2-stage)
    reg  [ADDR_WIDTH:0] wr_ptr_gray_s1, wr_ptr_gray_s2;  // wr→rd sync
    reg  [ADDR_WIDTH:0] rd_ptr_gray_s1, rd_ptr_gray_s2;  // rd→wr sync

    // Synchronized binary pointers (converted from gray)
    wire [ADDR_WIDTH:0] wr_ptr_bin_sync;    // Write pointer synchronized to read domain
    wire [ADDR_WIDTH:0] rd_ptr_bin_sync;    // Read  pointer synchronized to write domain

    // Dual-port RAM output
    wire [DATA_WIDTH-1:0] ram_rd_data;

    // -------------------------------------------------------------------------
    // Dual-Port Block RAM (Simple Dual Port, First Word Fall Through optional)
    // -------------------------------------------------------------------------
    afifo_mem #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_mem (
        .wr_clk  (wr_clk),
        .wr_en   (wr_en & ~wr_full),
        .wr_addr (wr_ptr_bin[ADDR_WIDTH-1:0]),
        .wr_data (wr_data),
        .rd_clk  (rd_clk),
        .rd_en   (rd_en & ~rd_empty),
        .rd_addr (rd_ptr_bin[ADDR_WIDTH-1:0]),
        .rd_data (ram_rd_data)
    );

    assign rd_data = ram_rd_data;

    // =========================================================================
    // WRITE CLOCK DOMAIN
    // =========================================================================

    // -------------------------------------------------------------------------
    // Write pointer – binary increment
    // -------------------------------------------------------------------------
    wire [ADDR_WIDTH:0] wr_ptr_bin_next;
    assign wr_ptr_bin_next = wr_ptr_bin + {{ADDR_WIDTH{1'b0}}, (wr_en & ~wr_full)};

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n)
            wr_ptr_bin <= {(ADDR_WIDTH+1){1'b0}};
        else
            wr_ptr_bin <= wr_ptr_bin_next;
    end

    // -------------------------------------------------------------------------
    // Write pointer – binary to gray conversion (registered)
    // -------------------------------------------------------------------------
    wire [ADDR_WIDTH:0] wr_ptr_gray_next;
    assign wr_ptr_gray_next = (wr_ptr_bin_next >> 1) ^ wr_ptr_bin_next;

    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n)
            wr_ptr_gray <= {(ADDR_WIDTH+1){1'b0}};
        else
            wr_ptr_gray <= wr_ptr_gray_next;
    end

    // -------------------------------------------------------------------------
    // Synchronize read gray pointer into write domain (2 flip-flop synchronizer)
    // -------------------------------------------------------------------------
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_ptr_gray_s1 <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr_gray_s2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            rd_ptr_gray_s1 <= rd_ptr_gray;    // Stage 1: capture (may be metastable)
            rd_ptr_gray_s2 <= rd_ptr_gray_s1; // Stage 2: resolved
        end
    end

    // -------------------------------------------------------------------------
    // Convert synchronized gray pointer back to binary (write domain)
    // -------------------------------------------------------------------------
    gray2bin #(.WIDTH(ADDR_WIDTH+1)) u_g2b_rd2wr (
        .gray (rd_ptr_gray_s2),
        .bin  (rd_ptr_bin_sync)
    );

    // -------------------------------------------------------------------------
    // Full flag – generated in write domain
    // Cummings method: compare MSBs differ AND remaining bits equal
    // Using gray code comparison directly:
    //   full when: wr_ptr_gray == {~rd_ptr_gray_s2[ADDR_WIDTH:ADDR_WIDTH-1],
    //                                rd_ptr_gray_s2[ADDR_WIDTH-2:0]}
    // -------------------------------------------------------------------------
    assign wr_full = (wr_ptr_gray == {~rd_ptr_gray_s2[ADDR_WIDTH:ADDR_WIDTH-1],
                                       rd_ptr_gray_s2[ADDR_WIDTH-2:0]});

    // -------------------------------------------------------------------------
    // Write-domain word count
    // -------------------------------------------------------------------------
    assign wr_count = wr_ptr_bin - rd_ptr_bin_sync;

    // =========================================================================
    // READ CLOCK DOMAIN
    // =========================================================================

    // -------------------------------------------------------------------------
    // Read pointer – binary increment
    // -------------------------------------------------------------------------
    wire [ADDR_WIDTH:0] rd_ptr_bin_next;
    assign rd_ptr_bin_next = rd_ptr_bin + {{ADDR_WIDTH{1'b0}}, (rd_en & ~rd_empty)};

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n)
            rd_ptr_bin <= {(ADDR_WIDTH+1){1'b0}};
        else
            rd_ptr_bin <= rd_ptr_bin_next;
    end

    // -------------------------------------------------------------------------
    // Read pointer – binary to gray conversion (registered)
    // -------------------------------------------------------------------------
    wire [ADDR_WIDTH:0] rd_ptr_gray_next;
    assign rd_ptr_gray_next = (rd_ptr_bin_next >> 1) ^ rd_ptr_bin_next;

    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n)
            rd_ptr_gray <= {(ADDR_WIDTH+1){1'b0}};
        else
            rd_ptr_gray <= rd_ptr_gray_next;
    end

    // -------------------------------------------------------------------------
    // Synchronize write gray pointer into read domain (2 flip-flop synchronizer)
    // -------------------------------------------------------------------------
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_ptr_gray_s1 <= {(ADDR_WIDTH+1){1'b0}};
            wr_ptr_gray_s2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            wr_ptr_gray_s1 <= wr_ptr_gray;    // Stage 1: capture
            wr_ptr_gray_s2 <= wr_ptr_gray_s1; // Stage 2: resolved
        end
    end

    // -------------------------------------------------------------------------
    // Convert synchronized gray pointer back to binary (read domain)
    // -------------------------------------------------------------------------
    gray2bin #(.WIDTH(ADDR_WIDTH+1)) u_g2b_wr2rd (
        .gray (wr_ptr_gray_s2),
        .bin  (wr_ptr_bin_sync)
    );

    // -------------------------------------------------------------------------
    // Empty flag – generated in read domain
    // Empty when read gray pointer == synchronized write gray pointer
    // -------------------------------------------------------------------------
    assign rd_empty = (rd_ptr_gray == wr_ptr_gray_s2);

    // -------------------------------------------------------------------------
    // Read-domain word count
    // -------------------------------------------------------------------------
    assign rd_count = wr_ptr_bin_sync - rd_ptr_bin;

endmodule
