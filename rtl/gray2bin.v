// =============================================================================
// Module  : gray2bin
// Desc    : Combinatorial Gray-code to Binary converter
//           Used to recover binary pointer value from synchronized gray pointer
//           MSB is identical in both encodings; each lower bit XORs with result above.
// =============================================================================

`timescale 1ns / 1ps

module gray2bin #(
    parameter WIDTH = 5
)(
    input  wire [WIDTH-1:0] gray,
    output wire [WIDTH-1:0] bin
);

    genvar i;
    generate
        // MSB is the same
        assign bin[WIDTH-1] = gray[WIDTH-1];

        // Each lower bit is XOR of all higher gray bits (tree-reduction equivalent)
        for (i = WIDTH-2; i >= 0; i = i - 1) begin : g2b_loop
            assign bin[i] = bin[i+1] ^ gray[i];
        end
    endgenerate

endmodule
