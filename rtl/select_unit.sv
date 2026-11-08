//=============================================================================
// select_unit.sv — CLS64 comparison + branchless select
//
// Normative contract: docs/isa-encoding.md VERSION 1.14.
//   §3.2 Comparison and branchless select (high nibble 0x2):
//        0x20 compare — rd = statusEnum(rs1, src2)
//        0x21 select  — rd = (status(rs1) == matchVal) ? trueReg : falseReg
//   §3.2.1 compare does NOT write FLAGS and does NOT branch. It materialises an
//          explicit status enum into rd. "The enum is the ONLY sanctioned result of
//          a comparison; producing a bare 0/1 boolean is a spec violation."
//   §3.2.2 select operand layout: rs2 = match value to test against,
//          trueReg index, falseReg index. "select performs a bitwise selection with
//          no branch. Its result must be identical regardless of which arm would
//          have been taken, and it must not touch PC other than the normal advance."
//   §3.1 operand layout is reused for compare's src2 (rs2 or sign-extended imm28).
//
// THE POINT OF THIS MODULE (spec §1.5, AGENTS.md §3.2):
//   Conditionals are resolved as hardware bitwise selection masks, so there is no
//   branch to mispredict. Two consequences are structural, not stylistic:
//     * `status_o` is a 4-bit enum, never a 1-bit flag — a boolean throws away
//       WHICH WAY and by HOW MUCH the values differed, which the architecture calls
//       boolean blindness.
//     * the select result is built from an all-ones/all-zeros MASK, so both arms are
//       always evaluated and the timing does not depend on which one wins.
//
// FIDELITY (docs/isa-encoding.md §8): lint-verified specification + simulation.
// Synthesized (tools/rtl-synth.sh, Yosys + sv2v): see docs/STATUS.md. Still NOT
// timing-closed, NOT placed/routed, never on silicon. No frequency is claimed:
// a cell count is not a timing result.
//=============================================================================

module select_unit
  import celeris64_pkg::*;
(
  input  logic [OP_W-1:0]   opcode_i,     // §3.2: 0x20 compare, 0x21 select
  input  logic [RS2_W-1:0]  rs2_idx_i,    // §3.2.2 rs2[47:44] = match / src2 register
  input  logic [RS1_W-1:0]  true_idx_i,   // §3.2.2 trueReg index  (operand[43:40])
  input  logic [RS1_W-1:0]  false_idx_i,  // §3.2.2 falseReg index (operand[39:36])
  // §3.2.2 (v1.3): operand[35:0] is reserved and MUST be zero — "rejected when set,
  // not ignored", matching §3.1 zero[39:28] and §3.6 reserved[39:32].
  input  logic [35:0]       reserved_i,   // §3.2.2 operand[35:0], must be zero

  // ---- compare operands -----------------------------------------------------
  input  logic [XLEN-1:0]   rs1_val_i,    // §3.2 lhs
  input  logic [XLEN-1:0]   src2_val_i,   // §3.1 src2 = rs2 or sign-extended imm28
  input  logic              signed_view_i,// §3.2.1: 1 = signed ordering members,
                                          //         0 = unsigned ones. Selected by the
                                          //         opcode's signed/unsigned form; the
                                          //         enum carries BOTH so the caller
                                          //         names which view it wants.
  // ---- select operands ------------------------------------------------------
  input  logic [RS2_W-1:0]  match_status_i,// §3.2.2 rs2: the status value to match
  // §3.2.1: a status is a 4-bit enum, so only those bits are carried. Passing the
  // full register here would invite a caller to compare against a wider value and
  // silently match on bits the enum does not define.
  input  status_e           status_val_i, // §3.2.2 rs1: the status register's enum
  input  logic [XLEN-1:0]   true_val_i,   // §3.2.2 trueReg value
  input  logic [XLEN-1:0]   false_val_i,  // §3.2.2 falseReg value

  output status_e           status_o,     // §3.2.1 the ONLY sanctioned compare result
  output logic [XLEN-1:0]   select_o,     // §3.2.2 branchless merge
  output logic [RS2_W-1:0]  rs2_idx_o,    // §3.2.2 passthrough for the core's operand wiring
  output logic [RS1_W-1:0]  true_idx_o,   // §3.2.2 passthrough
  output logic [RS1_W-1:0]  false_idx_o,  // §3.2.2 passthrough
  output logic              op_legal_o,   // 1 when opcode_i is one of the two §3.2 ops
  output logic              reserved_err_o// §3.2.2 v1.3: operand[35:0] != 0 (§7)
);

  //---------------------------------------------------------------------------
  // §3.2.1 `compare`.
  //
  // The two views are computed in PARALLEL and the equality case is shared, which
  // is exactly the structure the enum implies:
  //
  //   EQUAL is arm-independent — it does not matter which interpretation you use,
  //   so it is tested first and once.
  //
  //   If the operands are not equal, the SIGNED and UNSIGNED views can disagree
  //   about the direction. For 0xFFFF_FFFF_FFFF_FFFF vs 1 the signed view says
  //   LESS (-1 < 1) while the unsigned view says UNSIGNED_GREATER. That divergence
  //   is the entire reason the enum carries four ordering members instead of two;
  //   it is asserted directly in rtl/tb/stream_tb.sv.
  //
  // This mirrors src/select.zig `compare`/`compareSigned`/`compareUnsigned`: same
  // inputs must produce the same enum value.
  //---------------------------------------------------------------------------
  logic is_equal_q;

  // Signed comparison: interpret the bit patterns as two's complement. `$signed`
  // is a reinterpretation, not an arithmetic rescale, so no bits move.
  logic signed [XLEN-1:0] lhs_signed_q;
  logic signed [XLEN-1:0] rhs_signed_q;
  logic                   signed_less_q;

  // Unsigned comparison: the raw bit patterns as magnitudes.
  logic                   unsigned_less_q;

  always_comb begin
    is_equal_q = (rs1_val_i == src2_val_i);                  // §3.2.1 EQUAL

    lhs_signed_q   = $signed(rs1_val_i);
    rhs_signed_q   = $signed(src2_val_i);
    signed_less_q  = (lhs_signed_q < rhs_signed_q);           // §3.2.1 LESS
    unsigned_less_q= (rs1_val_i   < src2_val_i);              // §3.2.1 UNSIGNED_LESS
  end

  //---------------------------------------------------------------------------
  // §3.2.1 status enum. Values are taken from celeris64_pkg (STATUS_*), never
  // re-encoded here: the package is the single definition, and duplicating the
  // numbers is how the simulator and the RTL would silently drift apart.
  //
  // Priority is significant and is the whole content of the encoding: equality
  // wins over either ordering, and the signed/unsigned split only decides which
  // ordering member is produced.
  //---------------------------------------------------------------------------
  always_comb begin
    status_o = STATUS_EQUAL;                                  // §3.2.1 default: equal
    if (!is_equal_q) begin
      // Not equal: choose the ordering member that matches the requested view.
      // `signed_view_i` selects it; see the port note below.
      status_o = signed_view_i ? (signed_less_q   ? STATUS_LESS   : STATUS_GREATER)
                               : (unsigned_less_q ? STATUS_UNSIGNED_LESS
                                                  : STATUS_UNSIGNED_GREATER);
    end
  end

  //---------------------------------------------------------------------------
  // §3.2.2 `select` — GENUINELY BRANCHLESS.
  //
  // The contract is explicit that select is "a bitwise selection with no branch".
  // The implementation is therefore a mask and a merge, in three steps:
  //
  //   1. `match_q`  — is the presented status the one being matched?
  //   2. `mask_q`   — all-ones when it matches, all-zeros otherwise. Built by
  //                   negating a zero-extended single bit, which is a bitwise NOT
  //                   of a replicated bit, NOT an `if` on data values.
  //   3. `select_o` — (true & mask) | (false & ~mask), an and-or merge.
  //
  // There is deliberately NO `if (status == match)` statement anywhere in this
  // path. An `if` on data values would synthesise a mux with the same result but
  // would also express a CANNOT-HAPPEN arm ordering, and the point of the
  // primitive is that both arms are always evaluated. src/select.zig `select`
  // uses the identical `0 -% eq` mask construction.
  //---------------------------------------------------------------------------
  logic            match_q;
  logic [XLEN-1:0] mask_q;

  always_comb begin
    // §3.2.2: the status register holds a §3.2.1 enum, so the match is between two
    // 4-bit enum values and cannot be satisfied by undefined high bits.
    match_q = (status_val_i == status_e'(match_status_i));
    // All-ones mask when matched, all-zeros otherwise (two's-complement negation
    // of a 0/1 bit is the standard hardware "broadcast a bit" idiom).
    mask_q  = {XLEN{match_q}};
  end

  assign select_o = (true_val_i & mask_q) | (false_val_i & ~mask_q);

  assign op_legal_o = (opcode_i == OP_COMPARE) || (opcode_i == OP_SELECT);

  // §3.2.2 v1.3: a set reserved bit is a diagnostic error (§7).
  assign reserved_err_o = (reserved_i != 36'b0);

  // §3.2.2 operand passthroughs, so the §3.2 wiring is visible at the boundary.
  assign rs2_idx_o  = rs2_idx_i;
  assign true_idx_o = true_idx_i;
  assign false_idx_o= false_idx_i;

endmodule
