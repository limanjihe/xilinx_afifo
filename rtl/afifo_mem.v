// =============================================================================
// Module  : afifo_mem
// Desc    : Simple Dual-Port Block RAM inferred for Xilinx FPGA
//           Write port: write clock domain
//           Read  port: read  clock domain
//           Xilinx synthesis attributes ensure BRAM inference (not LUT RAM)
// =============================================================================

`timescale 1ns / 1ps

module afifo_mem #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 4
)(
    // Write port
    input  wire                  wr_clk,
    input  wire                  wr_en,
    input  wire [ADDR_WIDTH-1:0] wr_addr,
    input  wire [DATA_WIDTH-1:0] wr_data,

    // Read port
    input  wire                  rd_clk,
    input  wire                  rd_en,
    input  wire [ADDR_WIDTH-1:0] rd_addr,
    output reg  [DATA_WIDTH-1:0] rd_data
);

    localparam DEPTH = 1 << ADDR_WIDTH;

    // -------------------------------------------------------------------------
    // RAM array – Xilinx attribute forces BRAM inference
    // -------------------------------------------------------------------------
    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // -------------------------------------------------------------------------
    // Initialization (optional, helps simulation)
    // -------------------------------------------------------------------------
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = {DATA_WIDTH{1'b0}};
        rd_data = {DATA_WIDTH{1'b0}};
    end

    // -------------------------------------------------------------------------
    // Write port – synchronous write
    // -------------------------------------------------------------------------
    always @(posedge wr_clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    // -------------------------------------------------------------------------
    // Read port – synchronous read (registered output = standard BRAM behavior)
    // Xilinx 7-Series / UltraScale BRAM is always read-synchronous.
    // The FIFO controller pre-increments the read address so data appears
    // one cycle after rd_en assertion.
    // -------------------------------------------------------------------------
    always @(posedge rd_clk) begin
        if (rd_en)
            rd_data <= mem[rd_addr];
    end

endmodule
