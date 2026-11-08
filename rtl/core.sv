//=============================================================================
// core.sv — CLS64 top level: fetch, decode, dispatch, writeback
//
// Normative contract: docs/isa-encoding.md VERSION 1.14.
//   §1  fixed 64-bit instruction   -> PC stride is a constant 8 bytes, always
//   §2  word layout                -> opcode[63:56] | rd[55:52] | rs1[51:48] | operand[47:0]
//   §3  opcode map                 -> dispatch on opcode[63:56], §3.0-§3.7
//   §3.0 control                   -> jump/call/ret move PC; call ALSO sets LR
//   §4  register indices           -> 0-11 R0-R11, 12 SP, 13 LR, 14 PC, 15 FLAGS
//   §5  width suffix               -> applied by alu.sv and regfile.sv
//
// WHY THE FETCH IS THIS SIMPLE. §1 fixes instruction width at 64 bits, and §1
// says why: "it makes fetch a constant stride, makes PC advance trivially, and
// makes the decoder a pure function of one word with no lookahead." This module
// is the payoff — PC + 8 unconditionally, except for the three §3.0 control
// instructions. There is no instruction-length decoder here and never must be.
//
// THE call/LR BUG THIS FILE EXISTS TO NOT HAVE (contract §3.0 row 0x03):
//
//   `call` sets LR to the address of the NEXT instruction. `jump` does NOT touch
//   LR. Conflating them was a real defect found and fixed in the Zig VM: every
//   subroutine returned to address 0 because LR was never written. It comes back
//   the instant someone writes `lr_d = pc_q` (the address of the call itself,
//   which re-enters the call forever) instead of `pc_q + 8`.
//
//   The value is `pc_next` — the SAME expression the straight-line advance uses,
//   so the two cannot drift apart. rtl/tb/core_tb.sv pins it as an explicit
//   vector and rtl/CROSSCHECK.md cross-checks it against the Zig VM.
//
// FIDELITY (docs/isa-encoding.md §8) — READ BEFORE QUOTING ANY NUMBER:
//   Lint-verified specification plus SIMULATION. NEVER synthesized (no yosys on
//   this host), never timing-closed, never placed on silicon. NO clock frequency
//   is claimed anywhere in rtl/. The testbench clock period is stimulus, not a
//   timing result. One clock domain; multi-clock and CDC are out of scope.
//   Instruction counts are simulator counts, not a performance claim.
//
// IMPLEMENTATION LIMITS — stated here and in CROSSCHECK.md, never hidden:
//   1. `stream.*` is ISSUED by the core but WALKED by the testbench, which owns
//      memory and clocks the engine to completion. The core gates retirement on
//      the engine's final-element pointer-write pulse. There is no scoreboard and
//      no hazard interlock: a program that read a register the stream engine was
//      still advancing would read a stale value, so the testbench settles each
//      instruction before starting the next.
//   2. `matrix.*`, `fft.*`, `codec.*` (0x60-0x8F) are DECODED ONLY — see
//      rtl/accel.sv. A recognised operation raises err_accel_not_impl_o and
//      writes NOTHING; a reserved opcode byte raises err_accel_unknown_o.
//      Neither invents a result.
//   3. `cap.*` (0x50-0x52), `thread.*` (0x90-0x92) and `stream.setp` (0x43) are
//      recognised as instructions but not executed; they raise
//      err_unimplemented_o. CROSSCHECK.md records the measured Zig behaviour
//      behind each decision.
//   4. FLAGS (§4 index 15) is never written by any implemented instruction.
//      §3.2.1 is explicit that `compare` "does not write FLAGS", and no other
//      implemented op sets it, so FLAGS reads 0 in every program cross-checked
//      here. It is still a real regfile location, not a hardwired zero: a future
//      flag-setting op has somewhere to write.
//   5. `select` (0x21) and `field.*` (0x30-0x31) are DECODED, their units are
//      instantiated and their operand fields are sliced from the word, but their
//      register-writeback muxes are NOT wired; they raise err_unimplemented_o.
//      Reason: §3.2.2's `select` operand layout is ambiguous about `rs2`, and
//      wiring a guess into a writeback path is how a wrong result gets committed.
//      Reported instead — see the findings in CROSSCHECK.md.
//   6. PC (§4 index 14) and LR (§4 index 13) are held in THIS module rather than
//      regfile.sv. §4 says index 14 is writable only by the §3.0 jump forms and
//      that writing it otherwise is a diagnostic error; keeping the two system
//      registers the §3.0 control path owns next to the PC-next mux is what makes
//      that enforceable, and it means no ALU instruction naming index 13 or 14 in
//      `rd` can ever collide with a return address or the program counter.
//      SP (12) and FLAGS (15) DO live in regfile.sv, which owns every index the
//      §3.1 ALU can reach. reg_o[] below reads them out of it.
//=============================================================================

module core
  import celeris64_pkg::*;
(
  input  logic                 clk_i,
  input  logic                 rst_ni,        // synchronous, active-low

  // ---- instruction fetch (word addressed; one 64-bit word per valid_i) -----
  input  logic [XLEN-1:0]      fetch_word_i,  // §2 word at the current PC
  input  logic                 fetch_valid_i, // fetch_word_i has arrived and is valid

  // ---- flat memory port for the §3.4 stream engine (byte addressed) --------
  output logic                 mem_wr_en_o,   // committed, in-bounds write strobe
  output logic [XLEN-1:0]      mem_wr_addr_o,
  output logic [XLEN-1:0]      mem_wr_data_o,   // §3.4: XLEN-wide element value
  output logic [7:0]           mem_byte_sel_o,// little-endian byte lanes (§1)
  output logic                 mem_rd_en_o,
  output logic [XLEN-1:0]      mem_rd_addr_o,
  input  logic [XLEN-1:0]      mem_rd_data_i,   // §3.4: XLEN-wide element read-back

  // ---- §6 accessible region for the stream engine's bounds check ----------
  input  logic [XLEN-1:0]      region_base_i,
  input  logic [XLEN-1:0]      region_len_i,

  // ---- architectural-state observation request -----------------------------
  //
  // The 16-entry §4 register snapshot is captured by sweeping the ONE register
  // file's read ports over indices 0-15. That sweep must never run while an
  // instruction could be executing, so it is gated on THIS explicit request rather
  // than on "the core looks idle" — an earlier revision keyed it off the absence of
  // a fetch request, which is also true between instructions, and the sweep then
  // stole the read ports and suppressed writeback.
  //
  // Raise `obs_req_i` while `fetch_valid_i` is LOW (i.e. between instructions) and
  // hold it for 16+ cycles; the snapshot appears on `gpr_o`/`sp_o`/`lr_o`/`pc_o`/
  // `flags_o`. `obs_ready_o` goes high when the snapshot is complete.
  input  logic                 obs_req_i,
  output logic                 obs_ready_o,

  // ---- architectural state out (the cross-check compares exactly these) ----
  output logic [XLEN-1:0]      gpr_o [12],    // §4 indices 0-11
  output logic [XLEN-1:0]      sp_o,          // §4 index 12
  output logic [XLEN-1:0]      lr_o,          // §4 index 13
  output logic [XLEN-1:0]      pc_o,          // §4 index 14
  output logic [XLEN-1:0]      flags_o,       // §4 index 15

  // ---- retirement, halt and status ----------------------------------------
  output logic                 retired_o,     // one-cycle pulse: this word committed
  output logic                 halted_o,      // no further fetch; a diagnostic was raised
  output logic                 busy_o,        // a multi-cycle unit is in flight

  // ---- diagnostics, one signal per refusal (§7: never a bare code) --------
  output logic                 err_reserved_width_o, // §5: width 4-15
  output logic                 err_alu_zero_o,       // §3.1 v1.2: zero[39:28] != 0
  output logic                 err_div_zero_o,       // §3.1: divide-by-zero
  output logic                 err_accel_reserved_o, // §3.6: reserved[39:32] != 0
  output logic                 err_accel_not_impl_o, // §3.6: recognised, no datapath
  output logic                 err_accel_unknown_o,  // §3.6: reserved opcode byte
  output logic                 err_stream_o,         // §3.4: chunk/width/reserved/bounds
  output logic                 err_field_o,          // §3.3.1: width 0 / offset+width > 64
  output logic                 err_sel_reserved_o,   // §3.2.2 v1.3: operand[35:0] != 0
  output logic                 err_unimplemented_o,  // cap/thread/setp/select/field
  output logic [OP_W-1:0]      opcode_o,             // the opcode under execution

  // ---- §3.6 accelerator operand decode, EXPOSED FOR ASSERTION ---------------
  //
  // These are the decoder's real outputs, not debug copies. The §3.6 deliverable
  // is "decode the operands correctly and flag a non-zero reserved field", and a
  // testbench cannot assert that unless the decoded fields leave the module. Each
  // one is wired straight from u_accel and from u_alu/u_select/u_field.
  output logic [RS2_W-1:0]     dbg_acc_rs2,          // §3.6 rs2[47:44], 0 = unused
  output logic [RS2_W-1:0]     dbg_acc_rs3,          // §3.6 rs3[43:40], 0 = unused
  output logic [7:0]           dbg_acc_reserved,     // §3.6 reserved[39:32]
  output logic [ACC_COUNT_W-1:0] dbg_acc_count,      // §3.6 count[31:0]
  output logic                 dbg_acc_rs2_used,     // §3.6: rs2 != 0
  output logic                 dbg_acc_rs3_used,     // §3.6: rs3 != 0
  output logic                 dbg_acc_count_derived,// §3.6: count == 0 -> derive from rd
  output logic                 dbg_acc_recognised,   // §3.6: has a normative table row
  output logic                 dbg_acc_result_valid, // 0: this build computes nothing
  output logic [XLEN-1:0]      dbg_acc_result,       // always 0; never a guess

  // ---- unit-level status, exposed so each §3 group is independently assertable
  output logic                 dbg_is_nop,           // §3.0 0x00
  output logic                 dbg_alu_op_legal,     // §3.1: opcode in 0x10-0x19
  output logic                 dbg_comp_status_lo,   // §3.2.1 status enum, low bit
  output logic                 dbg_sel_op_legal,     // §3.2: opcode in 0x20-0x21
  output logic                 dbg_fld_op_legal,     // §3.3: opcode in 0x30-0x31
  output logic [RS2_W-1:0]     dbg_stream_rs2_idx,   // §3.4 rs2 pass-through
  output logic                 dbg_sel_result_lo,    // §3.2.2 branchless merge, low bit
  output logic                 dbg_fld_result_lo,    // §3.3 slice result, low bit
  output logic [XLEN-1:0]      dbg_sel_result,       // §3.2.2 full merge result
  output logic [XLEN-1:0]      dbg_fld_result,       // §3.3 full slice result
  output logic                 dbg_acc_in_range,     // §3.6: opcode in 0x60-0x8F
  output logic                 dbg_acc_group_matrix, // §3.6: 0x60-0x6F
  output logic                 dbg_acc_group_fft,    // §3.6: 0x70-0x7F
  output logic                 dbg_acc_group_codec,  // §3.6: 0x80-0x8F
  output logic [RD_W-1:0]      dbg_acc_rd,           // §3.6 §2 rd passthrough
  output logic [RS1_W-1:0]     dbg_acc_rs1,          // §3.6 §2 rs1 passthrough
  output logic [RS2_W-1:0]     dbg_sel_rs2_idx,      // §3.2.2 rs2 passthrough
  output logic [RS1_W-1:0]     dbg_sel_true_idx,     // §3.2.2 trueReg passthrough
  output logic [RS1_W-1:0]     dbg_sel_false_idx,    // §3.2.2 falseReg passthrough
  output logic [RS1_W-1:0]     dbg_fld_src2_idx,     // §3.3 src2 passthrough
  output logic [OPERAND_W-1:0] dbg_operand,          // §2 operand[47:0], whole field

  // ---- §3.1 ALU operand view of the SAME word, exposed for assertion ---------
  //
  // §3.1 v1.2 is the amendment that fixed a real contradiction: an immediate whose
  // diagram drew 40 bits while its name, its prose and both implementations said
  // 28. These fields are the ones whose interpretation changed, so a testbench can
  // pin the corrected reading directly:
  //   dbg_alu_imm28  — 28 bits; a word with a bit in [39:28] set has a ZERO imm28
  //                    and is therefore REGISTER-form, not immediate-form.
  //   dbg_alu_zero   — reserved [39:28]; non-zero is a §7 diagnostic.
  //   dbg_alu_is_imm — §3.1's immediate-form rule, from the package.
  output logic [IMM28_W-1:0]    dbg_alu_imm28,
  output logic [ALU_ZERO_W-1:0] dbg_alu_zero,
  output logic                  dbg_alu_is_imm,
  output logic                  dbg_alu_src2_is_imm,
  output logic [RS2_W-1:0]      dbg_alu_rs2,
  output logic [ALUWIDTH_W-1:0] dbg_alu_width,       // §3.1 width[43:40]
  output logic                  dbg_fld_no_zero_width,// §3.3: width field != 0

  // ---- §3.2.2 / §3.3 operand slices, exposed for assertion ------------------
  // (trueReg / falseReg / src2 passthroughs are declared above; only the fields
  //  that are NOT already exposed at the boundary are added here.)
  output logic [RS2_W-1:0]      dbg_sel_match,
  output logic [35:0]           dbg_sel_reserved,    // §3.2.2 v1.3 operand[35:0]
  output logic [27:0]           dbg_fld_reserved,    // §3.3 v1.3 operand[27:0]
  output logic [7:0]            dbg_fld_offset,
  output logic [7:0]            dbg_fld_width,

  // ---- §3.4 operand slices, exposed for assertion --------------------------
  output logic [19:0]           dbg_stream_chunk,
  output logic [ALUWIDTH_W-1:0] dbg_stream_elem_width,
  output logic [19:0]           dbg_stream_reserved,
  // ---- §3.0 control target and the §1 stride, exposed for assertion --------
  output logic [XLEN-1:0]       dbg_control_target,
  output logic [XLEN-1:0]       dbg_pc_next
);

  //===========================================================================
  // §2 WORD DECODE — one pure bit slice of the fetched word.
  //
  // unpack_word is the PACKAGE's function, so opcode/rd/rs1/operand are sliced in
  // exactly one place for the whole design, and the testbench, the package and
  // src/decoder.zig cannot drift apart.
  //
  // ---------------------------------------------------------------------------
  // JUSTIFIED LINT SUPPRESSION — Verilator 5.48 UNUSEDSIGNAL false positive.
  //
  // The tool reports `Bits of signal are not used: 'word_d'[39:0]` even though
  // every one of those bits is read into `operand` below and consumed by the §3.0
  // control target, the §3.1 ALU, the §3.2 select, the §3.3 field unit, the §3.4
  // stream engine and the §3.6 accelerator decode. The warning is a defect in the
  // tool's flattened bit numbering for packed structs, not a dead signal here.
  //
  // REPRODUCTION — self-contained, no project files, re-run it and check this
  // claim rather than taking it on trust. Reading the ENTIRE field once, into an
  // output, still fires it, and the range it names does not even correspond to the
  // field (operand lives at [47:0] but Verilator says [55:48]):
  //
  //   package pc;
  //     typedef struct packed {
  //       logic [7:0]  opcode; logic [3:0] rd; logic [3:0] rs1; logic [47:0] operand;
  //     } tw;
  //   endpackage
  //   module pc_m import pc::*;
  //     (input logic [63:0] w, output logic [47:0] oo, output logic [7:0] o);
  //     tw d;
  //     always_comb d = '{opcode: w[63:56], rd: w[55:52], rs1: w[51:48], operand: w[47:0]};
  //     assign oo = d.operand;   // the WHOLE 48-bit field, into an output
  //     assign o  = d.opcode;    // and the other fields used
  //   endmodule
  //
  //   $ verilator --lint-only -Wall --top-module pc_m pc.sv
  //   %Warning-UNUSEDSIGNAL: pc.sv:...: Bits of signal are not used: 'd'[55:48]
  //   %Error: Exiting due to 1 warning(s)
  //
  // The alternative — hand-slicing fetch_word_i here instead of calling the
  // package's unpack_word — would duplicate §2 decoding to appease the tool, and
  // that duplication is exactly the drift the package exists to prevent. So the
  // suppression is scoped to this ONE declaration; every other UNUSEDSIGNAL in the
  // tree (including rtl/stream_engine.sv's real one) stays live.
  // ---------------------------------------------------------------------------
  /* verilator lint_off UNUSEDSIGNAL */
  decoded_word_t    word_d;
  logic [OP_W-1:0]  opcode;
  logic [RD_W-1:0]  rd;
  logic [RS1_W-1:0] rs1;
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb word_d = unpack_word(fetch_word_i);

  assign opcode   = word_d.opcode;   // §2 [63:56]
  assign rd       = word_d.rd;       // §2 [55:52]
  assign rs1      = word_d.rs1;      // §2 [51:48]
  assign opcode_o = opcode;

  // §2 operand[47:0], named once. Every §3 group slices THIS, never the struct
  // field directly, so the §2 operand field has exactly one name in the design and
  // no bit of it can be dropped without the lint noticing.
  logic [OPERAND_W-1:0] operand;
  assign operand = word_d.operand;   // §2 operand[47:0]

  //===========================================================================
  // §1 PC ARITHMETIC — THE SINGLE PC-ADVANCE EXPRESSION.
  //
  // `pc_next` is the address of the next instruction and is used by BOTH the
  // straight-line advance and `call`'s LR write. There is deliberately no second
  // expression in this file: a second one is how `call` came to save the wrong
  // address in the Zig VM.
  //===========================================================================
  localparam logic [XLEN-1:0] PC_STRIDE = XLEN'(INSN_W / 8);  // §1: 64-bit word = 8 bytes

  logic [XLEN-1:0] pc_q;      // §4 index 14
  logic [XLEN-1:0] pc_next;

  assign pc_next = pc_q + PC_STRIDE;   // §1: fixed width -> fixed stride, always
  assign pc_o    = pc_q;

  //===========================================================================
  // §4 LR — index 13, owned here because the §3.0 control path is its only
  // writer. Registered, so `ret`'s target is available in the same cycle the
  // opcode is decoded with no combinational path from a write port to a read.
  //===========================================================================
  logic [XLEN-1:0] lr_q;
  assign lr_o = lr_q;

  //===========================================================================
  // §3 OPCODE RECOGNITION, computed once, in one place.
  //
  // Positive predicates rather than inline compares scattered through the
  // dispatch, so each §3 group is named exactly once. `is_accel` uses the
  // package's own §3.6 range predicate, which is also what enforces the
  // "reserved opcodes are not reinterpreted as a neighbour" rule (Amendment 1.1).
  //===========================================================================
  logic is_nop, is_halt, is_jump, is_call, is_ret;
  logic is_alu, is_compare, is_select;
  logic is_field, is_stream, is_stream_setp;
  logic is_cap, is_thread, is_accel;

  always_comb begin
    is_nop         = (opcode == OP_NOP);                                        // 0x00
    is_halt        = (opcode == OP_HALT);                                       // 0x01
    is_jump        = (opcode == OP_JUMP);                                       // 0x02
    is_call        = (opcode == OP_CALL);                                       // 0x03
    is_ret         = (opcode == OP_RET);                                        // 0x04
    is_alu         = (opcode >= OP_ADD) && (opcode <= OP_MOV);                  // 0x10-0x19
    is_compare     = (opcode == OP_COMPARE);                                    // 0x20
    is_select      = (opcode == OP_SELECT);                                     // 0x21
    is_field       = (opcode >= OP_FIELD_EXTRACT) && (opcode <= OP_FIELD_INSERT);// 0x30-0x31
    is_stream      = (opcode >= OP_STREAM_ADD) && (opcode <= OP_STREAM_SETP);    // 0x40-0x43
    is_stream_setp = (opcode == OP_STREAM_SETP);                                // 0x43
    is_cap         = (opcode >= OP_CAP_LOAD) && (opcode <= OP_CAP_CHECK);        // 0x50-0x52
    is_thread      = (opcode >= OP_THREAD_SPAWN) && (opcode <= OP_THREAD_YIELD); // 0x90-0x92
    is_accel       = is_accelerator_opcode(opcode);                              // §3.6 0x60-0x8F
  end

  //===========================================================================
  // §3.0 PC-NEXT MUX — the ONLY place PC changes direction.
  //
  //   jump 0x02 : PC <- operand[47:0]                 (LR untouched — §3.0 row 0x02)
  //   call 0x03 : PC <- operand[47:0], LR <- pc_next   (§3.0 row 0x03)
  //   ret  0x04 : PC <- LR
  //   otherwise : PC <- pc_next                        (§1 fixed stride)
  //
  // The control target is imm48 = operand[47:0], ZERO-extended: §3.0 says "imm48
  // target address", and src/decoder.zig does the same with `@as(u64, operand)`.
  // It is deliberately NOT imm_sext — that is §3.1's 28-bit signed ALU immediate
  // and has nothing to do with §3.0. `jump 0` is a legal encoding meaning address
  // 0; §3.0 has no "0 means unused" rule.
  //===========================================================================
  logic [XLEN-1:0] pc_target;
  logic [XLEN-1:0] lr_d;
  logic [XLEN-1:0] pc_d;

  always_comb begin
    pc_target = {16'd0, operand};   // §3.0: imm48, zero-extended
    // §3.0 row 0x03: LR <- the address of the NEXT instruction = pc_next, the very
    // same expression the straight-line path uses.
    lr_d = pc_next;

    unique case (1'b1)
      is_jump: pc_d = pc_target;      // 0x02
      is_call: pc_d = pc_target;      // 0x03
      is_ret:  pc_d = lr_q;           // 0x04
      default: pc_d = pc_next;        // §1 stride
    endcase
  end

  //===========================================================================
  // §3.1 ALU.
  //
  // src2 = rs2 or the sign-extended immediate, per §3.1's rule "if imm28 != 0 the
  // instruction is immediate-form and rs2 is ignored". Both the rule and the sign
  // extension come from the package, so this is the v1.2 reading: imm28 is
  // [27:0] and zero[39:28] is the reserved field. v1.1 read a 40-bit immediate
  // here and diverged from decoder.zig on every word with a bit in [39:28] set.
  //===========================================================================
  logic [XLEN-1:0] rf_rdata_a, rf_rdata_b;
  logic [XLEN-1:0] alu_src2;
  logic [XLEN-1:0] alu_result;
  logic            alu_div_zero, alu_width_err, alu_zero_err, alu_op_legal;

  assign alu_src2 = alu_is_immediate(word_d.imm28) ? word_d.imm_sext : rf_rdata_b;

  alu u_alu (
    .opcode_i    (opcode),
    .width_raw_i (word_d.alu_width_raw),
    .imm28_i     (word_d.imm28),
    .alu_zero_i  (word_d.alu_zero),
    .rs1_val_i   (rf_rdata_a),
    .rs2_val_i   (rf_rdata_b),
    .result_o    (alu_result),
    .div_zero_o  (alu_div_zero),
    .width_err_o (alu_width_err),
    .zero_err_o  (alu_zero_err),
    .op_legal_o  (alu_op_legal)
  );

  //===========================================================================
  // §3.2 COMPARE + SELECT UNIT.
  //
  // compare (0x20) IS executed: it writes the §3.2.1 status enum into rd. §3.2.1
  // is explicit that it "does not write FLAGS and does not branch".
  //
  // select (0x21) is DECODED but not executed (limit 5).
  //===========================================================================
  status_e          cmp_status;
  logic [XLEN-1:0]  sel_result;
  logic             sel_op_legal;
  logic [RS2_W-1:0] sel_rs2_idx;
  logic [RS1_W-1:0] sel_true_idx, sel_false_idx;
  logic [RS2_W-1:0] sel_rs2_idx_o;
  logic [RS1_W-1:0] sel_true_idx_o, sel_false_idx_o;
  logic [35:0]      sel_reserved;      // §3.2.2 v1.3: operand[35:0], must be zero
  logic             sel_reserved_err;

  // §3.2.2: match[47:44], trueReg[43:40], falseReg[39:36].
  assign sel_rs2_idx   = operand[47:44];
  assign sel_true_idx  = operand[43:40];
  assign sel_false_idx = operand[39:36];
  // §3.2.2 v1.3: operand[35:0] is reserved and is REJECTED when set, not ignored.
  assign sel_reserved  = operand[35:0];

  select_unit u_select (
    .opcode_i       (opcode),
    .rs2_idx_i      (sel_rs2_idx),
    .true_idx_i     (sel_true_idx),
    .false_idx_i    (sel_false_idx),
    .rs1_val_i      (rf_rdata_a),
    .src2_val_i     (alu_src2),
    // §3.2.1 defines LESS/GREATER as signed and UNSIGNED_LESS/UNSIGNED_GREATER as
    // unsigned, and the enum carries BOTH views in one value — so the signed view
    // is named here. src/vm.zig makes exactly this choice: "the signed view, which
    // is what §3.2.1 defines LESS/GREATER against".
    .signed_view_i  (1'b1),
    .match_status_i (operand[47:44]),
    .status_val_i   (status_e'(rf_rdata_a[3:0])),
    .true_val_i     (rf_rdata_b),
    .false_val_i    (rf_rdata_b),
    .status_o       (cmp_status),
    .select_o       (sel_result),
    .rs2_idx_o      (sel_rs2_idx_o),
    .true_idx_o     (sel_true_idx_o),
    .false_idx_o    (sel_false_idx_o),
    .op_legal_o     (sel_op_legal),
    .reserved_i     (sel_reserved),
    .reserved_err_o (sel_reserved_err)
  );

  //===========================================================================
  // §3.3 FIELD UNIT — decoded and instantiated, not written back (limit 5).
  //===========================================================================
  logic [XLEN-1:0]  fld_result;
  logic             fld_zero_width, fld_range_err, fld_too_wide, fld_op_legal;
  logic [RS1_W-1:0] fld_src2_idx, fld_src2_idx_o;
  logic [27:0]      fld_reserved;      // §3.3 v1.3: operand[27:0], must be zero
  logic             fld_reserved_err;

  assign fld_src2_idx = operand[31:28];   // §3.3 src2[31:28]
  // §3.3 v1.3: operand[27:0] is reserved and is REJECTED when set, not ignored.
  assign fld_reserved = operand[27:0];

  field_unit u_field (
    .opcode_i     (opcode),
    .offset_i     (operand[47:40]),   // §3.3 offset[47:40]
    .width_i      (operand[39:32]),   // §3.3 width[39:32]
    .src2_idx_i   (fld_src2_idx),
    .base_val_i   (rf_rdata_a),
    .field_val_i  (rf_rdata_b),
    .result_o     (fld_result),
    .zero_width_o (fld_zero_width),
    .range_err_o  (fld_range_err),
    .too_wide_o   (fld_too_wide),
    .op_legal_o   (fld_op_legal),
    .src2_idx_o   (fld_src2_idx_o),
    .reserved_i   (fld_reserved),
    .reserved_err_o(fld_reserved_err)
  );

  //===========================================================================
  // §3.6 ACCELERATOR — decode only (limit 2). See rtl/accel.sv.
  //===========================================================================
  logic [RS2_W-1:0]       acc_rs2, acc_rs3;
  logic [7:0]             acc_reserved;
  logic [ACC_COUNT_W-1:0] acc_count;
  logic acc_rs2_used, acc_rs3_used, acc_count_derived;
  logic acc_in_range, acc_matrix, acc_fft, acc_codec, acc_recognised;
  logic acc_reserved_err, acc_not_impl, acc_unknown, acc_result_valid;
  logic [XLEN-1:0] acc_result;
  logic [RD_W-1:0]  acc_rd;
  logic [RS1_W-1:0] acc_rs1;

  accel u_accel (
    .opcode_i          (opcode),
    .rd_i              (rd),
    .rs1_i             (rs1),
    .operand_i         (operand),
    .rs2_o             (acc_rs2),
    .rs3_o             (acc_rs3),
    .reserved_o        (acc_reserved),
    .count_o           (acc_count),
    .rs2_used_o        (acc_rs2_used),
    .rs3_used_o        (acc_rs3_used),
    .count_derived_o   (acc_count_derived),
    .in_range_o        (acc_in_range),
    .group_is_matrix_o (acc_matrix),
    .group_is_fft_o    (acc_fft),
    .group_is_codec_o  (acc_codec),
    .op_recognised_o   (acc_recognised),
    .reserved_err_o    (acc_reserved_err),
    .not_implemented_o (acc_not_impl),
    .unknown_op_o      (acc_unknown),
    .result_valid_o    (acc_result_valid),
    .result_o          (acc_result),
    .rd_o              (acc_rd),
    .rs1_o             (acc_rs1)
  );

  //===========================================================================
  // §3.4 STREAM ENGINE — issued here, walked by the testbench (limit 1).
  //
  // The engine owns the §3.4 atomicity gate: a chunk that does not fit inside the
  // accessible region modifies ZERO bytes and does not advance the pointer, and
  // that decision is made ONCE, before any element is touched, inside
  // stream_engine.sv. The core never tests bounds per element and must not:
  // a per-element test is exactly the partial application §3.4 rule 3 forbids.
  //===========================================================================
  logic [19:0]      st_chunk, st_reserved;
  logic [RS2_W-1:0] st_rs2_idx, st_rs2_idx_o;
  logic [ALUWIDTH_W-1:0] st_elem_width_raw;
  logic             st_busy, st_chunk_err, st_width_err, st_reserved_err;
  logic             st_bounds_err, st_chunk_too_large;
  logic [XLEN-1:0]  st_ptr_d;
  logic             st_ptr_we;
  logic             st_issue;   // §3.4 issue strobe; driven by the FSM below

  // §3.4 operand field for add/copy/fill:
  //   rs2[47:44] | chunk[43:24] | element width[23:20] | reserved[19:0]
  assign st_rs2_idx        = operand[47:44];   // §3.4 rs2
  assign st_chunk          = operand[43:24];   // §3.4 chunk, must be >= 1
  assign st_elem_width_raw = operand[23:20];   // §3.4 element width, §5 selector
  assign st_reserved       = operand[19:0];    // §3.4 reserved, must be zero

  stream_engine u_stream (
    .clk_i             (clk_i),
    .rst_ni            (rst_ni),
    .issue_i           (st_issue),
    .opcode_i          (opcode),
    .rs2_idx_i         (st_rs2_idx),
    .chunk_i           (st_chunk),
    .elem_width_raw_i  (st_elem_width_raw),
    .reserved_i        (st_reserved),
    .ptr_val_i         (rf_rdata_a),    // §3.4 rs1: the pointer register
    .scalar_val_i      (rf_rdata_b),    // §3.4 rd: the scalar for `fill`
    .src_addr_i        (rf_rdata_b),    // §3.4 rs2: source address for `copy`
    .offset_val_i      (rf_rdata_b),    // §3.4 rs2: per-element addend for `add`
    .region_base_i     (region_base_i), // §6
    .region_len_i      (region_len_i),  // §6
    .mem_wr_en_o       (mem_wr_en_o),
    .mem_wr_addr_o     (mem_wr_addr_o),
    .mem_wr_data_o     (mem_wr_data_o),
    .mem_byte_sel_o    (mem_byte_sel_o),
    .mem_rd_en_o       (mem_rd_en_o),
    .mem_rd_addr_o     (mem_rd_addr_o),
    .mem_rd_data_i     (mem_rd_data_i),
    .ptr_d_o           (st_ptr_d),
    .ptr_we_o          (st_ptr_we),
    .busy_o            (st_busy),
    .chunk_err_o       (st_chunk_err),
    .width_err_o       (st_width_err),
    .reserved_err_o    (st_reserved_err),
    .bounds_err_o      (st_bounds_err),
    .chunk_too_large_o (st_chunk_too_large),
    .rs2_idx_o         (st_rs2_idx_o)
  );

  //===========================================================================
  // §3.0 / §3.4 EXECUTION FSM.
  //
  //   DECODE    — combinational dispatch; a multi-cycle unit may be issued
  //   STREAMW   — the stream engine is walking the chunk; wait for the commit
  //   WRITEBACK — the register write commits, and the instruction retires
  //   HALTED    — `halt` retired, or a diagnostic was raised; no further fetch
  //
  // Retirement happens in WRITEBACK for every committed instruction, including
  // `nop`, so retired_o is a faithful count of executed words. An instruction
  // that REFUSES retires nothing: it raises its diagnostic and stops the
  // machine, because a wrong result committed to the register file is worse than
  // a stop. That is §7's principle applied to control flow.
  //===========================================================================
  typedef enum logic [2:0] {
    ST_DECODE    = 3'd0,
    ST_STREAMW   = 3'd1,
    ST_WRITEBACK = 3'd2,
    ST_HALTWB    = 3'd3,   // §3.0 row 0x01: halt retires here, then parks
    ST_HALTED    = 3'd4
  } state_e;

  state_e state_q;

  // §3.4 commit handshake. The engine ACCEPTS a chunk in the cycle issue_i is
  // asserted while its own accept predicate holds, then walks it, then pulses
  // ptr_we_o on the final element. That pulse is the engine's "the whole chunk is
  // applied and the pointer has advanced" signal, and it is what the core waits
  // for. A REFUSED chunk never becomes active and never pulses ptr_we_o, so the
  // core must not wait on it — it is refused in the issue cycle itself.
  logic st_refused, st_stream_commit;

  always_comb begin
    st_refused = st_chunk_err || st_width_err || st_reserved_err
              || st_bounds_err || st_chunk_too_large;
  end

  assign st_issue = (state_q == ST_DECODE) && is_stream && !is_stream_setp
                 && fetch_valid_i;

  // The engine pulses ptr_we_o on the cycle its final element commits, i.e. the
  // LAST cycle of ST_STREAMW. The register write happens in the FOLLOWING
  // ST_WRITEBACK cycle. Capturing the pulse in a single register was not enough:
  // it was high during ST_STREAMW and had already dropped by ST_WRITEBACK, so the
  // write mux (which requires ST_WRITEBACK) never fired and the pointer never
  // advanced. It is HELD until the writeback cycle consumes it, then cleared, so
  // the advance is applied exactly once.
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      st_stream_commit <= 1'b0;
    end else if (state_q == ST_WRITEBACK) begin
      st_stream_commit <= 1'b0;          // consumed by the writeback mux
    end else if (st_ptr_we) begin
      st_stream_commit <= 1'b1;          // hold until consumed
    end
  end

  //===========================================================================
  // DIAGNOSTIC AGGREGATION — §7 style: every refusal keeps its own name. There is
  // no single opaque "error" bit, because a caller that cannot say WHICH operand
  // was wrong cannot print the plain-language sentence §7 requires.
  //
  // Two classes are distinguished deliberately:
  //   * the OPERAND was illegal (bad width, non-zero reserved field, divide by
  //     zero, out-of-range field) -> the specific err_*_o for that operand;
  //   * the INSTRUCTION is legal but this build has no datapath for it
  //     (cap/thread/setp/select/field) -> err_unimplemented_o.
  // Collapsing the two would tell a user their program is invalid when in fact
  // the build is incomplete, which is the more misleading of the two errors.
  //===========================================================================
  logic err_operand, err_any;

  always_comb begin
    err_reserved_width_o = fetch_valid_i && (is_alu || is_compare) && alu_width_err;
    err_alu_zero_o       = fetch_valid_i && (is_alu || is_compare) && alu_zero_err;
    err_div_zero_o       = fetch_valid_i && is_alu && alu_div_zero;

    err_accel_reserved_o = fetch_valid_i && is_accel && acc_reserved_err;
    err_accel_not_impl_o = fetch_valid_i && is_accel && acc_not_impl;
    err_accel_unknown_o  = fetch_valid_i && is_accel && acc_unknown;

    err_stream_o         = fetch_valid_i && is_stream && !is_stream_setp
                           && (st_chunk_err || st_width_err || st_reserved_err ||
                               st_bounds_err || st_chunk_too_large);

    err_field_o          = fetch_valid_i && is_field
                           && (fld_zero_width || fld_range_err || fld_too_wide
                               || fld_reserved_err);

    // §3.2.2 v1.3: a set reserved bit in a select word is its own refusal.
    err_sel_reserved_o = fetch_valid_i && is_select && sel_reserved_err;

    err_operand = err_reserved_width_o || err_alu_zero_o || err_div_zero_o
               || err_accel_reserved_o || err_accel_not_impl_o
               || err_accel_unknown_o  || err_stream_o || err_field_o
               || err_sel_reserved_o;

    // A legal instruction this build does not execute. setp is here rather than in
    // err_stream_o because its §3.4 operand field is a DIFFERENT layout (a signed
    // 40-bit stride) from the other three stream ops — see CROSSCHECK.md.
    err_unimplemented_o = fetch_valid_i && !err_operand
                          && (is_cap || is_thread || is_stream_setp
                              || is_select || is_field);

    err_any = err_operand || err_unimplemented_o || rf_width_err;
  end

  //===========================================================================
  // §4 REGISTER FILE — ONE INSTANCE, TWO PORT VIEWS.
  //
  // regfile.sv is instantiated ONCE per view below, and every view is fed from the
  // same write port, so there is exactly one storage element and exactly one
  // writer per §4 index. A separate instance with we_i tied low would be
  // INDEPENDENT STORAGE and would read stale zeros — which is why the observation
  // ports below share this instance's write port instead of being their own.
  //
  // Port A = rs1 (§2 rs1[51:48]) for every §3 group.
  // Port B = the SECOND source, whose position depends on the §3 group:
  //            §3.1/§3.2/§3.6  rs2[47:44]
  //            §3.3            src2[31:28]
  //            §3.4 0x40-0x42  rs2[47:44] for add/copy, rd for fill (its scalar)
  //          Those positions are the §3 operand layouts, spelled out once here
  //          rather than re-derived at every use.
  //
  // WRITE PORT. Only three things reach it: the §3.1 ALU result, the §3.2.1
  // compare status, and the §3.4 stream pointer advance. Everything else raises a
  // diagnostic. There is deliberately NO default writeback, because a default is
  // how an unimplemented opcode commits a fabricated result. §4 index 12 (SP) and
  // 15 (FLAGS) are real locations in here; indices 13 (LR) and 14 (PC) are owned
  // by the §3.0 control path in this module (limit 6).
  //===========================================================================
  logic [RD_W-1:0]       rf_raddr_a, rf_raddr_b, rf_waddr;
  logic [XLEN-1:0]       rf_wdata;
  logic                  rf_we;
  logic [ALUWIDTH_W-1:0] rf_width_raw;
  logic                  rf_width_err;

  // The read addresses are muxed between EXECUTION (rs1/rs2 of the running
  // instruction) and OBSERVATION (a sweep of §4 indices 0-15 when the machine is
  // quiescent). The observation is driven by `obs_sel_q`, a small counter that
  // advances only while the core is idle, so it can never steal a port from a live
  // instruction.
  logic        obs_active;
  logic [3:0]  obs_idx;

  always_comb begin
    if (obs_active) begin
      rf_raddr_a = obs_idx;             // §4 index sweep
      rf_raddr_b = obs_idx;
    end else begin
      rf_raddr_a = rs1;                 // §2 rs1[51:48]

      unique case (1'b1)
        is_field:                       rf_raddr_b = fld_src2_idx;   // §3.3
        is_stream && !is_stream_setp
          && (opcode == OP_STREAM_FILL): rf_raddr_b = rd;            // §3.4 fill scalar
        default:                        rf_raddr_b = word_d.rs2;     // §3.1/§3.2/§3.4/§3.6
      endcase
    end
  end

  always_comb begin
    rf_we        = 1'b0;
    rf_waddr     = rd;
    rf_wdata     = {XLEN{1'b0}};
    rf_width_raw = word_d.alu_width_raw;   // §3.1/§5 operand width nibble

    if (!obs_active && (state_q == ST_WRITEBACK)) begin
      if (is_alu) begin
        // §3.1: the ALU already applied the §5 width to its result; regfile
        // applies it again on write. Idempotent, and it means a reserved width is
        // refused identically on both sides rather than in one place only.
        rf_we    = 1'b1;
        rf_waddr = rd;
        rf_wdata = alu_result;
      end else if (is_compare) begin
        // §3.2.1: the status enum is the ONLY sanctioned result of a comparison;
        // a bare 0/1 boolean would be a spec violation.
        rf_we        = 1'b1;
        rf_waddr     = rd;
        rf_wdata     = {60'd0, cmp_status};
        rf_width_raw = WIDTH_FULL;   // §3.2.1 defines no width for compare
      end else if (st_stream_commit) begin
        // §3.4 rule 2: the engine's auto-advance IS the pointer writeback. This is
        // the only pointer arithmetic in the architecture's batch path.
        rf_we        = 1'b1;
        rf_waddr     = rs1;          // §3.4: the pointer register
        rf_wdata     = st_ptr_d;
        rf_width_raw = WIDTH_FULL;
      end
    end
  end

  regfile u_regfile (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .raddr_a_i   (rf_raddr_a),
    .rdata_a_o   (rf_rdata_a),
    .raddr_b_i   (rf_raddr_b),
    .rdata_b_o   (rf_rdata_b),
    .we_i        (rf_we),
    .waddr_i     (rf_waddr),
    .width_raw_i (rf_width_raw),
    .wdata_i     (rf_wdata),
    .width_err_o (rf_width_err)
  );

  //===========================================================================
  // §4 STATE OBSERVATION for the cross-check.
  //
  // The observation sweep runs ONLY while the core is quiescent at ST_DECODE (no
  // instruction is being dispatched, so rs1/rs2 are not needed), visits each §4
  // index in turn, and latches what the register file returned. That gives a full
  // 16-entry architectural snapshot without a second register file and without
  // ever stealing a read port from a live instruction.
  //
  // Indices 0-11 (GPRs), 12 (SP) and 15 (FLAGS) come from regfile.sv. Indices 13
  // (LR) and 14 (PC) come from this module's own §3.0 control state, which is
  // their single writer (limit 6) — the sweep reports them from there rather than
  // inventing a regfile copy that nothing would keep in sync.
  //===========================================================================
  logic [XLEN-1:0] obs_regs [16];
  logic [3:0]      obs_idx_q;
  logic            obs_done_q;

  // Only sweep when explicitly asked AND no instruction is in flight. ST_HALTED is
  // included because that is where a program that ended in `halt` parks, and a
  // halted machine is exactly when its final state most needs observing. Both
  // states are quiescent: neither dispatches an instruction.
  assign obs_active = obs_req_i && !fetch_valid_i
                   && ((state_q == ST_DECODE) || (state_q == ST_HALTED));
  assign obs_idx    = obs_idx_q;
  assign obs_ready_o = obs_done_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      obs_idx_q  <= 4'd0;
      obs_done_q <= 1'b0;
      for (int unsigned i = 0; i < 16; i++) obs_regs[i] <= {XLEN{1'b0}};
    end else if (obs_active) begin
      // Latch what the register file returned for this index and move on. LR and
      // PC are taken from their single writer.
      unique case (obs_idx_q)
        REG_LR:  obs_regs[obs_idx_q] <= lr_q;                  // §4 index 13
        REG_PC:  obs_regs[obs_idx_q] <= pc_q;                  // §4 index 14
        default: obs_regs[obs_idx_q] <= rf_rdata_a;            // §4 indices 0-12, 15
      endcase
      obs_idx_q <= obs_idx_q + 4'd1;
      if (obs_idx_q == 4'd15) obs_done_q <= 1'b1;
    end else begin
      obs_done_q <= 1'b0;
    end
  end

  //===========================================================================
  // ARCHITECTURAL STATE OUTPUTS. §4 index order, so a caller can compare the
  // whole register file against the Zig VM's `File` field for field.
  //===========================================================================
  always_comb begin
    for (int unsigned i = 0; i < GPR_COUNT; i++) begin
      // GPR_COUNT is the same bound regfile.sv enforces on a GPR write, so the
      // observation and the storage agree on how many GPRs exist without either
      // stating the number twice. GPR_INDEX_MAX is the highest legal index.
      gpr_o[i] = (RD_W'(i) <= GPR_INDEX_MAX) ? obs_regs[i] : {XLEN{1'b0}};
    end
    sp_o    = obs_regs[REG_SP];      // §4 index 12
    flags_o = obs_regs[REG_FLAGS];   // §4 index 15
  end

  //===========================================================================
  // DECODE OUTPUTS exposed for the testbench. Straight wire-through of the real
  // decoder signals — there is no separate debug decode that could disagree with
  // the one used in execution.
  //===========================================================================
  assign dbg_acc_rs2           = acc_rs2;            // §3.6 rs2[47:44]
  assign dbg_acc_rs3           = acc_rs3;            // §3.6 rs3[43:40]
  assign dbg_acc_reserved      = acc_reserved;       // §3.6 reserved[39:32]
  assign dbg_acc_count         = acc_count;          // §3.6 count[31:0]
  assign dbg_acc_rs2_used      = acc_rs2_used;       // §3.6: 0 means unused
  assign dbg_acc_rs3_used      = acc_rs3_used;       // §3.6: 0 means unused
  assign dbg_acc_count_derived = acc_count_derived;  // §3.6: 0 -> derive from rd
  assign dbg_acc_recognised    = acc_recognised;     // §3.6 normative table row?
  assign dbg_acc_result_valid  = acc_result_valid;   // 0 in this build, by design
  assign dbg_acc_result        = acc_result;         // 0, never a fabricated value

  assign dbg_is_nop            = is_nop;             // §3.0 0x00
  assign dbg_alu_op_legal      = alu_op_legal;       // §3.1 0x10-0x19
  assign dbg_comp_status_lo    = cmp_status[0];      // §3.2.1 status enum bit 0
  assign dbg_sel_op_legal      = sel_op_legal;       // §3.2 0x20-0x21
  assign dbg_fld_op_legal      = fld_op_legal;       // §3.3 0x30-0x31
  assign dbg_stream_rs2_idx    = st_rs2_idx_o;       // §3.4 rs2 pass-through
  assign dbg_sel_result_lo     = sel_result[0];      // §3.2.2 branchless merge
  assign dbg_fld_result_lo     = fld_result[0];      // §3.3 extract/insert result
  assign dbg_sel_result        = sel_result;         // §3.2.2 full merge result
  assign dbg_fld_result        = fld_result;         // §3.3 full slice result
  assign dbg_acc_in_range      = acc_in_range;       // §3.6 range predicate
  assign dbg_acc_group_matrix  = acc_matrix;         // §3.6 0x60-0x6F
  assign dbg_acc_group_fft     = acc_fft;            // §3.6 0x70-0x7F
  assign dbg_acc_group_codec   = acc_codec;          // §3.6 0x80-0x8F
  assign dbg_acc_rd            = acc_rd;             // §3.6 §2 rd passthrough
  assign dbg_acc_rs1           = acc_rs1;            // §3.6 §2 rs1 passthrough
  assign dbg_sel_rs2_idx       = sel_rs2_idx_o;      // §3.2.2 rs2 passthrough
  assign dbg_sel_true_idx      = sel_true_idx_o;     // §3.2.2 trueReg passthrough
  assign dbg_sel_false_idx     = sel_false_idx_o;    // §3.2.2 falseReg passthrough
  assign dbg_fld_src2_idx      = fld_src2_idx_o;     // §3.3 src2 passthrough
  // The whole §2 operand field. Exposing it also consumes every bit of word_d, so
  // no part of the decoded struct is silently dropped by the core.
  assign dbg_operand           = operand;     // §2 operand[47:0]

  // §3.1 operand view — the exact fields whose meaning v1.2 corrected.
  assign dbg_alu_imm28      = word_d.imm28;               // §3.1 v1.2: [27:0], 28 bits
  assign dbg_alu_zero       = word_d.alu_zero;            // §3.1 v1.2: reserved [39:28]
  assign dbg_alu_is_imm     = alu_is_immediate(word_d.imm28);  // §3.1 immediate-form rule
  assign dbg_alu_src2_is_imm= alu_is_immediate(word_d.imm28);  // = dbg_alu_is_imm
  assign dbg_alu_rs2        = word_d.rs2;                 // §3.1 rs2[47:44]
  assign dbg_alu_width      = word_d.alu_width_raw;       // §3.1 width[43:40]
  // §3.3.1: width == 0 is a diagnostic error, and the field unit reports it on
  // zero_width_o; this is the positive predicate the testbench asserts.
  assign dbg_fld_no_zero_width = !fld_zero_width;

  // §3.2.2 / §3.3 operand slices.
  assign dbg_sel_match      = sel_rs2_idx;                // §3.2.2 match[47:44]
  assign dbg_sel_reserved   = sel_reserved;               // §3.2.2 v1.3 operand[35:0]
  assign dbg_fld_reserved   = fld_reserved;               // §3.3 v1.3 operand[27:0]
  assign dbg_fld_offset     = operand[47:40];      // §3.3 offset[47:40]
  assign dbg_fld_width      = operand[39:32];      // §3.3 width[39:32]

  // §3.4 operand slices.
  assign dbg_stream_chunk        = st_chunk;              // §3.4 chunk[43:24]
  assign dbg_stream_elem_width   = st_elem_width_raw;     // §3.4 width[23:20]
  assign dbg_stream_reserved     = st_reserved;           // §3.4 reserved[19:0]

  // §3.0 / §1 control views.
  assign dbg_control_target = pc_target;                  // §3.0 imm48, zero-extended
  assign dbg_pc_next        = pc_next;                    // §1 fixed stride

  //===========================================================================
  // STATE UPDATE.
  //===========================================================================
  // retired_o pulses for a committed instruction. ST_HALTWB is halt's own
  // retire cycle; without it halt would either not count (the original defect) or
  // re-execute forever.
  assign retired_o = ((state_q == ST_WRITEBACK) || (state_q == ST_HALTWB))
                  && !obs_active;
  assign halted_o  = (state_q == ST_HALTED);
  assign busy_o    = (state_q == ST_STREAMW) || st_busy;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      pc_q <= {XLEN{1'b0}};
      lr_q <= {XLEN{1'b0}};
    end else if ((state_q == ST_WRITEBACK) || (state_q == ST_HALTWB)) begin
      pc_q <= pc_d;                 // §3.0 mux, or pc_next for the §1 stride
      if (is_call) lr_q <= lr_d;    // §3.0 row 0x03: LR <- address of NEXT insn
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) state_q <= ST_DECODE;
    else begin
      unique case (state_q)
        ST_DECODE: begin
          if (fetch_valid_i) begin
            if (err_any)      state_q <= ST_HALTED;   // refused: stop, commit nothing
            // §3.0 row 0x01: halt IS a retired instruction. src/vm.zig counts it
            // (`.halt => { self.retired += 1; ... }`) and PC advances past it on
            // the fixed §1 stride. It therefore needs its OWN writeback state:
            // going straight to HALTED made retired_o short by one and left PC
            // pointing AT the halt word; going to ST_WRITEBACK and then back to
            // ST_DECODE re-executed the same halt word forever. ST_HALTWB retires
            // once and parks. It writes no register — the writeback mux has no
            // `is_halt` arm, which is the correct behaviour.
            else if (is_halt) state_q <= ST_HALTWB;
            else if (st_issue && !st_refused) state_q <= ST_STREAMW;
            else              state_q <= ST_WRITEBACK;
          end
        end
        ST_STREAMW:   if (st_ptr_we) state_q <= ST_WRITEBACK;   // the engine's raw pulse
        ST_WRITEBACK: state_q <= ST_DECODE;
        ST_HALTWB:    state_q <= ST_HALTED;
        ST_HALTED:    state_q <= ST_HALTED;
        default:      state_q <= ST_DECODE;
      endcase
    end
  end

endmodule
