//=============================================================================
// field_unit.sv — CLS64 bitfield slicing: field.extract / field.insert
//
// Normative contract: docs/isa-encoding.md VERSION 1.14.
//   §3.3 Field slicing (high nibble 0x3):
//        0x30 field.extract — rd = (rs1 >> offset) & mask(width)
//        0x31 field.insert  — rd = rs1 with `width` bits of src2 placed at `offset`
//   §3.3 operand layout for both:
//        offset[47:40] | width[39:32] | src2[31:28] (field.insert only)
//   §3.3.1 Field constraints, normative:
//        * width must be 1..=64. width == 0 is a diagnostic error.
//        * offset + width must be <= 64. Overflow is a diagnostic error, NOT a
//          silent wrap. "Out-of-range extraction is exactly the class of bug this
//          primitive exists to remove."
//        * widths are explicitly non-power-of-two, e.g. U1, U3, U5 (spec §3.3).
//
//   §5 is NOT used here: a field width is an arbitrary 1..64 bit count, not one of
//   the four register-write widths. The two are different encodings in different
//   operand positions, so this module deliberately does not accept a width_e.
//
// THE POINT OF THIS MODULE (spec §3.3, AGENTS.md §3.3):
//   `(v >> off) & ((1 << w) - 1)` is one line of software, and the reason field.*
//   exists is not brevity — it is that the hand-written form has NO range check, so
//   an out-of-range slice silently produces garbage from the wrong bits. Here the
//   range check is a hardware output (range_err_o) and an out-of-range request
//   produces NO datum at all rather than a wrapped one.
//
// FIDELITY (docs/isa-encoding.md §8): lint-verified specification + simulation.
// NEVER synthesized, never timing-closed, never on silicon. No frequency claimed.
//=============================================================================

module field_unit
  import celeris64_pkg::*;
(
  input  logic [OP_W-1:0]    opcode_i,     // §3.3: 0x30 field.extract, 0x31 field.insert
  input  logic [7:0]         offset_i,     // §3.3 offset[47:40], bit position
  input  logic [7:0]         width_i,      // §3.3 width[39:32], 1..=64 bits
  input  logic [RS1_W-1:0]   src2_idx_i,   // §3.3 src2[31:28], field.insert source reg
  // §3.3 (v1.9): operand[27:0] is reserved and MUST be zero — "reserved means rejected
  // when set, not ignored". Earlier revisions left this range unmentioned; the contract
  // now states it, so the RTL rejects rather than silently dropping the bits.
  input  logic [27:0]        reserved_i,   // §3.3 operand[27:0], must be zero

  input  logic [XLEN-1:0]    base_val_i,   // §3.3 rs1: the value to slice / to modify
  input  logic [XLEN-1:0]    field_val_i,  // §3.3 src2 value, resolved by the regfile

  output logic [XLEN-1:0]    result_o,     // §3.3 extract or insert result
  output logic               zero_width_o, // §3.3.1: width == 0 is a diagnostic error
  output logic               range_err_o,  // §3.3.1: offset + width > 64, no silent wrap
  output logic               too_wide_o,   // §3.3: insert value does not fit the field
  output logic               reserved_err_o,// §3.3 v1.9: operand[27:0] != 0 (§7)
  output logic               op_legal_o,   // 1 when opcode_i is one of the two §3.3 ops
  output logic [RS1_W-1:0]   src2_idx_o    // §3.3 src2 passthrough for operand wiring
);

  //---------------------------------------------------------------------------
  // §3.3.1 width mask. `mask(width)` is `width` low bits set.
  //
  // width == 64 is the one case a shift cannot express: `1 << 64` is not a legal
  // 64-bit shift, and the mathematically correct mask is all-ones. It is therefore
  // special-cased explicitly rather than relying on a shift by 0, which would
  // silently produce a ONE-bit mask and corrupt every full-width extract.
  // This mirrors src/field.zig `mask`, which special-cases maxInt(u64) identically.
  //---------------------------------------------------------------------------
  localparam int unsigned FIELD_W    = 8;   // §3.3 width is 8 bits (not the §5 .w suffix)
  localparam int unsigned FIELD_OFF_W = 8;  // §3.3 offset is 8 bits

  logic [XLEN-1:0] width_mask_q;
  logic            width_is_64_q;

  assign width_is_64_q = (width_i == FIELD_W'(XLEN));   // §3.3.1: width == 64

  //---------------------------------------------------------------------------
  // §3.3.1 range check: 1 <= width <= 64 and offset + width <= 64.
  //
  // The sum is widened to 9 bits so `offset + width` can be compared against 64
  // without wrapping: at 8 bits, offset 255 + width 2 would wrap to 1 and PASS a
  // naive <= 64 test, which is precisely the silent wrap §3.3.1 forbids.
  //---------------------------------------------------------------------------
  logic [FIELD_OFF_W:0] offset_plus_width_q;
  logic              width_in_range_q;
  logic              span_ok_q;

  always_comb begin
    offset_plus_width_q = {1'b0, offset_i} + {1'b0, width_i};
    width_in_range_q    = (width_i >= FIELD_W'(1)) && (width_i <= FIELD_W'(XLEN));
    span_ok_q           = (offset_plus_width_q <= ((FIELD_OFF_W+1)'(XLEN)));
  end

  // §3.3 v1.9: a set reserved bit is a diagnostic error (§7), so a request carrying
  // one is refused rather than honoured with the bits quietly dropped.
  assign reserved_err_o = (reserved_i != 28'b0);
  assign zero_width_o = (width_i == FIELD_W'(0));       // §3.3.1: width == 0
  assign range_err_o  = !zero_width_o && !(width_in_range_q && span_ok_q);
  assign op_legal_o   = (opcode_i == OP_FIELD_EXTRACT) || (opcode_i == OP_FIELD_INSERT);

  // A request is only honoured when every §3.3.1 constraint holds AND the reserved
  // field is zero (§3.3 v1.9).
  logic request_ok_q;
  assign request_ok_q = width_in_range_q && span_ok_q && (reserved_i == 28'b0);

  //---------------------------------------------------------------------------
  // Mask construction, then the two operations. All combinational.
  //---------------------------------------------------------------------------
  always_comb begin
    // Two's-complement style: 1 << width gives the bit ABOVE the field, minus one
    // makes it the field's low-bit mask. width == 64 is the special case above.
    //
    // The shift amount is the 6-bit low part of width. For width < 64 that is exact
    // (0..63); for width == 64 the value is overridden by width_is_64_q, so the
    // shift never needs to represent 64 and a Verilator WIDTH error is avoided.
    width_mask_q = width_is_64_q ? {XLEN{1'b1}}
                                 : ((XLEN'(1) << width_i[5:0]) - XLEN'(1));
  end

  //---------------------------------------------------------------------------
  // §3.3 extract: `rd = (rs1 >> offset) & mask(width)`.
  //
  // The shift amount is the 6-bit low part of offset: a 64-bit variable shift only
  // defines amounts 0..63, and offset is validated to satisfy offset+width <= 64, so
  // an in-range offset with a non-zero width is at most 63. For offset == 64 the
  // only legal width is 0, which is refused before the result is used.
  //---------------------------------------------------------------------------
  logic [XLEN-1:0] extracted_q;

  logic [5:0] off_shift_q;
  assign off_shift_q = offset_i[5:0];

  assign extracted_q = (base_val_i >> off_shift_q) & width_mask_q;

  //---------------------------------------------------------------------------
  // §3.3 insert: place the low `width` bits of src2 at `offset`, leaving every
  // other bit of rs1 untouched.
  //
  // src/field.zig `insert` additionally REFUSES a field value that does not fit the
  // declared width (InsertValueTooWide) rather than masking it down silently, on the
  // grounds that silent loss is the bug field.* exists to kill. The contract §3.3
  // does not name that case explicitly, so the RTL reports it on too_wide_o while
  // still producing the correctly-masked datum; the choice is called out as a
  // finding in the task report rather than assumed to be contract-mandated.
  //---------------------------------------------------------------------------
  logic [XLEN-1:0] shifted_mask_q;
  logic [XLEN-1:0] inserted_q;
  logic            insert_overflow_q;

  assign shifted_mask_q   = width_mask_q << off_shift_q;
  assign inserted_q       = (base_val_i & ~shifted_mask_q)
                          | ((field_val_i & width_mask_q) << off_shift_q);
  // width == 64 has no "above the field" bits, so it can never overflow.
  assign insert_overflow_q = (width_i != FIELD_W'(0)) && !width_is_64_q
                          && ((field_val_i & ~width_mask_q) != {XLEN{1'b0}});

  assign too_wide_o = (opcode_i == OP_FIELD_INSERT) && insert_overflow_q;

  //---------------------------------------------------------------------------
  // Result mux. A request that violates §3.3.1 produces ZERO rather than a wrapped
  // value: §3.3.1 calls out-of-range extraction "exactly the class of bug this
  // primitive exists to remove", so returning wrapped garbage would defeat it.
  // The caller sees the datum it asked for only when range_err_o is clear.
  //---------------------------------------------------------------------------
  always_comb begin
    unique case (opcode_i)
      OP_FIELD_EXTRACT: result_o = extracted_q;            // 0x30
      OP_FIELD_INSERT:  result_o = inserted_q;             // 0x31
      default:          result_o = {XLEN{1'b0}};           // not a §3.3 op
    endcase
    if (!request_ok_q) result_o = {XLEN{1'b0}};            // §3.3.1: refuse, do not wrap
  end

  // §3.3 src2[31:28] is the insert source register; the core resolves it, and it is
  // surfaced here so the §3.3 operand wiring is visible at the module boundary.
  assign src2_idx_o = src2_idx_i;

endmodule
