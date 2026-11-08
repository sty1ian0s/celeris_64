//=============================================================================
// regfile.sv — CLS64 register file: R0-R11, SP, LR, PC, FLAGS
//
// Normative contract: docs/isa-encoding.md VERSION 1.14.
//   §4  Register Index Encoding — 0..11 R0-R11, 12 SP, 13 LR, 14 PC, 15 FLAGS
//   §5  Width Suffix Encoding   — 0 none / 1 .l / 2 .w / 3 .b, 4-15 reserved
// Architectural mandate: AGENTS.md §2.1, spec §2.2 — a sub-width write
// ZERO-EXTENDS the upper bits. This is observable behaviour: it is the mechanism
// that removes partial-register stall dependencies, so the upper bits are
// CLEARED, never preserved. rtl/tb/alu_tb.sv asserts this directly.
//
// Structure: two asynchronous read ports, one synchronous write port.
// Read is combinational (a pure function of the stored state and the index), so
// a read in the same cycle as a write to the same register returns the OLD value.
// That is the classic register-file read/write conflict rule and the ordering the
// core's pipeline expects; it is stated here because it is not visible in the code.
//
// FIDELITY (docs/isa-encoding.md §8): lint-verified specification + simulation.
// NEVER synthesized, never timing-closed, never on silicon. No frequency claimed.
//=============================================================================

module regfile
  import celeris64_pkg::*;
(
  input  logic                 clk_i,
  input  logic                 rst_ni,       // synchronous, active-low

  // ---- read port A (rs1) ---------------------------------------------------
  input  logic [RD_W-1:0]      raddr_a_i,    // §4 index
  output logic [XLEN-1:0]      rdata_a_o,

  // ---- read port B (rs2) ---------------------------------------------------
  input  logic [RD_W-1:0]      raddr_b_i,    // §4 index
  output logic [XLEN-1:0]      rdata_b_o,

  // ---- write port ----------------------------------------------------------
  input  logic                 we_i,
  input  logic [RD_W-1:0]      waddr_i,      // §4 index
  input  logic [ALUWIDTH_W-1:0] width_raw_i, // §5 raw width nibble: 4-15 reserved
  input  logic [XLEN-1:0]      wdata_i,
  output logic                 width_err_o   // §5: reserved width was requested
);

  //---------------------------------------------------------------------------
  // Storage. R0-R11 are twelve real, writable 64-bit containers (§4: index 0 is
  // NOT a hardwired zero — Celeris-64's ZERO has no index at all, it is expressed
  // by omitting a write target).
  //---------------------------------------------------------------------------
  logic [XLEN-1:0] gpr_q   [GPR_COUNT];
  logic [XLEN-1:0] sp_q;      // §4 index 12
  logic [XLEN-1:0] lr_q;      // §4 index 13
  logic [XLEN-1:0] pc_q;      // §4 index 14
  logic [XLEN-1:0] flags_q;   // §4 index 15

  //---------------------------------------------------------------------------
  // §5 width decode. width_raw_i is the raw 4-bit field from §3.1 width[43:40]
  // (or §3.4 operand[23:20]); values 4-15 are reserved and MUST be reported, not
  // silently treated as full width. This is the same refusal src/registers.zig
  // `Width.fromEncoded` implements on the software side.
  //---------------------------------------------------------------------------
  logic             width_legal;
  width_e           width;
  logic [XLEN-1:0]  width_mask_q;

  always_comb begin
    width_legal  = width_enc_is_legal(width_raw_i);   // §5: 0..3 legal, 4..15 reserved
    width        = width_e'(width_raw_i[1:0]);        // only meaningful when legal
    width_mask_q = width_mask(width);
  end

  assign width_err_o = we_i && !width_legal;

  //---------------------------------------------------------------------------
  // §5 + AGENTS.md §2.1: sub-width write with mandatory zero-extension.
  //
  // "Write low N, zero-extend upper 64-N" is exactly `wdata_i & width_mask(width)`
  // stored into the full 64-bit register: the mask clears every upper bit, so the
  // stored value is N bits wide and zero above. WIDTH_FULL's mask is all-ones, so
  // a full write keeps every bit.
  //
  // A stored zero-extended value is what makes a later full-width read return
  // 0x0000_0000_0000_00AB rather than the stale 0xFFFF_FFFF_FFFF_FFFF that a
  // preserve-the-upper-bits write would leave behind.
  //---------------------------------------------------------------------------
  logic [XLEN-1:0] wdata_ext;

  always_comb begin
    wdata_ext = wdata_i & width_mask_q;
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      for (int unsigned i = 0; i < GPR_COUNT; i++) begin
        gpr_q[i] <= {XLEN{1'b0}};
      end
      sp_q    <= {XLEN{1'b0}};
      lr_q    <= {XLEN{1'b0}};
      pc_q    <= {XLEN{1'b0}};
      flags_q <= {XLEN{1'b0}};
    end else if (we_i && width_legal) begin
      // §5: a reserved width is refused outright — the register is not modified,
      // so a reserved encoding can never be mistaken for a full-width write.
      case (waddr_i)
        REG_SP:    sp_q    <= wdata_ext;                             // §4 index 12
        REG_LR:    lr_q    <= wdata_ext;                             // §4 index 13
        REG_PC:    pc_q    <= wdata_ext;                             // §4 index 14
        REG_FLAGS: flags_q <= wdata_ext;                             // §4 index 15
        default: begin
          // §4: indices 0-11 are R0-R11. GPR_INDEX_MAX guards the array bound.
          if (waddr_i <= GPR_INDEX_MAX) begin
            gpr_q[waddr_i] <= wdata_ext;
          end
        end
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // Asynchronous read ports, §4 index decode. Both ports see the same state, so
  // two reads of the same index in one cycle agree by construction.
  //---------------------------------------------------------------------------
  always_comb begin
    if (raddr_a_i <= GPR_INDEX_MAX) begin
      rdata_a_o = gpr_q[raddr_a_i];                      // §4 indices 0-11
    end else begin
      case (raddr_a_i)
        REG_SP:    rdata_a_o = sp_q;                     // §4 index 12
        REG_LR:    rdata_a_o = lr_q;                     // §4 index 13
        REG_PC:    rdata_a_o = pc_q;                     // §4 index 14
        REG_FLAGS: rdata_a_o = flags_q;                  // §4 index 15
        default:   rdata_a_o = {XLEN{1'b0}};             // unreachable: 4 bits, max 15
      endcase
    end
  end

  always_comb begin
    if (raddr_b_i <= GPR_INDEX_MAX) begin
      rdata_b_o = gpr_q[raddr_b_i];                      // §4 indices 0-11
    end else begin
      case (raddr_b_i)
        REG_SP:    rdata_b_o = sp_q;                     // §4 index 12
        REG_LR:    rdata_b_o = lr_q;                     // §4 index 13
        REG_PC:    rdata_b_o = pc_q;                     // §4 index 14
        REG_FLAGS: rdata_b_o = flags_q;                  // §4 index 15
        default:   rdata_b_o = {XLEN{1'b0}};             // unreachable: 4 bits, max 15
      endcase
    end
  end

endmodule
