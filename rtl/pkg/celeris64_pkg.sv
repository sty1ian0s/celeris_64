//=============================================================================
// celeris64_pkg.sv — CLS64 encoding constants (second implementation)
//
// Normative contract: docs/isa-encoding.md, VERSION 1.14.
//
// The "v1.2" mentions below are historical: each records the amendment that
// introduced a rule, not the contract version this file tracks. Only the line
// above tracks the contract. Amendments after 1.2 (1.11-1.14) govern §3.5-§3.7
// opcodes, which this package declares as constants and does not re-derive.
//
//   v1.1 -> v1.2 (Amendment 1.2): §3.1 `imm28` is 28 bits [27:0], not the 40 bits
//   its v1.1 diagram drew. Bits [39:28] are reserved `zero` and must be zero.
// Sections implemented here verbatim:
//   §2  Word Layout               — OP_W, RD_W, RS1_W, OPERAND_W + unpack funcs
//   §3  Opcode Map                — OP_* major opcode constants (§3.0-§3.7)
//   §3.1 ALU operand field        — RS2/ALUWIDTH/ALU_ZERO/IMM28 (v1.2 widths)
//   §4  Register Index Encoding   — REG_* indices
//   §5  Width Suffix Encoding     — width_e enum
//
// This is the second implementation of §2-§5; the Zig decoder in
// src/decoder.zig is the first. Every constant below was cross-checked against
// decoder.zig `Opcode.fromByte` and `assembleWord` rather than written from
// memory. Where the doc and decoder.zig were compared, the comparison is
// recorded in the task report.
//
// FIDELITY (docs/isa-encoding.md §8): this package is a lint-verified
// specification, and it is now synthesized along with the rest of the design
// (tools/rtl-synth.sh). It is still NOT timing-closed and never placed on
// silicon. No clock frequency is claimed anywhere in rtl/, and a cell count is
// not a timing result.
//=============================================================================

`ifndef CELERIS64_PKG_SV
`define CELERIS64_PKG_SV

package celeris64_pkg;

  //---------------------------------------------------------------------------
  // §1 / §2 Machine parameters
  //---------------------------------------------------------------------------
  localparam int unsigned XLEN      = 64;   // §1: data word and instruction word
  localparam int unsigned INSN_W    = 64;   // §1: fixed 64-bit instruction
  localparam int unsigned GPR_COUNT = 12;   // §1: R0-R11 (AGENTS.md §2.1)
  localparam logic [3:0]   GPR_INDEX_MAX = 4'd11;  // §4: indices 0-11 are R0-R11

  //---------------------------------------------------------------------------
  // §2 Word Layout
  //
  //  63        56 55    52 51    48 47                            0
  // +------------+--------+--------+-------------------------------+
  // |   opcode   |  rd    |  rs1   |          operand field        |
  // +------------+--------+--------+-------------------------------+
  //     8 bits     4 bits   4 bits              48 bits
  //---------------------------------------------------------------------------
  localparam int unsigned OP_W      = 8;    // §2 opcode[63:56]
  localparam int unsigned RD_W      = 4;    // §2 rd[55:52]
  localparam int unsigned RS1_W     = 4;    // §2 rs1[51:48]
  localparam int unsigned OPERAND_W = 48;   // §2 operand[47:0]

  //---------------------------------------------------------------------------
  // §3.1 ALU operand field layout (shared by §3.1 ALU and §3.2.1 compare)
  //
  // Contract v1.2 (Amendment 1.2) corrected this diagram. v1.1 drew a 40-bit
  // immediate (`imm28[39:0]`), which was geometrically self-consistent — rs2 (4)
  // + width (4) + 40 = exactly the 48-bit operand field — but contradicted the
  // field's own name, the §3.1 prose "signed 28-bit immediate", assembler.zig's
  // signed-28-bit range check and decoder.zig's `u28`. The width is 28; the
  // drawing was the defect. Bits [39:28] are now reserved `zero` and MUST be
  // zero — a non-zero value is a diagnostic error (§7).
  //
  //  47      44 43   40 39    28 27                            0
  // +----------+-------+--------+-------------------------------+
  // |   rs2    | width |  zero  |            imm28              |
  // +----------+-------+--------+-------------------------------+
  //    4 bits    4 bits  12 bits              28 bits
  //---------------------------------------------------------------------------
  localparam int unsigned RS2_W        = 4;   // §3.1 rs2[47:44]
  localparam int unsigned ALUWIDTH_W   = 4;   // §3.1 width[43:40]
  localparam int unsigned IMM28_W      = 28;  // §3.1 signed imm28[27:0]
  localparam int unsigned ALU_ZERO_W   = 12;  // §3.1 zero[39:28], reserved, must be 0

  //---------------------------------------------------------------------------
  // §3.2.2 select operand layout (owned by rtl/select_unit.sv)
  //   match[47:44] | trueReg[43:40] | falseReg[39:36]
  //---------------------------------------------------------------------------

  //---------------------------------------------------------------------------
  // §3.3 field.* operand layout (owned by rtl/field_unit.sv)
  //   offset[47:40] | width[39:32] | src2[31:28]
  //---------------------------------------------------------------------------

  //---------------------------------------------------------------------------
  // §3.4 stream.* operand layout (owned by rtl/stream_engine.sv)
  //   rs2[47:44] | chunk[43:24] | element width[23:20] | reserved[19:0]
  //---------------------------------------------------------------------------

  //---------------------------------------------------------------------------
  // §3.6 accelerator operand layout (Amendment 1.1, owned by rtl/accel.sv)
  //   rs2[47:44] | rs3[43:40] | reserved[39:32] | count[31:0]
  //---------------------------------------------------------------------------
  localparam int unsigned ACC_COUNT_W = 32;

  //---------------------------------------------------------------------------
  // §3 Opcode map — major opcode byte. One constant per §3 table row.
  // Cross-checked against src/decoder.zig `Opcode.fromByte` (all 30 rows).
  //---------------------------------------------------------------------------
  typedef enum logic [OP_W-1:0] {
    // §3.0 Control (high nibble 0x0)
    OP_NOP   = 8'h00,
    OP_HALT  = 8'h01,
    OP_JUMP  = 8'h02,
    OP_CALL  = 8'h03,
    OP_RET   = 8'h04,

    // §3.1 ALU (high nibble 0x1)
    OP_ADD   = 8'h10,
    OP_SUB   = 8'h11,
    OP_MUL   = 8'h12,
    OP_DIV   = 8'h13,
    OP_AND   = 8'h14,
    OP_OR    = 8'h15,
    OP_XOR   = 8'h16,
    OP_SHL   = 8'h17,
    OP_SHR   = 8'h18,
    OP_MOV   = 8'h19,

    // §3.2 Comparison and branchless select (high nibble 0x2)
    OP_COMPARE = 8'h20,
    OP_SELECT  = 8'h21,

    // §3.3 Field slicing (high nibble 0x3)
    OP_FIELD_EXTRACT = 8'h30,
    OP_FIELD_INSERT  = 8'h31,

    // §3.4 Stream engine (high nibble 0x4)
    OP_STREAM_ADD  = 8'h40,
    OP_STREAM_COPY = 8'h41,
    OP_STREAM_FILL = 8'h42,
    OP_STREAM_SETP = 8'h43,

    // §3.5 Capability instructions (high nibble 0x5)
    OP_CAP_LOAD  = 8'h50,
    OP_CAP_STORE = 8'h51,
    OP_CAP_CHECK = 8'h52,

    // §3.6 Accelerator space 0x60-0x8F. 0x60-0x6F matrix, 0x70-0x7F fft,
    // 0x80-0x8F codec. Only opcodes with a normative table row get a constant;
    // an unassigned byte in the range is *reserved* and must round-trip as raw
    // bytes rather than being reinterpreted as a neighbour (Amendment 1.1).
    OP_MATRIX_DET       = 8'h60,
    OP_MATRIX_INVERT    = 8'h61,
    OP_MATRIX_MUL       = 8'h62,
    OP_MATRIX_TRANSFORM = 8'h63,
    OP_MATRIX_IDENTITY  = 8'h64,
    OP_FFT_FORWARD      = 8'h70,
    OP_FFT_INVERSE      = 8'h71,
    OP_FFT_NTT          = 8'h72,
    OP_FFT_NTT_INVERSE  = 8'h73,
    OP_CODEC_COMPRESS   = 8'h80,
    OP_CODEC_DECOMPRESS = 8'h81,
    OP_CODEC_FNV1A      = 8'h82,
    OP_CODEC_CHECKSUM16 = 8'h83,

    // §3.7 Thread instructions (high nibble 0x9)
    OP_THREAD_SPAWN = 8'h90,
    OP_THREAD_JOIN  = 8'h91,
    OP_THREAD_YIELD = 8'h92
  } opcode_e;

  // §3.6 accelerator range bound, used for the "reserved, do not reinterpret"
  // rule (Amendment 1.1) and for the matrix/fft/codec split by high nibble.
  localparam logic [OP_W-1:0] ACC_OP_LO = 8'h60;
  localparam logic [OP_W-1:0] ACC_OP_HI = 8'h8F;

  //---------------------------------------------------------------------------
  // §4 Register Index Encoding
  //---------------------------------------------------------------------------
  localparam logic [RD_W-1:0] REG_SP    = 4'd12;  // §4
  localparam logic [RD_W-1:0] REG_LR    = 4'd13;  // §4
  localparam logic [RD_W-1:0] REG_PC    = 4'd14;  // §4
  localparam logic [RD_W-1:0] REG_FLAGS = 4'd15;  // §4

  // §4: ZERO has no index — it is expressed by omitting a write target. Code that
  // needs a zero uses the literal immediate 0. There is deliberately no REG_ZERO.

  //---------------------------------------------------------------------------
  // §5 Width Suffix Encoding
  //
  //  value  suffix  bits  register write behaviour
  //    0     none     64   full write
  //    1     .l       32   write low 32, ZERO-EXTEND upper 32
  //    2     .w       16   write low 16, ZERO-EXTEND upper 48
  //    3     .b        8   write low  8, ZERO-EXTEND upper 56
  //  4-15 reserved, diagnostic error
  //
  // Zero-extension is mandatory and observable (AGENTS.md §2.1, spec §2.2). It is
  // the mechanism that removes partial-register stall dependencies, so the regfile
  // clears the upper bits rather than preserving them.
  //---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    WIDTH_FULL = 4'd0,  // §5: 64-bit, full write
    WIDTH_L    = 4'd1,  // §5: .l, 32-bit, zero-extend upper 32
    WIDTH_W    = 4'd2,  // §5: .w, 16-bit, zero-extend upper 48
    WIDTH_B    = 4'd3   // §5: .b,  8-bit, zero-extend upper 56
  } width_e;

  /// §5: reserved encodings 4-15 are a diagnostic error, not a guessed width.
  /// Synthesizable predicate: the regfile refuses such a write (no write strobe).
  function automatic logic width_enc_is_legal(input logic [3:0] enc);
    return (enc <= 4'd3);
  endfunction

  /// §5: the bit count a width suffix names.
  function automatic logic [6:0] width_bits(input width_e w);
    case (w)
      WIDTH_FULL: width_bits = 7'd64;
      WIDTH_L:    width_bits = 7'd32;
      WIDTH_W:    width_bits = 7'd16;
      WIDTH_B:    width_bits = 7'd8;
      default:    width_bits = 7'd64;
    endcase
  endfunction

  /// §5: the write mask that implements the mandatory zero-extension. Applying
  /// `value & width_mask(w)` to the full 64-bit ALU result and writing the result
  /// is exactly "write low N, zero-extend upper 64-N".
  function automatic logic [XLEN-1:0] width_mask(input width_e w);
    case (w)
      WIDTH_FULL: width_mask = {XLEN{1'b1}};
      WIDTH_L:    width_mask = 64'h0000_0000_FFFF_FFFF;
      WIDTH_W:    width_mask = 64'h0000_0000_0000_FFFF;
      WIDTH_B:    width_mask = 64'h0000_0000_0000_00FF;
      default:    width_mask = {XLEN{1'b1}};
    endcase
  endfunction

  //---------------------------------------------------------------------------
  // §3.2.1 compare status enum. The enum is the ONLY sanctioned result of a
  // comparison; a bare 0/1 boolean is a spec violation.
  //---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    STATUS_EQUAL            = 4'd0,  // rs1 == src2
    STATUS_LESS             = 4'd1,  // rs1 <  src2, signed
    STATUS_GREATER          = 4'd2,  // rs1 >  src2, signed
    STATUS_UNSIGNED_LESS    = 4'd3,  // rs1 <  src2, unsigned
    STATUS_UNSIGNED_GREATER = 4'd4   // rs1 >  src2, unsigned
  } status_e;

  //---------------------------------------------------------------------------
  // §2 Decoded word
  //
  // The 64-bit word and its §2 field split, decoded once. `rs2`, `alu_width_raw`
  // and `imm28` are the §3.1 view of `operand`; they are computed unconditionally
  // (they are a pure bit slice, never an interpretation) but only MEAN rs2/width/
  // immediate for opcodes whose §3 table row says so. `accel_reserved` and
  // `accel_count` are the §3.6 view of the same bits.
  //---------------------------------------------------------------------------
  typedef struct packed {
    logic [OP_W-1:0]      opcode;        // §2 opcode[63:56]
    logic [RD_W-1:0]      rd;            // §2 rd[55:52],    §4 index
    logic [RS1_W-1:0]     rs1;           // §2 rs1[51:48],   §4 index
    logic [OPERAND_W-1:0] operand;       // §2 operand[47:0]

    // §3.1 view (v1.2: immediate is 28 bits, bits [39:28] are reserved zero)
    logic [RS2_W-1:0]     rs2;           // §3.1 rs2[47:44]
    logic [ALUWIDTH_W-1:0] alu_width_raw; // §3.1 width[43:40], raw: 4-15 reserved (§5)
    logic [IMM28_W-1:0]   imm28;         // §3.1 imm28[27:0], signed
    logic [ALU_ZERO_W-1:0] alu_zero;     // §3.1 zero[39:28], reserved: must be 0 (§7)
    logic signed [XLEN-1:0] imm_sext;    // §3.1 imm28 sign-extended to 64 bits

    // §3.6 view (Amendment 1.1)
    logic [7:0]           accel_reserved; // must be zero, else diagnostic error
    logic [ACC_COUNT_W-1:0] accel_count;  // 0 means "derive from destination"
  } decoded_word_t;

  /// §2: split a 64-bit word into its four §2 fields. Pure bit slicing.
  function automatic decoded_word_t unpack_word(input logic [INSN_W-1:0] word);
    decoded_word_t d;
    d.opcode        = word[63:56];                              // §2
    d.rd            = word[55:52];                              // §2
    d.rs1           = word[51:48];                              // §2
    d.operand       = word[47:0];                               // §2
    d.rs2           = word[47:44];                              // §3.1
    d.alu_width_raw = word[43:40];                              // §3.1
    d.imm28         = word[27:0];                               // §3.1 v1.2: imm28[27:0]
    d.alu_zero      = word[39:28];                              // §3.1 v1.2: reserved, must be 0
    // §3.1: signed 28-bit immediate, sign-extended to 64 bits. Replicate bit 27.
    d.imm_sext      = {{(XLEN-IMM28_W){word[27]}}, word[27:0]};
    d.accel_reserved = word[39:32];                             // §3.6 Amendment 1.1
    d.accel_count    = word[31:0];                              // §3.6 Amendment 1.1
    return d;
  endfunction

  /// §2: rebuild a word from its fields. The literal inverse of unpack_word's
  /// §2 half; provided so an RTL testbench can assemble a vector the same way
  /// src/decoder.zig `assembleWord` does, instead of hand-writing hex.
  function automatic logic [INSN_W-1:0] pack_word(
      input logic [OP_W-1:0]      opcode,
      input logic [RD_W-1:0]      rd,
      input logic [RS1_W-1:0]     rs1,
      input logic [OPERAND_W-1:0] operand);
    return {opcode, rd, rs1, operand};                          // §2 MSB-first layout
  endfunction

  /// §3.1 (v1.2): build the ALU operand field:
  ///   rs2[47:44] | width[43:40] | zero[39:28] | imm28[27:0]
  /// `alu_zero` is the reserved field and defaults to zero, which is the only
  /// value the contract accepts (§7 diagnostic otherwise).
  function automatic logic [OPERAND_W-1:0] pack_alu_operand(
      input logic [RS2_W-1:0]     rs2,
      input logic [ALUWIDTH_W-1:0] width_raw,
      input logic [IMM28_W-1:0]   imm28,
      input logic [ALU_ZERO_W-1:0] alu_zero = {ALU_ZERO_W{1'b0}});
    return {rs2, width_raw, alu_zero, imm28};                   // §3.1 v1.2
  endfunction

  //---------------------------------------------------------------------------
  // §3.1 immediate-form rule
  //
  // "If imm28 != 0, the instruction is immediate-form and rs2 is ignored."
  // A zero imm28 is therefore the register form. This is a positive predicate so
  // the ALU does not re-derive the rule from the raw bits in two places.
  //
  // v1.2 note: because imm28 is now [27:0], a word carrying bits in [39:28] and
  // a zero imm28 is REGISTER-form, not immediate-form. Under the v1.1 40-bit
  // reading the same word was immediate-form, which is the exact divergence that
  // prompted Amendment 1.2. decoder.zig reads `@truncate(operand)` as u28, so
  // this rule and the decoder now agree bit-for-bit.
  //---------------------------------------------------------------------------
  function automatic logic alu_is_immediate(input logic [IMM28_W-1:0] imm28);
    return (imm28 != {IMM28_W{1'b0}});
  endfunction

  /// §3.1 (v1.2) + §7: the reserved field zero[39:28] must be zero. A non-zero
  /// value is a diagnostic error, so this predicate lets a caller REJECT the word
  /// rather than silently ignore the bits (which is the round-trip bug the
  /// reserved field exists to prevent).
  function automatic logic alu_zero_is_reserved_ok(input logic [ALU_ZERO_W-1:0] alu_zero);
    return (alu_zero == {ALU_ZERO_W{1'b0}});
  endfunction

  //---------------------------------------------------------------------------
  // §3.6 Amendment 1.1: reserved accelerator opcodes must NOT be silently
  // reinterpreted as a neighbouring operation.
  //---------------------------------------------------------------------------
  function automatic logic is_accelerator_opcode(input logic [OP_W-1:0] op);
    return (op >= ACC_OP_LO) && (op <= ACC_OP_HI);
  endfunction

  function automatic logic is_matrix_opcode(input logic [OP_W-1:0] op);
    return (op >= 8'h60) && (op <= 8'h6F);
  endfunction

  function automatic logic is_fft_opcode(input logic [OP_W-1:0] op);
    return (op >= 8'h70) && (op <= 8'h7F);
  endfunction

  function automatic logic is_codec_opcode(input logic [OP_W-1:0] op);
    return (op >= 8'h80) && (op <= 8'h8F);
  endfunction

endpackage

`endif  // CELERIS64_PKG_SV
