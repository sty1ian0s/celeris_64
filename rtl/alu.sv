//=============================================================================
// alu.sv — CLS64 ten §3.1 ALU operations
//
// Normative contract: docs/isa-encoding.md VERSION 1.14.
//   §3.1 ALU — opcodes 0x10-0x19, operand layout (v1.2 Amendment 1.2)
//                rs2[47:44] | width[43:40] | zero[39:28] | imm28[27:0]
//              "imm28 is a signed 28-bit immediate, sign-extended to 64 bits.
//               If imm28 != 0 the instruction is immediate-form and rs2 is
//               ignored."
//              v1.1 drew a 40-bit immediate here. The drawing contradicted the
//              field name, the §3.1 prose and decoder.zig's `u28`; Amendment 1.2
//              fixed the diagram, not the width. Bits [39:28] are reserved and
//              must be zero — reported on zero_err_o, never silently ignored.
//   §3.1 div — "divide-by-zero is a diagnostic error, not a trap (§7)". This
//              module therefore reports it on div_zero_o and substitutes 0; it
//              does not fault and does not rely on host division semantics.
//   §5 Width Suffix — the width applies to the RESULT before writeback.
//
// Combinational: one word in, one 64-bit result out. No clock, no state.
//
// FIDELITY (docs/isa-encoding.md §8): lint-verified specification + simulation.
// NEVER synthesized, never timing-closed, never on silicon. No frequency claimed.
//=============================================================================

module alu
  import celeris64_pkg::*;
(
  input  logic [OP_W-1:0]       opcode_i,   // §2 opcode[63:56]; §3.1: 0x10-0x19
  input  logic [ALUWIDTH_W-1:0] width_raw_i,// §3.1 width[43:40]; §5: 4-15 reserved
  input  logic [IMM28_W-1:0]    imm28_i,    // §3.1 v1.2 imm28[27:0], signed
  input  logic [ALU_ZERO_W-1:0] alu_zero_i, // §3.1 v1.2 zero[39:28], reserved: must be 0
  input  logic [XLEN-1:0]       rs1_val_i,  // §2 rs1[51:48] resolved by the regfile
  input  logic [XLEN-1:0]       rs2_val_i,  // §3.1 rs2[47:44] resolved by the regfile

  output logic [XLEN-1:0]       result_o,   // §5: width ALREADY applied to the result
  output logic                  div_zero_o, // §3.1: src2 == 0, diagnostic not trap
  output logic                  width_err_o,// §5: reserved width requested
  output logic                  zero_err_o, // §3.1 v1.2: reserved zero[39:28] != 0 (§7)
  output logic                  op_legal_o  // 1 when opcode_i is one of the ten §3 ops
);

  //---------------------------------------------------------------------------
  // §3.1 immediate-form rule: "If imm28 != 0, the instruction is immediate-form
  // and rs2 is ignored."
  //
  // Consequence worth stating: there is no way to encode add Rd, Rs1, 0 as an
  // immediate, because imm28 == 0 IS the register form. That is what the contract
  // says; it is reported as a finding rather than patched around here.
  //
  // v1.2: imm28 is [27:0], so a word with bits set in the reserved [39:28] and a
  // zero imm28 is REGISTER-form. That is the exact word whose interpretation
  // diverged under v1.1 and motivated Amendment 1.2.
  //---------------------------------------------------------------------------
  logic             imm_form;
  logic [XLEN-1:0]  src2;      // §3.1 src2 = rs2 or the immediate, per the rule above

  always_comb begin
    imm_form = alu_is_immediate(imm28_i);
    // Sign-extension of the 28-bit immediate from bit 27. Done once in the
    // package (`unpack_word.imm_sext`) and replicated here so the ALU is usable
    // with raw fields.
    src2     = imm_form ? {{(XLEN-IMM28_W){imm28_i[IMM28_W-1]}}, imm28_i}
                        : rs2_val_i;
  end

  // §3.1 v1.2 + §7: a non-zero reserved field is a diagnostic error, reported on
  // zero_err_o. The field is NOT ignored: silently dropping bits is what makes a
  // word fail to round-trip.
  assign zero_err_o = !alu_zero_is_reserved_ok(alu_zero_i);

  //---------------------------------------------------------------------------
  // §5 width decode — the same legality rule the regfile applies, so a reserved
  // width is refused identically on both sides.
  //---------------------------------------------------------------------------
  width_e          width;
  logic            width_legal;
  logic [XLEN-1:0] width_mask_q;

  always_comb begin
    width_legal  = width_enc_is_legal(width_raw_i);   // §5: 0..3 legal, 4..15 reserved
    width        = width_e'(width_raw_i[1:0]);
    width_mask_q = width_mask(width);
  end

  assign width_err_o = !width_legal;

  //---------------------------------------------------------------------------
  // §3.1 opcode decode and the ten operations.
  //
  // All arithmetic is carried out at the full 64-bit width and the §5 width is
  // applied to the RESULT, never to the operands — the contract says "width
  // applies to the result before writeback", so `add.l` of 0xFFFF_FFFF and 1
  // produces 0x0000_0000_0000_0000 (sum 0x1_0000_0000 truncated to 32 bits),
  // not 0xFFFF_FFFF + 1 computed at 32 bits.
  //
  // shl/shr use the low 6 bits of src2 as the shift amount: shifts >= XLEN are
  // not defined by §3.1 and a 64-bit right shift by >= 64 would be a Verilator
  // WIDTH error, so the amount is truncated explicitly and visibly rather than
  // left to wrap. shift amount 0 is a no-op, so the truncation is exact for
  // every in-range shift; it only affects out-of-range shifts the contract does
  // not define.
  //---------------------------------------------------------------------------
  logic [XLEN-1:0] raw_result;
  logic            is_div_zero;
  logic [5:0]      shamt;

  always_comb begin
    // --- combinational, no state, no latching: every output is assigned in
    // --- every path that reaches it.
    shamt = src2[5:0];

    unique case (opcode_i)
      OP_ADD:  raw_result = rs1_val_i + src2;                        // 0x10
      OP_SUB:  raw_result = rs1_val_i - src2;                        // 0x11
      OP_MUL:  raw_result = rs1_val_i * src2;                        // 0x12 low 64 bits
      OP_DIV: begin                                                  // 0x13
        if (src2 == {XLEN{1'b0}}) begin
          // §3.1 + §7: divide-by-zero is a diagnostic, not a trap. Report it and
          // do not let the result be an artefact of the host's divide behaviour.
          raw_result = {XLEN{1'b0}};
        end else begin
          raw_result = rs1_val_i / src2;
        end
      end
      OP_AND:  raw_result = rs1_val_i & src2;                        // 0x14
      OP_OR:   raw_result = rs1_val_i | src2;                        // 0x15
      OP_XOR:  raw_result = rs1_val_i ^ src2;                        // 0x16
      OP_SHL:  raw_result = rs1_val_i << shamt;                      // 0x17
      OP_SHR:  raw_result = rs1_val_i >> shamt;                      // 0x18, logical
      OP_MOV:  raw_result = src2;                                    // 0x19: rs1 ignored
      default: raw_result = {XLEN{1'b0}};   // not one of the ten §3.1 ops
    endcase
  end

  always_comb begin
    op_legal_o  = (opcode_i >= OP_ADD) && (opcode_i <= OP_MOV);       // §3.1: 0x10-0x19
    is_div_zero = (opcode_i == OP_DIV) && (src2 == {XLEN{1'b0}});     // §3.1 divide-by-zero
    div_zero_o  = is_div_zero;
  end

  //---------------------------------------------------------------------------
  // §5: width applies to the result before writeback. Multiplying by the mask
  // zero-extends the upper bits — the same mandatory zero-extension the regfile
  // performs on write (AGENTS.md §2.1), so a caller that writes result_o into a
  // at full width still gets a zero-extended value.
  //---------------------------------------------------------------------------
  always_comb begin
    result_o = raw_result & width_mask_q;
  end

endmodule
