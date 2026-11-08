//=============================================================================
// alu_tb.sv — CLS64 ALU + regfile testbench (Verilator 5.x --binary)
//
// Drives rtl/alu.sv and rtl/regfile.sv with hand-computed §3.1 / §5 / §4 vectors.
// Every expected value below is computed by hand from docs/isa-encoding.md v1.1
// and written as a literal — none is produced by the DUT and copied back, so a
// wrong encoding fails rather than agreeing with itself.
//
// FIDELITY (docs/isa-encoding.md §8): this is SIMULATION of a lint-verified
// specification. It has never been synthesized, never timing-closed, never on
// silicon, and no clock frequency is claimed.
//
// Testbench hygiene: rtl/ synthesizable modules contain no `initial` and no
// delays; this file is under rtl/tb/ and is the only place either appears.
//
// There is deliberately NO `timescale` directive here. The synthesizable modules
// are forbidden one, and a testbench-local timescale makes Verilator raise
// TIMESCALEMOD against every module that lacks it. The clock period below is a
// testbench stimulus interval only — no clock frequency is claimed for the RTL,
// which has never been synthesized (contract §8).
//=============================================================================

module alu_tb
  import celeris64_pkg::*;
();

  //---------------------------------------------------------------------------
  // DUT signals
  //---------------------------------------------------------------------------
  logic                 clk;
  logic                 rst_ni;

  logic [OP_W-1:0]      opcode;
  logic [ALUWIDTH_W-1:0] width_raw;
  logic [IMM28_W-1:0]   imm28;
  logic [ALU_ZERO_W-1:0] alu_zero;    // §3.1 v1.2 reserved zero[39:28]
  logic [XLEN-1:0]      rs1_val;
  logic [XLEN-1:0]      rs2_val;

  logic [XLEN-1:0]      alu_result;
  logic                 alu_div_zero;
  logic                 alu_width_err;
  logic                 alu_zero_err;
  logic                 alu_op_legal;

  logic [RD_W-1:0]      raddr_a, raddr_b;
  logic [XLEN-1:0]      rdata_a, rdata_b;
  logic                 rf_we;
  logic [RD_W-1:0]      rf_waddr;
  logic [ALUWIDTH_W-1:0] rf_width_raw;
  logic [XLEN-1:0]      rf_wdata;
  logic                 rf_width_err;

  //---------------------------------------------------------------------------
  // Pass/fail bookkeeping. A `$fatal` would abort on the first mismatch and hide
  // how many vectors agreed, so failures are counted and the process exits
  // non-zero with a real FAIL line. Silence is never success here.
  //---------------------------------------------------------------------------
  int unsigned checks = 0;
  int unsigned failures = 0;

  alu u_alu (
    .opcode_i    (opcode),
    .width_raw_i (width_raw),
    .imm28_i     (imm28),
    .alu_zero_i  (alu_zero),
    .rs1_val_i   (rs1_val),
    .rs2_val_i   (rs2_val),
    .result_o    (alu_result),
    .div_zero_o  (alu_div_zero),
    .width_err_o (alu_width_err),
    .zero_err_o  (alu_zero_err),
    .op_legal_o  (alu_op_legal)
  );

  regfile u_regfile (
    .clk_i        (clk),
    .rst_ni       (rst_ni),
    .raddr_a_i    (raddr_a),
    .rdata_a_o    (rdata_a),
    .raddr_b_i    (raddr_b),
    .rdata_b_o    (rdata_b),
    .we_i         (rf_we),
    .waddr_i      (rf_waddr),
    .width_raw_i  (rf_width_raw),
    .wdata_i      (rf_wdata),
    .width_err_o  (rf_width_err)
  );

  //---------------------------------------------------------------------------
  // Clock. 10 ns period, purely a testbench artefact: no timing claim is made
  // about the RTL, which has never been synthesized (contract §8).
  //---------------------------------------------------------------------------
  initial clk = 1'b0;
  always #5 clk = ~clk;

  //---------------------------------------------------------------------------
  // Assertion helpers
  //---------------------------------------------------------------------------
  task automatic check64(input string name, input logic [XLEN-1:0] got, input logic [XLEN-1:0] exp);
    begin
      checks++;
      if (got !== exp) begin
        failures++;
        $display("FAIL %-46s got=0x%016x exp=0x%016x", name, got, exp);
      end else begin
        $display("  ok %-46s = 0x%016x", name, got);
      end
    end
  endtask

  task automatic check1(input string name, input logic got, input logic exp);
    begin
      checks++;
      if (got !== exp) begin
        failures++;
        $display("FAIL %-46s got=%0b exp=%0b", name, got, exp);
      end else begin
        $display("  ok %-46s = %0b", name, got);
      end
    end
  endtask

  // Writes one full-width GPR value and checks it landed (used to seed the
  // "upper bits were all ones" precondition for the zero-extension tests).
  task automatic seed_reg(input logic [RD_W-1:0] idx, input logic [XLEN-1:0] val);
    begin
      rf_we = 1'b1; rf_waddr = idx; rf_width_raw = WIDTH_FULL; rf_wdata = val;
      @(posedge clk);
      #1;
      rf_we = 1'b0;
      @(posedge clk);
      #1;
      raddr_a = idx;
      #1;
    end
  endtask

  //---------------------------------------------------------------------------
  // Main vector sequence
  //---------------------------------------------------------------------------
  initial begin
    $display("=== CLS64 rtl/alu.sv + rtl/regfile.sv testbench (contract v1.2) ===");

    // ---- reset ------------------------------------------------------------
    rst_ni = 1'b0;
    rf_we  = 1'b0;
    rf_waddr = '0; rf_width_raw = '0; rf_wdata = '0;
    raddr_a = '0; raddr_b = '0;
    opcode = '0; width_raw = '0; imm28 = '0; alu_zero = '0;
    rs1_val = '0; rs2_val = '0;
    repeat (2) @(posedge clk);
    #1;
    rst_ni = 1'b1;
    @(posedge clk);
    #1;

    // =======================================================================
    // GROUP 1 — §2/§3.1 bit layout of a hand-assembled add word
    //
    // add R1, R2, R3, full width, register form:
    //   opcode 0x10 | rd=1 | rs1=2 | rs2=3 | width=0 | imm28=0
    //   word = 0x1012_3000_0000_0000
    //
    // The operand field of a register-form add is rs2<<44 = 0x3 << 44
    //   = 0x0030_0000_0000. Adding the §2 opcode/rd/rs1 gives the word below.
    // =======================================================================
    $display("-- group 1: §2 word layout (hand-assembled add R1,R2,R3) --");
    begin
      logic [INSN_W-1:0] word;
      decoded_word_t     d;
      word = 64'h1012_3000_0000_0000;                  // hand-computed, see above
      d = unpack_word(word);
      check64("§2 word[63:56] opcode", {56'd0, d.opcode}, 64'h0000_0000_0000_0010);
      check64("§2 word[55:52] rd",     {60'd0, d.rd},     64'h0000_0000_0000_0001);
      check64("§2 word[51:48] rs1",    {60'd0, d.rs1},    64'h0000_0000_0000_0002);
      check64("§3.1 word[47:44] rs2",  {60'd0, d.rs2},    64'h0000_0000_0000_0003);
      check64("§3.1 word[43:40] width",{60'd0, d.alu_width_raw}, 64'h0);
      check64("§3.1 v1.2 zero[39:28]", {52'd0, d.alu_zero}, 64'h0);
      // §3.1: imm28 == 0 means register form, so rs2 is the source.
      check1 ("§3.1 imm28==0 -> register form", alu_is_immediate(d.imm28), 1'b0);
      // §3.6 Amendment 1.1 views of the same operand bits: reserved[39:32] is
      // zero in this word, and count[31:0] is the low 32 bits.
      check64("§3.6 accel_reserved = 0", {56'd0, d.accel_reserved}, 64'h0);
      check64("§3.6 accel_count", {32'd0, d.accel_count}, 64'h0);
      // §3.1: imm_sext of a zero imm28 is zero.
      check64("§3.1 imm_sext of 0", d.imm_sext, 64'h0);
      check64("§2 pack_word round-trip", pack_word(d.opcode, d.rd, d.rs1, d.operand), word);
    end

    // A NEGATIVE layout check: if rs2 were read from the wrong bit position the
    // word above would still decode, but this word puts a marker in bits [47:44]
    // ONLY. rs2 must be 0xA and the width must be 0 and imm28 must be 0.
    begin
      logic [INSN_W-1:0] word;
      decoded_word_t     d;
      word = pack_word(OP_ADD, 4'd0, 4'd0, 48'hA000_0000_0000);
      d = unpack_word(word);
      check64("NEG §3.1 rs2 sits at [47:44] only", {60'd0, d.rs2}, 64'hA);
      check64("NEG §3.1 width still 0",            {60'd0, d.alu_width_raw}, 64'h0);
      check64("NEG §3.1 imm28 still 0",            {36'd0, d.imm28}, 64'h0);
      check64("NEG §3.1 zero[39:28] still 0",      {52'd0, d.alu_zero}, 64'h0);
      check64("NEG §3.6 reserved still 0",         {56'd0, d.accel_reserved}, 64'h0);
      check64("NEG §3.6 count still 0",            {32'd0, d.accel_count}, 64'h0);
      check64("NEG §3.1 imm_sext still 0",         d.imm_sext, 64'h0);
      // Consume the whole 216-bit struct: every field of the §2/§3.1/§3.6 decode
      // of this word must equal this hand-computed packed value.
      //
      // The constant is written as a 216-bit literal rather than a concatenation:
      // an unsized/`64'd0` concatenation operand is self-determined, so the concat
      // total came out 232 bits and the comparison failed for a reason that had
      // nothing to do with the DUT. The literal below is the concatenation of
      // opcode|rd|rs1|operand|rs2|width|imm28|alu_zero|imm_sext|reserved|count,
      // MSB first (v1.2 added the 12-bit alu_zero field).
      check1("NEG whole struct (216b) matches",
             216'(d) === 216'h1000a00000000000a0000000000000000000000000000000000000,
             1'b1);
    end

    // §3.1 v1.2 sign-extension, checked on the package's own unpack. imm28 is a
    // 28-BIT field (imm28[27:0]) per Amendment 1.2, so its sign bit is bit 27 and
    // 0x800_0000 (bit 27 set) is the most negative 28-bit value. It must
    // sign-extend to 0xFFFFFFFFF8000000 — NOT to 0x0000000080000000, which a
    // zero-extending unpack would produce.
    begin
      logic [INSN_W-1:0] word;
      decoded_word_t     d;
      word = pack_word(OP_MOV, 4'd1, 4'd0, pack_alu_operand(4'd0, WIDTH_FULL, 28'h800_0000));
      d = unpack_word(word);
      check64("NEG §3.1 imm28 sign-extends bit 27", d.imm_sext, 64'hFFFF_FFFF_F800_0000);
      check64("NEG §3.1 rs2 restored from operand", {60'd0, d.rs2}, 64'h0);
      check64("NEG §3.1 imm28 field itself", {36'd0, d.imm28}, 64'h800_0000);
      check64("NEG §3.1 zero field is 0", {52'd0, d.alu_zero}, 64'h0);
      // §3.6 views of the same operand bits, so nothing in the struct goes
      // unobserved. operand = 0x0000_0800_0000 here, so reserved[39:32] = 0x00
      // and count[31:0] = 0x0800_0000.
      check64("NEG §3.6 accel_reserved", {56'd0, d.accel_reserved}, 64'h00);
      check64("NEG §3.6 accel_count", {32'd0, d.accel_count}, 64'h0800_0000);
      // Whole-struct check, 216-bit literal. Covers every remaining field
      // explicitly. Fields MSB first:
      //   opcode|rd|rs1|operand|rs2|width|imm28|alu_zero|imm_sext|reserved|count
      //   operand  = 0x0000_0800_0000 (rs2=0, width=0, zero=0, imm28=0x800_0000)
      //   imm_sext = 0xFFFF_FFFF_F800_0000  (bit 27 replicated into [63:28])
      // If imm_sext were zero-extended this comparison fails on that field.
      check1("NEG whole struct (216b) with sign-extended imm",
             216'(d) === 216'h1910000008000000008000000000fffffffff80000000008000000,
             1'b1);
    end

    // =======================================================================
    // §3.1 v1.2 REGRESSION — the exact word that motivated Amendment 1.2.
    //
    // Under the v1.1 40-bit reading, operand bit 39 was part of the immediate, so
    // this word was immediate-form. Under v1.2, imm28 is [27:0], so bit 39 lands
    // in the reserved `zero` field and imm28 == 0: the word is REGISTER-form and
    // rs2 is the source. This is the divergence rtl-core found by cross-checking
    // decoder.zig, and it is pinned here so it cannot silently regress.
    //
    // operand[39:0] = 0x80_0000_0000 (bit 39 set, bit 27 clear)
    // =======================================================================
    $display("-- §3.1 v1.2 regression: bit 39 set, bit 27 clear --");
    begin
      logic [INSN_W-1:0] word;
      decoded_word_t     d;
      word = pack_word(OP_ADD, 4'd1, 4'd2, 48'h0080_0000_0000);
      d = unpack_word(word);
      check64("REG v1.2 imm28 == 0 with bit39 set", {36'd0, d.imm28}, 64'h0);
      check64("REG v1.2 zero[39:28] == 0x800", {52'd0, d.alu_zero}, 64'h800);
      // The decisive assertion: register-form, so rs2 (not the immediate) drives.
      check1 ("REG v1.2 bit39-set word is REGISTER form", alu_is_immediate(d.imm28), 1'b0);
      check64("REG v1.2 imm_sext is 0", d.imm_sext, 64'h0);
      // §3.6 views of the same bits. operand = 0x0080_0000_0000, so
      // reserved[39:32] = 0x80 and count[31:0] = 0x0000_0000.
      check64("REG v1.2 accel_reserved", {56'd0, d.accel_reserved}, 64'h80);
      check64("REG v1.2 accel_count", {32'd0, d.accel_count}, 64'h0000_0000);
      // Whole-struct check (216-bit literal) so no field of this decisive word is
      // left unobserved. Fields MSB first:
      //   opcode|rd|rs1|operand|rs2|width|imm28|alu_zero|imm_sext|reserved|count
      //   0x10 | 1 | 2 | 0x008000000000 | 0|0| 0 | 0x080 | 0 | 0x80 | 0x80000000
      check1("REG v1.2 whole struct (216b)",
             216'(d) === 216'h101200800000000000000000080000000000000000008000000000,
             1'b1);
    end

    // =======================================================================
    // GROUP 2 — the ten §3.1 ops, register form, full width
    // =======================================================================
    $display("-- group 2: ten §3.1 ops, register form, full width --");
    width_raw = WIDTH_FULL;
    imm28     = 28'd0;             // §3.1: imm28==0 -> register form, rs2 used

    // add 0x10: 0xFFFF_FFFF_FFFF_FFFF + 1 = 0x0000_0000_0000_0000 (wraps at 64)
    opcode = OP_ADD; rs1_val = 64'hFFFF_FFFF_FFFF_FFFF; rs2_val = 64'd1;
    #1; check64("0x10 add wrap",  alu_result, 64'h0000_0000_0000_0000);
    check1("0x10 op_legal", alu_op_legal, 1'b1);

    // sub 0x11: 0x10 - 0x1 = 0xF
    opcode = OP_SUB; rs1_val = 64'h10; rs2_val = 64'h1;
    #1; check64("0x11 sub",       alu_result, 64'hF);

    // mul 0x12: 0x1_0000_0000 * 0x1_0000_0000 = 2^64 -> low 64 bits = 0
    opcode = OP_MUL; rs1_val = 64'h1_0000_0000; rs2_val = 64'h1_0000_0000;
    #1; check64("0x12 mul low 64 bits", alu_result, 64'h0);

    // div 0x13: 100 / 7 = 14 (0xE)
    opcode = OP_DIV; rs1_val = 64'd100; rs2_val = 64'd7;
    #1; check64("0x13 div",       alu_result, 64'hE);
    check1("0x13 div no zero flag", alu_div_zero, 1'b0);

    // div by zero 0x13: §3.1 says diagnostic, not trap. Result must be 0 and the
    // zero flag must be raised.
    opcode = OP_DIV; rs1_val = 64'd100; rs2_val = 64'd0;
    #1; check64("0x13 div-by-zero result", alu_result, 64'h0);
    check1("0x13 div-by-zero flag", alu_div_zero, 1'b1);

    // and 0x14: 0xF0F0 & 0xFF00 = 0xF000
    opcode = OP_AND; rs1_val = 64'hF0F0; rs2_val = 64'hFF00;
    #1; check64("0x14 and",       alu_result, 64'hF000);

    // or 0x15: 0xF0F0 | 0x0F0F = 0xFFFF
    opcode = OP_OR; rs1_val = 64'hF0F0; rs2_val = 64'h0F0F;
    #1; check64("0x15 or",        alu_result, 64'hFFFF);

    // xor 0x16: 0xFFFF ^ 0x0F0F = 0xF0F0
    opcode = OP_XOR; rs1_val = 64'hFFFF; rs2_val = 64'h0F0F;
    #1; check64("0x16 xor",       alu_result, 64'hF0F0);

    // shl 0x17: 1 << 40 = 0x0000_0100_0000_0000
    opcode = OP_SHL; rs1_val = 64'd1; rs2_val = 64'd40;
    #1; check64("0x17 shl by 40", alu_result, 64'h0000_0100_0000_0000);

    // shr 0x18 (logical): 0x8000_0000_0000_0000 >> 4 = 0x0800_0000_0000_0000
    // A logical shift, so the sign bit does NOT smear.
    opcode = OP_SHR; rs1_val = 64'h8000_0000_0000_0000; rs2_val = 64'd4;
    #1; check64("0x18 shr logical", alu_result, 64'h0800_0000_0000_0000);

    // mov 0x19: rd = src2, rs1 ignored. rs1 is deliberately garbage.
    opcode = OP_MOV; rs1_val = 64'hDEAD_BEEF_DEAD_BEEF; rs2_val = 64'hCAFE_F00D;
    #1; check64("0x19 mov ignores rs1", alu_result, 64'h0000_0000_CAFE_F00D);

    // An opcode outside 0x10-0x19 must be reported, not silently executed.
    opcode = OP_COMPARE; rs1_val = 64'd5; rs2_val = 64'd5;
    #1; check1("NEG non-ALU opcode 0x20 -> op_legal=0", alu_op_legal, 1'b0);

    // =======================================================================
    // GROUP 3 — §3.1 immediate form (imm28 != 0, rs2 ignored)
    // =======================================================================
    $display("-- group 3: §3.1 immediate form (v1.2: imm28[27:0]) --");
    // add Rd, Rs1, #1  with rs2 = 0xF (which must be ignored).
    opcode = OP_ADD; width_raw = WIDTH_FULL; imm28 = 28'd1;
    rs1_val = 64'h1000; rs2_val = 64'hF;
    #1; check64("§3.1 imm +1 ignores rs2", alu_result, 64'h1001);

    // Negative immediate: imm28 = -1 (all 28 bits set) sign-extends to
    // 0xFFFF_FFFF_FFFF_FFFF. add 0x10 + (-1) = 0xF.
    opcode = OP_ADD; imm28 = 28'hFFF_FFFF;  // -1 in 28 bits
    rs1_val = 64'h10; rs2_val = 64'h0;
    #1; check64("§3.1 imm28=-1 sign-extends", alu_result, 64'hF);

    // The most negative 28-bit immediate: imm28 = 0x800_0000 (bit 27 set)
    // sign-extends to 0xFFFF_FFFF_F800_0000. mov Rd, imm puts it straight into
    // the result, which is the cleanest proof of sign-extension.
    opcode = OP_MOV; imm28 = 28'h800_0000;
    #1; check64("§3.1 imm28 negative 28-bit sign-extends", alu_result, 64'hFFFF_FFFF_F800_0000);

    // The largest positive 28-bit immediate: 0x7FF_FFFF -> 0x0000_0000_07FF_FFFF,
    // so the sign bit is genuinely bit 27 and not a higher bit left over.
    opcode = OP_MOV; imm28 = 28'h7FF_FFFF;
    #1; check64("§3.1 max positive 28-bit imm", alu_result, 64'h0000_0000_07FF_FFFF);

    // §3.1 v1.2 + §7: a non-zero reserved field zero[39:28] is a diagnostic
    // error, reported on zero_err_o. It must NOT be silently ignored, so this
    // negative test fails if the reserved field is dropped on the floor.
    opcode = OP_MOV; imm28 = 28'd1; alu_zero = 12'h001;
    #1; check1("NEG §3.1 v1.2 zero[39:28]!=0 -> zero_err", alu_zero_err, 1'b1);
    alu_zero = 12'h800;
    #1; check1("NEG §3.1 v1.2 zero high bit -> zero_err", alu_zero_err, 1'b1);
    alu_zero = 12'h000;
    #1; check1("§3.1 v1.2 zero==0 -> no zero_err", alu_zero_err, 1'b0);

    // =======================================================================
    // GROUP 4 — §5 width applies to the RESULT, and zero-extends
    // =======================================================================
    $display("-- group 4: §5 sub-width result truncation + zero-extension --");
    imm28 = 28'd0; alu_zero = 12'd0;

    // .l = 32 bits. 0xFFFF_FFFF + 1 = 0x1_0000_0000; truncated to 32 bits -> 0.
    opcode = OP_ADD; width_raw = WIDTH_L;
    rs1_val = 64'h0000_0000_FFFF_FFFF; rs2_val = 64'd1;
    #1; check64("§5 .l truncates result to 32 bits", alu_result, 64'h0000_0000_0000_0000);

    // .b = 8 bits. 0xFF + 1 = 0x100; truncated to 8 bits -> 0x00.
    opcode = OP_ADD; width_raw = WIDTH_B;
    rs1_val = 64'hFF; rs2_val = 64'd1;
    #1; check64("§5 .b truncates result to 8 bits", alu_result, 64'h0000_0000_0000_0000);

    // .w = 16 bits. 0xFFFF + 1 = 0x1_0000; truncated to 16 bits -> 0.
    opcode = OP_ADD; width_raw = WIDTH_W;
    rs1_val = 64'hFFFF; rs2_val = 64'd1;
    #1; check64("§5 .w truncates result to 16 bits", alu_result, 64'h0000_0000_0000_0000);

    // The hand-computed zero-extension vector the task asks for, at the ALU:
    // mov.b Rd, 0xAB  ->  result is 0x0000_0000_0000_00AB, NOT 0x...FFFF_FFAB.
    // rs1 is deliberately all-ones so a "preserve the upper bits" bug is visible.
    opcode = OP_MOV; width_raw = WIDTH_B;
    rs1_val = 64'hFFFF_FFFF_FFFF_FFFF; rs2_val = 64'hAB;
    #1; check64("§5 hand vector mov.b 0xAB -> 0x..00AB", alu_result, 64'h0000_0000_0000_00AB);

    // Full width keeps all 64 bits — the contrast case for the vector above.
    opcode = OP_MOV; width_raw = WIDTH_FULL;
    rs1_val = 64'hFFFF_FFFF_FFFF_FFFF; rs2_val = 64'hDEAD_BEEF_CAFE_F00D;
    #1; check64("§5 full width keeps 64 bits", alu_result, 64'hDEAD_BEEF_CAFE_F00D);

    // §5: width 4-15 is reserved and must be reported, not treated as full width.
    opcode = OP_MOV; width_raw = 4'd4; rs2_val = 64'hFF;
    #1; check1("NEG §5 reserved width 4 -> width_err", alu_width_err, 1'b1);
    opcode = OP_MOV; width_raw = 4'd15; rs2_val = 64'hFF;
    #1; check1("NEG §5 reserved width 15 -> width_err", alu_width_err, 1'b1);
    opcode = OP_MOV; width_raw = WIDTH_B; rs2_val = 64'hFF;
    #1; check1("§5 legal width .b -> no width_err", alu_width_err, 1'b0);

    // =======================================================================
    // GROUP 5 — regfile: §4 index decode and the mandatory zero-extension
    //
    // This is the AGENTS.md §2.1 invariant the task requires be observable.
    // Each case first fills the register with all-ones, then performs a
    // sub-width write, then reads the FULL 64 bits back.
    // =======================================================================
    $display("-- group 5: regfile §4 index decode + §2.1 zero-extension --");

    // --- hand-computed vector: R3 := 0xFFFF_FFFF_FFFF_FFFF then write .b 0xAB --
    // Expected register contents after the sub-width write: 0x0000_0000_0000_00AB.
    // A regfile that preserved the upper bits would return
    // 0xFFFF_FFFF_FFFF_FFAB, which is the failure this vector exists to catch.
    seed_reg(4'd3, 64'hFFFF_FFFF_FFFF_FFFF);
    check64("seed R3 = all ones", rdata_a, 64'hFFFF_FFFF_FFFF_FFFF);

    rf_we = 1'b1; rf_waddr = 4'd3; rf_width_raw = WIDTH_B; rf_wdata = 64'hAB;
    @(posedge clk); #1; rf_we = 1'b0;
    raddr_a = 4'd3; #1;
    check64("HAND VECTOR .b write zero-extends R3", rdata_a, 64'h0000_0000_0000_00AB);
    check64("HAND VECTOR upper bits are zero, not stale",
            rdata_a & 64'hFFFF_FFFF_FFFF_FF00, 64'h0);

    // --- .w: fill all ones, write 0xBEEF -> 0x0000_0000_0000_BEEF ------------
    seed_reg(4'd3, 64'hFFFF_FFFF_FFFF_FFFF);
    rf_we = 1'b1; rf_waddr = 4'd3; rf_width_raw = WIDTH_W; rf_wdata = 64'hBEEF;
    @(posedge clk); #1; rf_we = 1'b0;
    raddr_a = 4'd3; #1;
    check64("§2.1 .w write zero-extends R3", rdata_a, 64'h0000_0000_0000_BEEF);

    // --- .l: fill all ones, write 0xDEAD_BEEF -> 0x0000_0000_DEAD_BEEF -------
    seed_reg(4'd3, 64'hFFFF_FFFF_FFFF_FFFF);
    rf_we = 1'b1; rf_waddr = 4'd3; rf_width_raw = WIDTH_L; rf_wdata = 64'hDEAD_BEEF;
    @(posedge clk); #1; rf_we = 1'b0;
    raddr_a = 4'd3; #1;
    check64("§2.1 .l write zero-extends R3", rdata_a, 64'h0000_0000_DEAD_BEEF);

    // --- full width preserves all 64 bits -----------------------------------
    seed_reg(4'd3, 64'h0);
    rf_we = 1'b1; rf_waddr = 4'd3; rf_width_raw = WIDTH_FULL;
    rf_wdata = 64'hDEAD_BEEF_CAFE_F00D;
    @(posedge clk); #1; rf_we = 1'b0;
    raddr_a = 4'd3; #1;
    check64("§5 full write keeps 64 bits", rdata_a, 64'hDEAD_BEEF_CAFE_F00D);

    // --- sub-width truncates a too-wide value -------------------------------
    seed_reg(4'd5, 64'h0);
    rf_we = 1'b1; rf_waddr = 4'd5; rf_width_raw = WIDTH_B; rf_wdata = 64'h1FF;
    @(posedge clk); #1; rf_we = 1'b0;
    raddr_a = 4'd5; #1;
    check64("§5 .b truncates 0x1FF to 0xFF", rdata_a, 64'h0000_0000_0000_00FF);

    // --- §4 index decode: 12 SP, 13 LR, 14 PC, 15 FLAGS ---------------------
    // Each is written at full width and read back on port A. idx is an int so
    // the loop bound is not a constant comparison on a 4-bit value.
    begin
      for (int unsigned idx = 12; idx <= 15; idx++) begin
        rf_we = 1'b1; rf_waddr = idx[3:0]; rf_width_raw = WIDTH_FULL;
        rf_wdata = 64'h1000 + 64'(idx);
        @(posedge clk); #1; rf_we = 1'b0;
        raddr_a = idx[3:0]; #1;
        check64("§4 system reg readback index", rdata_a, 64'h1000 + 64'(idx));
      end
    end

    // --- §4: indices 0-11 are REAL writable GPRs, so index 0 stores a value --
    // (Celeris-64 has no REG_ZERO index; ZERO is expressed by omitting a target.)
    seed_reg(4'd0, 64'h0);
    rf_we = 1'b1; rf_waddr = 4'd0; rf_width_raw = WIDTH_FULL; rf_wdata = 64'h1234_5678;
    @(posedge clk); #1; rf_we = 1'b0;
    raddr_a = 4'd0; #1;
    check64("§4 R0 is writable, not hardwired zero", rdata_a, 64'h1234_5678);

    // --- two read ports agree on the same index -----------------------------
    raddr_a = 4'd3; raddr_b = 4'd3; #1;
    check1("two read ports agree", rdata_a === rdata_b, 1'b1);

    // --- §5: a reserved width write is refused; the register is unchanged ----
    seed_reg(4'd7, 64'hAAAA_BBBB_CCCC_DDDD);
    rf_we = 1'b1; rf_waddr = 4'd7; rf_width_raw = 4'd4; rf_wdata = 64'hFFFF;
    @(posedge clk); #1;
    check1("NEG §5 reserved width write -> width_err", rf_width_err, 1'b1);
    rf_we = 1'b0;
    raddr_a = 4'd7; #1;
    check64("NEG reserved width write leaves reg unchanged",
            rdata_a, 64'hAAAA_BBBB_CCCC_DDDD);

    // =======================================================================
    // GROUP 6 — ALU result through the regfile, end to end
    // add.b R9, R3, R4 where R3 = 0x...00FF and R4 = 1 -> 0x100 -> .b -> 0x00
    // =======================================================================
    $display("-- group 6: ALU -> regfile end-to-end with §5 width --");
    seed_reg(4'd3, 64'h0000_0000_0000_00FF);
    seed_reg(4'd4, 64'h0000_0000_0000_0001);
    raddr_a = 4'd3; raddr_b = 4'd4; #1;
    opcode = OP_ADD; width_raw = WIDTH_B; imm28 = 28'd0;
    rs1_val = rdata_a; rs2_val = rdata_b;
    #1;
    check64("e2e add.b 0xFF + 1", alu_result, 64'h0);
    rf_we = 1'b1; rf_waddr = 4'd9; rf_width_raw = WIDTH_B; rf_wdata = alu_result;
    @(posedge clk); #1; rf_we = 1'b0;
    raddr_a = 4'd9; #1;
    check64("e2e R9 after add.b writeback", rdata_a, 64'h0);

    // =======================================================================
    // Verdict
    // =======================================================================
    $display("=== checks=%0d failures=%0d ===", checks, failures);
    if (failures == 0) begin
      $display("PASS: all %0d alu/regfile vectors matched (simulation only; RTL is NOT synthesized)", checks);
      $finish;
    end else begin
      $display("FAIL: %0d of %0d vectors mismatched", failures, checks);
      $fatal(1, "alu_tb failed: %0d mismatched vector(s)", failures);
    end
  end

endmodule
