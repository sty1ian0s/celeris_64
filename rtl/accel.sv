//=============================================================================
// accel.sv — CLS64 §3.6 accelerator operand decode (opcodes 0x60-0x8F)
//
// Normative contract: docs/isa-encoding.md VERSION 1.14, §3.6 (Amendment 1.1):
//
//   operand[47:44] = rs2        4 bits   second source; 0 means UNUSED, not R0
//   operand[43:40] = rs3        4 bits   third source; 0 means UNUSED
//   operand[39:32] = reserved   8 bits   MUST be zero; non-zero is a §7 error
//   operand[31:0]  = count     32 bits   unsigned; 0 means "derive from rd"
//
//   High nibble selects the group: 0x60-0x6F matrix, 0x70-0x7F fft,
//   0x80-0x8F codec. An opcode in the range with no §3.6 table row is RESERVED:
//   it must NOT be silently reinterpreted as a neighbouring operation.
//
// SCOPE AND HONEST LIMIT — READ THIS BEFORE TRUSTING ANYTHING BELOW.
//
// This module decodes OPERANDS. It does not, and deliberately does not,
// implement the arithmetic of matrix.*, fft.* or codec.*. Those are large
// datapaths (inversion, a butterfly network, an entropy coder) and the contract
// classifies their behaviour as a SOFTWARE MODEL (docs/isa-encoding.md §3.6 and
// the §8 fidelity ledger: "Correct results computed in software. No hardware
// acceleration, no cycle claims.").
//
// The module's contract is therefore: decode correctly, flag a non-zero
// reserved field, and raise `not_implemented_o` for a RECOGNISED operation and
// `unknown_op_o` for a reserved opcode byte — rather than silently emitting a
// zero (which would be a WRONG RESULT) or aliasing the opcode onto a neighbour.
// `result_valid_o` is asserted only for a word this module can actually answer.
// Today that set is EMPTY, so the top level treats every accelerator word as an
// explicit "this build does not implement it" fault. Saying so is the point.
//
// FIDELITY (docs/isa-encoding.md §8): lint-verified specification + simulation.
// Synthesized (tools/rtl-synth.sh, Yosys + sv2v): see docs/STATUS.md. Still NOT
// timing-closed, NOT placed/routed, never on silicon. No frequency is claimed:
// a cell count is not a timing result.
//=============================================================================

module accel
  import celeris64_pkg::*;
(
  input  logic [OP_W-1:0]       opcode_i,   // §2 opcode[63:56]; §3.6: 0x60-0x8F
  input  logic [RD_W-1:0]       rd_i,       // §2 rd[55:52]
  input  logic [RS1_W-1:0]      rs1_i,      // §2 rs1[51:48]
  input  logic [OPERAND_W-1:0]  operand_i,  // §2 operand[47:0], the §3.6 view

  // ---- decoded §3.6 operand field -----------------------------------------
  output logic [RS2_W-1:0]      rs2_o,          // §3.6 rs2[47:44];  0 = unused
  output logic [RS2_W-1:0]      rs3_o,          // §3.6 rs3[43:40];  0 = unused
  output logic [7:0]            reserved_o,     // §3.6 reserved[39:32]
  output logic [ACC_COUNT_W-1:0] count_o,       // §3.6 count[31:0]; 0 = derive from rd

  // ---- operand-mapping flags (the "0 means unused" rule, §3.6) ------------
  output logic                  rs2_used_o,     // §3.6: rs2_o != 0
  output logic                  rs3_used_o,     // §3.6: rs3_o != 0
  output logic                  count_derived_o,// §3.6: count_o == 0 -> derive from rd

  // ---- group and recognition ----------------------------------------------
  output logic                  in_range_o,     // §3.6: opcode in 0x60-0x8F
  output logic                  group_is_matrix_o,
  output logic                  group_is_fft_o,
  output logic                  group_is_codec_o,
  output logic                  op_recognised_o,// §3.6: has a normative table row

  // ---- decoded §2 destination/source, so the caller never re-slices the word -
  output logic [RD_W-1:0]       rd_o,           // §2 rd[55:52]
  output logic [RS1_W-1:0]      rs1_o,          // §2 rs1[51:48]

  // ---- status --------------------------------------------------------------
  output logic                  reserved_err_o, // §3.6 + §7: reserved[39:32] != 0
  output logic                  not_implemented_o, // §3.6: recognised, no RTL datapath
  output logic                  unknown_op_o,   // §3.6: reserved opcode byte
  output logic                  result_valid_o, // 1 only when a result may be written
  output logic [XLEN-1:0]       result_o        // always 0; never a guess
);

  //---------------------------------------------------------------------------
  // §3.6 operand decode. Pure bit slicing of the §2 operand field — the same
  // slices the package exposes as decoded_word_t and src/decoder.zig performs
  // for the `.accelerator` payload, so all three agree bit-for-bit by
  // construction rather than by coincidence.
  //---------------------------------------------------------------------------
  always_comb begin
    rs2_o      = operand_i[47:44];   // §3.6 rs2[47:44]
    rs3_o      = operand_i[43:40];   // §3.6 rs3[43:40]
    reserved_o = operand_i[39:32];   // §3.6 reserved[39:32], must be zero
    count_o    = operand_i[31:0];    // §3.6 count[31:0]
    // §2 fields passed straight through. Every §3.6 row names rd and rs1 (the
    // destination and the source stream), so the decode is presented complete
    // rather than partial — and repeating the §2 slice here is not a second
    // interpretation of the word, it is the same bits.
    rd_o       = rd_i;               // §2 rd[55:52]
    rs1_o      = rs1_i;              // §2 rs1[51:48]
  end

  // §3.6: "0 means unused, not R0", for rs2 and rs3. Making this a positive
  // predicate rather than an inline compare keeps the rule in one place.
  assign rs2_used_o      = (rs2_o != 4'd0);
  assign rs3_used_o      = (rs3_o != 4'd0);
  assign count_derived_o = (count_o == 32'd0);

  //---------------------------------------------------------------------------
  // §3.6 range and group split. The group is a pure function of the high
  // nibble, which is why the three ranges cannot collide.
  //---------------------------------------------------------------------------
  always_comb begin
    in_range_o         = is_accelerator_opcode(opcode_i);            // 0x60-0x8F
    group_is_matrix_o  = is_matrix_opcode(opcode_i);                 // 0x60-0x6F
    group_is_fft_o     = is_fft_opcode(opcode_i);                    // 0x70-0x7F
    group_is_codec_o   = is_codec_opcode(opcode_i);                  // 0x80-0x8F
  end

  //---------------------------------------------------------------------------
  // §3.6 recognition. Only opcodes with a normative table row count. Everything
  // else in 0x60-0x8F is reserved and must round-trip as raw bytes rather than
  // being read as the next operation down — the alias bug Amendment 1.1 closed.
  //
  // The list is deliberately exhaustive rather than a range check: a range check
  // would report a reserved byte as recognised because its neighbour is.
  //
  // 0x65 `matrix.mulout` was added by amendment 1.19 and is RECOGNISED here as of
  // amendment 1.20's follow-up (F40). It is decode-only like the other thirteen:
  // §3.6 calls these operations a *software model*, so the RTL recognises the opcode
  // and raises not_implemented_o rather than fabricating a product. It is NOT given
  // a datapath — rtl/CROSSCHECK.md §4/§5.7 records that choice deliberately.
  //---------------------------------------------------------------------------
  always_comb begin
    unique case (opcode_i)
      OP_MATRIX_DET, OP_MATRIX_INVERT, OP_MATRIX_MUL,
      OP_MATRIX_TRANSFORM, OP_MATRIX_IDENTITY, OP_MATRIX_MULOUT,
      OP_FFT_FORWARD, OP_FFT_INVERSE, OP_FFT_NTT, OP_FFT_NTT_INVERSE,
      OP_CODEC_COMPRESS, OP_CODEC_DECOMPRESS, OP_CODEC_FNV1A, OP_CODEC_CHECKSUM16:
        op_recognised_o = 1'b1;
      default:
        op_recognised_o = 1'b0;
    endcase
  end

  // §3.6 + §7: a non-zero reserved field is a diagnostic error. The bits are
  // reported, never dropped: silently ignoring them is what makes a word fail to
  // round-trip, and it is the exact class of defect Amendment 1.2 fixed in §3.1.
  assign reserved_err_o = (reserved_o != 8'd0);

  //---------------------------------------------------------------------------
  // §3.6: "not implemented" is a first-class outcome, not an error path bolted
  // on. A recognised operation with no datapath raises not_implemented_o; a
  // reserved opcode byte raises unknown_op_o. The two are distinct because they
  // mean different things to a user: one is "not in this build", the other is
  // "not in this architecture".
  //
  // `result_valid_o` is the ONLY signal that permits a writeback. It is tied to
  // a constant zero here, because this module implements no accelerator
  // arithmetic at all. When a datapath is added it must raise this signal on the
  // specific opcodes it genuinely answers.
  //---------------------------------------------------------------------------
  always_comb begin
    not_implemented_o = in_range_o && op_recognised_o;
    unknown_op_o      = in_range_o && !op_recognised_o;

    result_valid_o = 1'b0;
    result_o       = {XLEN{1'b0}};
  end

endmodule
