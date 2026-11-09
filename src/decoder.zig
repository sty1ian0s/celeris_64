//! Celeris-64 decoder: one 64-bit word -> one tagged instruction.
//!
//! Normative reference: docs/isa-encoding.md §2 (word layout), §3 (opcode map),
//! §4 (register indices), §5 (width suffixes). The §2 layout is fixed:
//!
//!     opcode[63:56] | rd[55:52] | rs1[51:48] | operand[47:0]
//!
//! Fidelity: executable model. This is a real decoder over a real bit layout,
//! fully tested. It is a pure function of the word: no allocation, no VM access,
//! no hidden state, so decoding the same word twice gives the same result.
//!
//! The contract property the assembler and disassembler both depend on is
//! `encode(decode(w)) == w` for every word carrying a defined opcode. The
//! Instruction union therefore carries every field that affects the bits, and
//! `encode` is the literal inverse of `decode` — field for field, no defaults.
//! The instruction text and the accelerator sub-opcode are recovered from the
//! raw opcode byte, so nothing is invented.

const std = @import("std");
const regs = @import("registers.zig");
const diag = @import("diagnostics.zig");

/// One width type for the whole codebase: registers.zig's. Values 0..3 are
/// full/.l/.w/.b; 4..15 are reserved and are reported, never guessed.
pub const Width = regs.Width;

pub const Diagnostic = diag.Diagnostic;

/// The status enum produced by `compare` (§3.2.1). Exactly one value is
/// produced; a bare boolean is a spec violation. These are the values the
/// architecture assigns and the values `compare` writes into `rd`.
pub const Status = enum(u4) {
    EQUAL = 0,
    LESS = 1,
    GREATER = 2,
    UNSIGNED_LESS = 3,
    UNSIGNED_GREATER = 4,

    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .EQUAL => "EQUAL",
            .LESS => "LESS",
            .GREATER => "GREATER",
            .UNSIGNED_LESS => "UNSIGNED_LESS",
            .UNSIGNED_GREATER => "UNSIGNED_GREATER",
        };
    }

    /// Decode a status value held in a register. Null for a value the
    /// architecture does not define, so `select` can report it instead of
    /// silently choosing an arm.
    pub fn fromValue(raw: u64) ?Status {
        return if (raw > 4) null else @enumFromInt(@as(u4, @intCast(raw)));
    }
};

/// The single opcode map, §3. One entry per §3 opcode, so the instruction
/// union, the assembler, the disassembler and the VM share one vocabulary.
pub const Opcode = enum(u8) {
    nop = 0x00,
    halt = 0x01,
    jump = 0x02,
    call = 0x03,
    ret = 0x04,
    branch = 0x05,

    add = 0x10,
    sub = 0x11,
    mul = 0x12,
    div = 0x13,
    and_ = 0x14,
    or_ = 0x15,
    xor_ = 0x16,
    shl = 0x17,
    shr = 0x18,
    mov = 0x19,
    load = 0x1A,
    store = 0x1B,

    compare = 0x20,
    select = 0x21,

    field_extract = 0x30,
    field_insert = 0x31,

    stream_add = 0x40,
    stream_copy = 0x41,
    stream_fill = 0x42,
    stream_setp = 0x43,

    cap_load = 0x50,
    cap_store = 0x51,
    cap_check = 0x52,

    thread_spawn = 0x90,
    thread_join = 0x91,
    thread_yield = 0x92,

    /// The word's opcode is not defined by the §3 map (or is in the
    /// accelerator range 0x60-0x8F, whose operands a model module owns).
    unknown = 0xFE,

    pub fn mnemonic(self: Opcode) []const u8 {
        return switch (self) {
            .and_ => "and",
            .or_ => "or",
            .xor_ => "xor",
            .field_extract => "field.extract",
            .field_insert => "field.insert",
            .stream_add => "stream.add",
            .stream_copy => "stream.copy",
            .stream_fill => "stream.fill",
            .stream_setp => "stream.setp",
            .branch => "branch",
            .load => "load",
            .store => "store",
            .cap_load => "cap.load",
            .cap_store => "cap.store",
            .cap_check => "cap.check",
            .thread_spawn => "thread.spawn",
            .thread_join => "thread.join",
            .thread_yield => "thread.yield",
            .unknown => "<unknown>",
            else => @tagName(self),
        };
    }

    pub fn fromByte(raw: u8) ?Opcode {
        if (raw >= 0x60 and raw <= 0x8F) return null;
        return switch (raw) {
            0x00 => .nop,
            0x01 => .halt,
            0x02 => .jump,
            0x03 => .call,
            0x04 => .ret,
            0x10 => .add,
            0x11 => .sub,
            0x12 => .mul,
            0x13 => .div,
            0x14 => .and_,
            0x15 => .or_,
            0x16 => .xor_,
            0x17 => .shl,
            0x18 => .shr,
            0x19 => .mov,
            0x20 => .compare,
            0x21 => .select,
            0x30 => .field_extract,
            0x31 => .field_insert,
            0x40 => .stream_add,
            0x41 => .stream_copy,
            0x42 => .stream_fill,
            0x43 => .stream_setp,
            0x05 => .branch,
            0x1A => .load,
            0x1B => .store,
            0x50 => .cap_load,
            0x51 => .cap_store,
            0x52 => .cap_check,
            0x90 => .thread_spawn,
            0x91 => .thread_join,
            0x92 => .thread_yield,
            else => null,
        };
    }
};

// ---------------------------------------------------------------------------
// Instruction payloads. Each carries every field that affects its bits.
// ---------------------------------------------------------------------------

/// §3.0 control instructions: `imm48[47:0]` target address.
pub const Control = struct {
    /// The opcode byte, so `nop`/`halt`/`jump`/`call`/`ret` stay distinguishable
    /// while the payload carries the raw fields.
    opcode: u8,
    /// `imm48[47:0]` — target address, zero-extended to 64 bits.
    target: u64,
};

/// §3.0.1 `branch` — a status-enum test plus a PC-relative offset.
pub const Branch = struct {
    op: u8,
    /// The register holding a status enum produced by `compare` (§3.2.1).
    rs1: u4,
    /// The enum value to test against, 0..=4. Validated at decode.
    match_val: u4,
    /// Signed byte offset from the ADDRESS OF THE BRANCH INSTRUCTION, not from
    /// the following instruction — see §3.0.1. `jump`/`call` use an absolute
    /// imm48; the difference is deliberate.
    offset: i64,
    /// Raw operand, for the `.raw` fallback (F20-F26/F29 family).
    operand: u48 = 0,
};

/// §3.1.1 scalar memory access: `load rd, [rs1+imm]` / `store rs2, [rs1+imm]`.
pub const Mem = struct {
    op: u8,
    /// `load`: the destination. `store`: unused, must be zero.
    rd: u4,
    /// The base address register.
    rs1: u4,
    /// `store`: the value source. `load`: unused, must be zero.
    rs2: u4,
    /// Access width, §5. For `load` this is the destination's suffix; for
    /// `store` the source's.
    width: Width,
    /// Signed 28-bit byte displacement from `rs1`.
    offset: i64,
    /// Raw operand, for the `.raw` fallback.
    operand: u48 = 0,
};

/// §3.1 ALU, and §3.2 `compare`, which shares the same operand layout.
///
/// `imm` is the signed 28-bit immediate, sign-extended to 64 bits. The encoding
/// contract says "if imm28 != 0 the instruction is immediate form and rs2 is
/// ignored", so the encoded form is recovered from `imm` being exactly 0
/// (register form) or not (immediate form). `rs2` is retained either way: a
/// register-form instruction must not lose it, or `add R0, R1, R2` would not
/// round-trip.
pub const Alu = struct {
    op: u8,
    rd: u4,
    rs1: u4,
    rs2: u4,
    width: Width,
    imm: ?i64,
    /// The raw 48-bit operand field, kept verbatim so a word whose mnemonic
    /// cannot name every bit falls back to `.raw` without loss (F21/F29).
    operand: u48 = 0,
};

/// §3.2.2 select: `select rd, statusReg, [MATCH], trueReg, falseReg`.
pub const Select = struct {
    rd: u4,
    rs1: u4,
    match_val: Status,
    true_reg: u4,
    false_reg: u4,
    /// Raw operand, for the `.raw` fallback (F29).
    operand: u48 = 0,
};

/// §3.3 field slicing. `width` is a bit count, not a register width suffix.
pub const Field = struct {
    op: u8,
    rd: u4,
    rs1: u4,
    src2: u4,
    offset: u8,
    width: u8,
    /// Raw operand, for the `.raw` fallback (F25).
    operand: u48 = 0,
};

/// §3.4 stream engine. `stride` is the signed 40-bit byte stride of `stream.setp`;
/// for the other three it is zero and the chunk/element-width fields are used.
pub const Stream = struct {
    op: u8,
    rd: u4,
    rs1: u4,
    rs2: u4,
    /// Raw operand, for the `.raw` fallback (F26).
    operand: u48 = 0,
    chunk: u20,
    width: Width,
    stride: i64,
};

/// §3.5 capability instructions.
pub const Cap = struct {
    op: u8,
    rd: u4,
    rs1: u4,
    /// Raw operand. §3.5 reserves the whole field for `cap.*`, so the decoder
    /// rejects a non-zero value before this is ever populated (F15).
    operand: u48 = 0,
};

/// §3.7 thread instructions. `slots` is a bitmask, one bit per slot T0-T7.
pub const Thread = struct {
    op: u8,
    rs1: u4,
    /// §3.7 defines eight slots T0-T7, so the mask needs 8 bits; a u5
    /// silently made T5-T7 unrepresentable.
    slots: u8,
    /// Raw operand, for the `.raw` fallback (F23).
    operand: u48 = 0,
};

/// §3.6 accelerator instructions. The opcode is the raw 0x60-0x8F byte; the
/// operand field is defined by the model module, so it is kept verbatim.
/// §3.6 (amendment 1.1). The operand field is now normative:
///   rs2[47:44] | rs3[43:40] | reserved[39:32] | count[31:0]
pub const Accelerator = struct {
    opcode: u8,
    rd: u4,
    rs1: u4,
    /// §3.6 rs2[47:44]; 0 means unused, not R0.
    rs2: u4,
    /// §3.6 rs3[43:40]; 0 means unused.
    rs3: u4,
    /// §3.6 count[31:0]; 0 means "derive from the destination register".
    count: u32,
    /// The raw operand field, kept verbatim so reserved opcodes round-trip.
    operand: u48,
};

/// True when the opcode byte is in the §3.6 accelerator range 0x60-0x8F.
pub fn isAcceleratorByte(op_byte: u8) bool {
    return op_byte >= 0x60 and op_byte <= 0x8F;
}

/// The §3.6 model module that owns an accelerator opcode: `matrix`, `fft` or
/// `codec`. The accelerator space is split by high nibble, so the group is a
/// pure function of the opcode byte.
pub fn acceleratorGroup(op_byte: u8) []const u8 {
    if (op_byte >= 0x60 and op_byte <= 0x6F) return "matrix";
    if (op_byte >= 0x70 and op_byte <= 0x7F) return "fft";
    return "codec";
}

/// One variant per §3 opcode. The tag is the opcode, so a `switch` on the
/// instruction is a `switch` on the opcode map.
pub const Instruction = union(enum) {
    nop,
    halt,
    jump: Control,
    call: Control,
    ret,
    branch: Branch,

    add: Alu,
    sub: Alu,
    mul: Alu,
    div: Alu,
    and_: Alu,
    or_: Alu,
    xor_: Alu,
    shl: Alu,
    shr: Alu,
    mov: Alu,
    load: Mem,
    store: Mem,

    compare: Alu,
    select: Select,

    field_extract: Field,
    field_insert: Field,

    stream_add: Stream,
    stream_copy: Stream,
    stream_fill: Stream,
    stream_setp: Stream,

    cap_load: Cap,
    cap_store: Cap,
    cap_check: Cap,

    thread_spawn: Thread,
    thread_join: Thread,
    thread_yield: Thread,

    accelerator: Accelerator,
};

pub const DecodeResult = union(enum) {
    ok: Instruction,
    err: Diagnostic,
};

/// The raw opcode byte of an instruction.
pub fn opcodeOf(ins: Instruction) u8 {
    return switch (ins) {
        .nop => 0x00,
        .halt => 0x01,
        .jump => |c| c.opcode,
        .call => |c| c.opcode,
        .ret => 0x04,
        .add => |a| a.op,
        .sub => |a| a.op,
        .mul => |a| a.op,
        .div => |a| a.op,
        .and_ => |a| a.op,
        .or_ => |a| a.op,
        .xor_ => |a| a.op,
        .shl => |a| a.op,
        .shr => |a| a.op,
        .mov => |a| a.op,
        .compare => |a| a.op,
        .select => 0x21,
        .field_extract => |f| f.op,
        .field_insert => |f| f.op,
        .stream_add => |s| s.op,
        .stream_copy => |s| s.op,
        .stream_fill => |s| s.op,
        .stream_setp => |s| s.op,
        .branch => |b| b.op,
        .load => |m| m.op,
        .store => |m| m.op,
        .cap_load => |c| c.op,
        .cap_store => |c| c.op,
        .cap_check => |c| c.op,
        .thread_spawn => |t| t.op,
        .thread_join => |t| t.op,
        .thread_yield => |t| t.op,
        .accelerator => |a| a.opcode,
    };
}

// ---------------------------------------------------------------------------
// §2 bit-field helpers
// ---------------------------------------------------------------------------

/// The opcode byte, §2.
pub fn opcodeOfWord(word: u64) u8 {
    return @truncate(word >> 56);
}

/// The `rd` field, §2.
pub fn rdOfWord(word: u64) u4 {
    return @truncate(word >> 52);
}

/// The `rs1` field, §2.
pub fn rs1OfWord(word: u64) u4 {
    return @truncate(word >> 48);
}

/// The `operand[47:0]` field, §2.
pub fn operandOfWord(word: u64) u48 {
    return @truncate(word);
}

/// The §4 register index of a field, with the reserved-width check applied to
/// the width nibble where a width is present.
pub fn registerName(index: u4) []const u8 {
    return switch (index) {
        0...11 => "R0",
        12 => "SP",
        13 => "LR",
        14 => "PC",
        15 => "FLAGS",
    };
}

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

/// Decodes one fixed 64-bit word per §2/§3. Pure: no allocation, no state.
/// Never panics: a word whose opcode is not defined, whose width nibble is
/// reserved (§5) or whose status value is not defined (§3.2.1) comes back as
/// `.err` with a plain-language sentence.
///
/// The union tag comes from the opcode, not from a helper: a runtime byte cannot
/// select a union tag, so every dispatch below is an explicit switch on the
/// opcode. That is why the ten ALU opcodes, the three capability opcodes and the
/// three thread opcodes each get their own arm.
pub fn decode(word: u64) DecodeResult {
    const op_byte = opcodeOfWord(word);
    const rd = rdOfWord(word);
    const rs1 = rs1OfWord(word);
    const operand = operandOfWord(word);

    // §3.6: the accelerator range 0x60-0x8F is owned by matrix/fft/codec.
    if (isAcceleratorByte(op_byte)) {
        // §3.6: reserved[39:32] must be zero. A non-zero value is a diagnostic
        // error, so the space stays available for future operands.
        const reserved: u8 = @truncate(operand >> 32);
        if (reserved != 0) {
            return .{ .err = reservedBitsDiagnostic(word, reserved) };
        }
        return .{ .ok = .{ .accelerator = .{
            .opcode = op_byte,
            .rd = rd,
            .rs1 = rs1,
            .rs2 = @truncate(operand >> 44),
            .rs3 = @truncate(operand >> 40),
            .count = @truncate(operand),
            .operand = operand,
        } } };
    }

    return switch (op_byte) {
        0x00 => noOperandOrErrNop(word, rd, rs1, operand),
        0x01 => noOperandOrErrHalt(word, rd, rs1, operand),
        0x04 => controlOrErr(.ret, word, op_byte, rd, rs1, operand),
        0x05 => branchOrErr(word, op_byte, rd, rs1, operand),
        0x02 => controlOrErr(.jump, word, op_byte, rd, rs1, operand),
        0x03 => controlOrErr(.call, word, op_byte, rd, rs1, operand),

        0x10 => aluOrErr(.add, word, op_byte, rd, rs1, operand),
        0x11 => aluOrErr(.sub, word, op_byte, rd, rs1, operand),
        0x12 => aluOrErr(.mul, word, op_byte, rd, rs1, operand),
        0x13 => aluOrErr(.div, word, op_byte, rd, rs1, operand),
        0x14 => aluOrErr(.and_, word, op_byte, rd, rs1, operand),
        0x15 => aluOrErr(.or_, word, op_byte, rd, rs1, operand),
        0x16 => aluOrErr(.xor_, word, op_byte, rd, rs1, operand),
        0x17 => aluOrErr(.shl, word, op_byte, rd, rs1, operand),
        0x18 => aluOrErr(.shr, word, op_byte, rd, rs1, operand),
        0x19 => aluOrErr(.mov, word, op_byte, rd, rs1, operand),
        0x1A => memOrErr(.load, word, op_byte, rd, rs1, operand),
        0x1B => memOrErr(.store, word, op_byte, rd, rs1, operand),
        0x20 => aluOrErr(.compare, word, op_byte, rd, rs1, operand),

        0x21 => selectOrErr(word, rd, rs1, operand),

        0x30 => fieldOrErr(.field_extract, word, op_byte, rd, rs1, operand),
        0x31 => fieldOrErr(.field_insert, word, op_byte, rd, rs1, operand),

        0x40 => streamOrErr(.stream_add, word, op_byte, rd, rs1, operand),
        0x41 => streamOrErr(.stream_copy, word, op_byte, rd, rs1, operand),
        0x42 => streamOrErr(.stream_fill, word, op_byte, rd, rs1, operand),
        0x43 => streamOrErr(.stream_setp, word, op_byte, rd, rs1, operand),

        0x50 => capOrErr(.cap_load, word, op_byte, rd, rs1, operand),
        0x51 => capOrErr(.cap_store, word, op_byte, rd, rs1, operand),
        0x52 => capOrErr(.cap_check, word, op_byte, rd, rs1, operand),

        0x90 => threadOrErr(.thread_spawn, word, op_byte, rs1, operand),
        0x91 => threadOrErr(.thread_join, word, op_byte, rs1, operand),
        0x92 => threadOrErr(.thread_yield, word, op_byte, rs1, operand),

        else => .{ .err = unknownOpcode(word, op_byte) },
    };
}

// -- tag dispatch helpers ---------------------------------------------------
//
// Each helper is comptime-tagged on the opcode so the returned union variant is
// the real opcode. The `comptime` parameter is not a runtime argument: it is
// the tag the switch arm at the call site selected.

/// §3.1/§3.2.1: rs2[47:44], width[43:40], signed imm28[39:0].
///
/// The ALU operand is the same for every opcode in the group, so one helper
/// builds the payload and the tag is the `comptime` argument.
fn aluOrErr(comptime tag: Opcode, word: u64, op_byte: u8, rd: u4, rs1: u4, operand: u48) DecodeResult {
    // §4: "in rs1/rs2 it is legal for SP, LR and FLAGS and a diagnostic error for
    // PC." The assembler enforced that (parseSourceReg), the decoder did not, so
    // `run-bin` executed a word the assembler refuses (F27:
    // 0x124E02000995E499 -> `mul R4.w, PC, -107617127`, exit 0). The assembler
    // is not the only entry point — the F8 rule, applied in both layers.
    if (rs1 == 14) return .{ .err = pcAsSourceDiagnostic(word) };

    const raw_rs2: u4 = @truncate(operand >> 44);
    const raw_width: u4 = @truncate(operand >> 40);
    const raw_imm: u28 = @truncate(operand);

    // §3.1 amendment 1.2: bits [39:28] are reserved and must be zero; a non-zero
    // value is a diagnostic error (§7). SCOPED TO THIS CLASS: `stream.setp`
    // (§3.4) legally defines operand[39:0] as a signed 40-bit stride over the
    // same bits, so this check must never be hoisted to a global one.
    const reserved: u12 = @truncate(operand >> 28);
    if (reserved != 0) return .{ .err = aluReservedBitsDiagnostic(word, reserved) };

    const width = Width.fromEncoded(raw_width) catch return .{ .err = widthDiagnostic(op_byte, raw_width) };
    const imm: ?i64 = if (raw_imm == 0) null else @as(i64, @as(i28, @bitCast(raw_imm)));

    if (raw_rs2 == 14 and raw_imm != 0) return .{ .err = pcAsSourceDiagnostic(word) };

    const a = Alu{ .op = op_byte, .rd = rd, .rs1 = rs1, .rs2 = raw_rs2, .width = width, .imm = imm, .operand = operand };
    return .{ .ok = tagOf(tag, a) };
}

/// §3.2.2: rs2[47:44] = match value, trueReg[43:40], falseReg[39:36].
fn selectOrErr(word: u64, rd: u4, rs1: u4, operand: u48) DecodeResult {
    const raw_match: u4 = @truncate(operand >> 44);
    const match = Status.fromValue(raw_match) orelse return .{ .err = matchDiagnostic(raw_match) };

    // §3.2.2: operand[35:0] is reserved and must be zero; non-zero is rejected
    // (§7). Scoped to select: the bits carry other meanings in other classes.
    const select_reserved: u36 = @truncate(operand);
    if (select_reserved != 0) return .{ .err = selectReservedBitsDiagnostic(word, select_reserved) };
    return .{ .ok = .{ .select = .{
        .rd = rd,
        .rs1 = rs1,
        .match_val = match,
        .true_reg = @truncate(operand >> 40),
        .false_reg = @truncate(operand >> 36),
        .operand = operand,
    } } };
}

/// §3.3: offset[47:40], width[39:32], src2[31:28].
/// §3.0 (v1.7): `jump`, `call` and `ret` carry `imm48` in the operand field, so
/// `rd[55:52]` and `rs1[51:48]` are unused and must be zero. Only `nop`/`halt`
/// were previously marked "must be zero", which implied the rest of the control
/// group was unconstrained — it is not.
fn controlOrErr(comptime tag: Opcode, word: u64, op_byte: u8, rd: u4, rs1: u4, operand: u48) DecodeResult {
    if (rd != 0 or rs1 != 0) {
        return .{ .err = controlUnusedBitsDiagnostic(word) };
    }
    return .{ .ok = switch (tag) {
        .ret => .ret,
        .jump => .{ .jump = .{ .opcode = op_byte, .target = @as(u64, operand) } },
        else => .{ .call = .{ .opcode = op_byte, .target = @as(u64, operand) } },
    } };
}

/// §3.0.1 `branch`: rs1 = status register, operand[47:44] = match value,
/// operand[43:40] = width, operand[39:28] reserved, operand[27:0] = signed
/// byte offset RELATIVE to the branch instruction.
fn branchOrErr(word: u64, op_byte: u8, rd: u4, rs1: u4, operand: u48) DecodeResult {
    // `rd` has no meaning for a branch: the target is an immediate offset, and
    // nothing is written back. A non-zero value is rejected rather than ignored,
    // the same rule jump/call/ret already follow.
    if (rd != 0) return .{ .err = branchUnusedBitsDiagnostic(word) };

    const match_raw: u4 = @truncate(operand >> 44);
    if (match_raw > 4) return .{ .err = branchMatchDiagnostic(word, match_raw) };

    const reserved: u12 = @truncate(operand >> 28);
    if (reserved != 0) return .{ .err = branchReservedBitsDiagnostic(word, reserved) };

    // §3.0.1: operand[43:40] is RESERVED for a branch. A branch narrows nothing,
    // so the field carries no information — and "validate it but drop it" would
    // let a word decode, lose four bits on re-emit, and re-assemble differently.
    // The round-trip fuzzer caught exactly that. Reserved means rejected when set.
    const raw_width: u4 = @truncate(operand >> 40);
    if (raw_width != 0) return .{ .err = branchReservedBitsDiagnostic(word, raw_width) };

    const raw_off: u28 = @truncate(operand);
    const offset = @as(i64, @as(i28, @bitCast(raw_off)));

    // §1: every instruction is 8 bytes, so a branch offset that is not a multiple
    // of 8 cannot name an instruction boundary. The assembler enforced this; the
    // decoder did not, so a blob could carry a branch to the middle of an
    // instruction — and the round-trip fuzzer caught it, because such a word
    // renders as text the assembler then refuses. The three `branch` checks form
    // the by-now-standard two-layer rule: the assembler is not the only entry
    // point, and `run-bin` loads images it never sees.
    if (@rem(offset, 8) != 0) return .{ .err = branchUnalignedDiagnostic(word, offset) };

    return .{ .ok = .{ .branch = .{
        .op = op_byte,
        .rs1 = rs1,
        .match_val = match_raw,
        .offset = offset,
        .operand = operand,
    } } };
}

/// §3.1.1 `load`/`store`.
fn memOrErr(comptime tag: Opcode, word: u64, op_byte: u8, rd: u4, rs1: u4, operand: u48) DecodeResult {
    const raw_rs2: u4 = @truncate(operand >> 44);

    // `load` writes rd and has no source register; `store` reads rs2 and writes
    // nothing. Either way the unused field must be zero, enforced HERE as well as
    // in the assembler because `run-bin` loads blobs the assembler never sees.
    if (tag == .load and raw_rs2 != 0) return .{ .err = memUnusedSourceDiagnostic(word) };
    if (tag == .store and rd != 0) return .{ .err = memUnusedDestDiagnostic(word) };

    const reserved: u12 = @truncate(operand >> 28);
    if (reserved != 0) return .{ .err = aluReservedBitsDiagnostic(word, reserved) };

    const raw_width: u4 = @truncate(operand >> 40);
    const width = Width.fromEncoded(raw_width) catch return .{ .err = widthDiagnostic(op_byte, raw_width) };

    const raw_off: u28 = @truncate(operand);
    const m = Mem{
        .op = op_byte,
        .rd = rd,
        .rs1 = rs1,
        .rs2 = raw_rs2,
        .width = width,
        .offset = @as(i64, @as(i28, @bitCast(raw_off))),
        .operand = operand,
    };
    return switch (tag) {
        .load => .{ .ok = .{ .load = m } },
        else => .{ .ok = .{ .store = m } },
    };
}

fn branchUnusedBitsDiagnostic(word: u64) Diagnostic {
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 1, .name = "destination register field", .text = "non-zero" },
        .expected = "the destination register field to be zero, because a branch carries its target as an immediate offset and writes nothing back (docs/isa-encoding.md §3.0.1)",
        .detail = "The instruction was not decoded; unused bits are rejected rather than ignored, so the encoding cannot silently acquire a meaning later.",
    };
}

fn branchMatchDiagnostic(word: u64, value: u4) Diagnostic {
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "an undefined value";
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 2, .name = "branch match value", .text = text },
        .expected = "one of the five status enum values EQUAL, LESS, GREATER, UNSIGNED_LESS or UNSIGNED_GREATER, from 0 to 4 (docs/isa-encoding.md §3.2.1)",
        .detail = "The instruction was not decoded; a branch testing a value that is not a status enum would never fire, which is far more likely a mistake than an intent.",
    };
}

fn branchUnalignedDiagnostic(word: u64, offset: i64) Diagnostic {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{offset}) catch "an unaligned offset";
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 3, .name = "branch offset", .text = text },
        .expected = "a byte offset that is a multiple of 8, because every instruction is 8 bytes and an offset that is not a multiple of 8 cannot name an instruction boundary (docs/isa-encoding.md §1)",
        .detail = "The instruction was not decoded; the assembler refuses this form, and the decoder must not accept what the assembler rejects.",
    };
}

fn branchReservedBitsDiagnostic(word: u64, reserved: u12) Diagnostic {
    std.debug.assert(reserved != 0);
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 3, .name = "reserved branch field", .text = "non-zero" },
        .expected = "operand[39:28] to be zero, because the branch layout reserves those bits (docs/isa-encoding.md §3.0.1)",
        .detail = "The instruction was not decoded; reserved means rejected when set, not ignored.",
    };
}

fn memUnusedSourceDiagnostic(word: u64) Diagnostic {
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 2, .name = "source register field", .text = "non-zero" },
        .expected = "the second-source register field to be zero, because `load` reads memory into rd and has no source register (docs/isa-encoding.md §3.1.1)",
        .detail = "The instruction was not decoded; unused bits are rejected rather than ignored, so a loaded image cannot carry bits no source line can express.",
    };
}

fn memUnusedDestDiagnostic(word: u64) Diagnostic {
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 1, .name = "destination register field", .text = "non-zero" },
        .expected = "the destination register field to be zero, because `store` writes memory and has no destination register (docs/isa-encoding.md §3.1.1)",
        .detail = "The instruction was not decoded; unused bits are rejected rather than ignored.",
    };
}

fn controlUnusedBitsDiagnostic(word: u64) Diagnostic {
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 1, .name = "unused register field", .text = "non-zero" },
        .expected = "the destination and first-source register fields to be zero, because this instruction carries an immediate and does not use them (docs/isa-encoding.md §3.0)",
        .detail = "The instruction was not decoded; unused bits are rejected rather than ignored, so the encoding cannot silently acquire a meaning later.",
    };
}

fn fieldOrErr(comptime tag: Opcode, word: u64, op_byte: u8, rd: u4, rs1: u4, operand: u48) DecodeResult {
    // §3.3 (v1.7): operand[27:0] is reserved and must be zero. An undocumented
    // range is not a licence — it is indistinguishable from an oversight, which
    // is exactly the shape of the earlier imm28 defect.
    if (@as(u28, @truncate(operand)) != 0) {
        return .{ .err = fieldReservedBitsDiagnostic(word) };
    }
    const f = Field{
        .op = op_byte,
        .rd = rd,
        .rs1 = rs1,
        .src2 = @truncate(operand >> 28),
        .offset = @truncate(operand >> 40),
        .width = @truncate(operand >> 32),
        .operand = operand,
    };

    // §3.3.1 (normative): `width` is 1..=64 and `offset + width <= 64`, because a
    // register holds exactly 64 bits. The assembler enforced this; the decoder did
    // not, so `run-bin` accepted offset=45,width=61 (F24:
    // 0x30512D3D00000000) where `asm` refused the same instruction. Execution was
    // safe — the field unit cannot address past 64 bits — but a word no source
    // line can express must not decode, or the two entry points disagree.
    if (f.width == 0 or f.width > 64) return .{ .err = fieldWidthDiagnostic(word, f.width) };
    if (@as(u16, f.offset) + @as(u16, f.width) > 64) {
        return .{ .err = fieldRangeDiagnostic(word, f.offset, f.width) };
    }
    return switch (tag) {
        .field_extract => .{ .ok = .{ .field_extract = f } },
        .field_insert => .{ .ok = .{ .field_insert = f } },
        else => unreachable,
    };
}

/// §3.4: rs2[47:44], chunk[43:24], width[23:20], reserved[19:0]; setp uses
/// signed 40-bit stride[39:0].
fn streamOrErr(comptime tag: Opcode, word: u64, op_byte: u8, rd: u4, rs1: u4, operand: u48) DecodeResult {
    if (tag == .stream_setp) {
        // §3.4: `setp` uses `rd` (the pointer register) and operand[39:0] (the
        // signed stride) and nothing else. `rs1` and operand[47:40] had no rule
        // requiring them to be zero, so a word carrying them decoded and the
        // renderer dropped them (F19: 0x43BAB89E3BCCB87F lost rs1=10 and
        // operand[47:40]=184). Contract gap + silent loss, closed on both layers.
        if (rs1 != 0) return .{ .err = setpUnusedRegisterDiagnostic(word) };
        if (@as(u8, @truncate(operand >> 40)) != 0) {
            return .{ .err = setpReservedBitsDiagnostic(word) };
        }
        const s = Stream{
            .op = op_byte,
            .rd = rd,
            .rs1 = rs1,
            .rs2 = 0,
            .chunk = 0,
            .width = .full,
            .stride = @as(i64, @as(i40, @bitCast(@as(u40, @truncate(operand))))),
        };
        return .{ .ok = .{ .stream_setp = s } };
    }
    // §3.4: `operand[19:0]` is reserved and a non-zero value is a diagnostic
    // error — "reserved means REJECTED when set, not ignored". SCOPED to
    // add/copy/fill: `stream.setp` legally uses [39:0] for its 40-bit stride and
    // returned above, so this check cannot over-reach into it.
    if (@as(u20, @truncate(operand)) != 0) {
        return .{ .err = streamReservedBitsDiagnostic(word, op_byte) };
    }

    const raw_width: u4 = @truncate(operand >> 20);
    const width = Width.fromEncoded(raw_width) catch return .{ .err = widthDiagnostic(op_byte, raw_width) };
    const s = Stream{
        .op = op_byte,
        .rd = rd,
        .rs1 = rs1,
        .rs2 = @truncate(operand >> 44),
        .chunk = @truncate(operand >> 24),
        .width = width,
        .stride = 0,
    };
    return switch (tag) {
        .stream_add => .{ .ok = .{ .stream_add = s } },
        .stream_copy => .{ .ok = .{ .stream_copy = s } },
        .stream_fill => .{ .ok = .{ .stream_fill = s } },
        else => unreachable,
    };
}

/// Wraps an ALU payload in the union variant named by `tag`. A comptime switch
/// is the only way to choose a union tag in Zig, so the ten tags are spelled out.
fn tagOf(comptime tag: Opcode, a: Alu) Instruction {
    return switch (tag) {
        .add => .{ .add = a },
        .sub => .{ .sub = a },
        .mul => .{ .mul = a },
        .div => .{ .div = a },
        .and_ => .{ .and_ = a },
        .or_ => .{ .or_ = a },
        .xor_ => .{ .xor_ = a },
        .shl => .{ .shl = a },
        .shr => .{ .shr = a },
        .mov => .{ .mov = a },
        .compare => .{ .compare = a },
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------

/// The exact inverse of `decode` for every word the §3 map defines.
///
/// Field-for-field, no defaults: `opcode` is the raw byte from the payload, so
/// the `rd`/`rs1` bits of the opcode and the whole `operand` field come back
/// unchanged. `encode(decode(w)) == w` holds for every word whose opcode is
/// defined and whose width/status fields are valid — the words the decoder
/// accepts. An undecodable word is reported as `.err`, never re-encoded, so
/// there is no "close enough" path.
pub fn encode(ins: Instruction) u64 {
    return switch (ins) {
        .nop => assembleWord(0x00, 0, 0, 0),
        .halt => assembleWord(0x01, 0, 0, 0),
        .ret => assembleWord(0x04, 0, 0, 0),
        .jump => |c| assembleWord(c.opcode, 0, 0, @truncate(c.target)),
        .call => |c| assembleWord(c.opcode, 0, 0, @truncate(c.target)),

        .add => |a| encodeAlu(a),
        .sub => |a| encodeAlu(a),
        .mul => |a| encodeAlu(a),
        .div => |a| encodeAlu(a),
        .and_ => |a| encodeAlu(a),
        .or_ => |a| encodeAlu(a),
        .xor_ => |a| encodeAlu(a),
        .shl => |a| encodeAlu(a),
        .shr => |a| encodeAlu(a),
        .mov => |a| encodeAlu(a),
        .compare => |a| encodeAlu(a),

        .select => |s| encodeSelect(s),

        .field_extract => |f| encodeField(f),
        .field_insert => |f| encodeField(f),

        .stream_add => |s| encodeStream(s),
        .stream_copy => |s| encodeStream(s),
        .stream_fill => |s| encodeStream(s),
        .stream_setp => |s| encodeStream(s),

        .branch => |b| encodeBranch(b),
        .load => |m| encodeMem(m),
        .store => |m| encodeMem(m),
        .cap_load => |c| assembleWord(c.op, c.rd, c.rs1, 0),
        .cap_store => |c| assembleWord(c.op, c.rd, c.rs1, 0),
        .cap_check => |c| assembleWord(c.op, c.rd, c.rs1, 0),

        .thread_spawn => |t| assembleWord(t.op, 0, t.rs1, @as(u48, t.slots)),
        .thread_join => |t| assembleWord(t.op, 0, t.rs1, @as(u48, t.slots)),
        .thread_yield => |t| assembleWord(t.op, 0, t.rs1, @as(u48, t.slots)),

        .accelerator => |a| assembleWord(a.opcode, a.rd, a.rs1, a.operand),
    };
}

/// §2: opcode[63:56] | rd[55:52] | rs1[51:48] | operand[47:0].
pub fn assembleWord(opcode: u8, rd: u4, rs1: u4, operand: u48) u64 {
    return (@as(u64, opcode) << 56) | (@as(u64, rd) << 52) | (@as(u64, rs1) << 48) | @as(u64, operand);
}

/// §3.0.1: rs2[47:44] = match value, width[43:40], reserved[39:28] = 0,
/// offset[27:0] = signed byte displacement from the branch itself.
fn encodeBranch(b: Branch) u64 {
    const raw_off: u28 = @truncate(@as(u64, @bitCast(b.offset)));
    const operand: u48 = (@as(u48, b.match_val) << 44) | raw_off;
    return assembleWord(b.op, 0, b.rs1, operand);
}

/// §3.1.1: rs2[47:44], width[43:40], reserved[39:28] = 0, offset[27:0].
fn encodeMem(m: Mem) u64 {
    const raw_off: u28 = @truncate(@as(u64, @bitCast(m.offset)));
    const operand: u48 = (@as(u48, m.rs2) << 44) |
        (@as(u48, @intFromEnum(m.width)) << 40) |
        raw_off;
    return assembleWord(m.op, m.rd, m.rs1, operand);
}

/// §3.1: rs2[47:44], width[43:40], signed imm28[39:0]. `imm == null` means
/// register form, so imm28 is zero and rs2 is the source.
fn encodeAlu(a: Alu) u64 {
    const raw_imm: u28 = if (a.imm) |imm| @truncate(@as(u64, @bitCast(imm))) else 0;
    const operand: u48 = (@as(u48, a.rs2) << 44) | (@as(u48, @intFromEnum(a.width)) << 40) | raw_imm;
    return assembleWord(a.op, a.rd, a.rs1, operand);
}

/// §3.2.2: match[47:44], trueReg[43:40], falseReg[39:36].
fn encodeSelect(s: Select) u64 {
    const operand: u48 = (@as(u48, @intFromEnum(s.match_val)) << 44) |
        (@as(u48, s.true_reg) << 40) |
        (@as(u48, s.false_reg) << 36);
    return assembleWord(0x21, s.rd, s.rs1, operand);
}

/// §3.3: offset[47:40], width[39:32], src2[31:28].
fn encodeField(f: Field) u64 {
    const operand: u48 = (@as(u48, f.offset) << 40) |
        (@as(u48, f.width) << 32) |
        (@as(u48, f.src2) << 28);
    return assembleWord(f.op, f.rd, f.rs1, operand);
}

/// §3.4: rs2[47:44], chunk[43:24], width[23:20]; setp uses signed 40-bit
/// stride[39:0] and leaves the rest of the operand field zero.
fn encodeStream(s: Stream) u64 {
    if (s.op == 0x43) {
        const raw: u40 = @truncate(@as(u64, @bitCast(s.stride)));
        return assembleWord(s.op, s.rd, s.rs1, @as(u48, raw));
    }
    const operand: u48 = (@as(u48, s.rs2) << 44) |
        (@as(u48, s.chunk) << 24) |
        (@as(u48, @intFromEnum(s.width)) << 20);
    return assembleWord(s.op, s.rd, s.rs1, operand);
}

// ---------------------------------------------------------------------------
// Diagnostics (§4.2: plain sentences, never a bare hex code)
// ---------------------------------------------------------------------------

/// §3.6/§7: non-zero reserved bits, reported as a sentence naming the field and
/// the value. Never a bare hex token (AGENTS.md §4.2).
fn reservedBitsDiagnostic(word: u64, reserved: u8) Diagnostic {
    // Only called when the field is non-zero; the assertion documents that
    // precondition and keeps the parameter meaningful.
    std.debug.assert(reserved != 0);
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{
            .index = 3,
            .name = "accelerator reserved field",
            .text = "non-zero",
        },
        .expected = "the reserved bits between the third source register and the count to be zero, because the encoding contract reserves them for future operands",
        .detail = "The instruction was not decoded; a non-zero reserved field is rejected rather than ignored, so an encoding cannot silently change meaning later.",
    };
}

/// §3.0: `nop` and `halt` carry no operands at all, so rd, rs1 and the whole
/// operand field must be zero. `ret` is excluded: §3.0 lists it as "jumps to LR"
/// with no "must be zero" clause.
fn noOperandOrErrNop(word: u64, rd: u4, rs1: u4, operand: u48) DecodeResult {
    if (rd != 0 or rs1 != 0 or operand != 0) return .{ .err = noOperandDiagnostic(word) };
    return .{ .ok = .nop };
}

fn noOperandOrErrHalt(word: u64, rd: u4, rs1: u4, operand: u48) DecodeResult {
    if (rd != 0 or rs1 != 0 or operand != 0) return .{ .err = noOperandDiagnostic(word) };
    return .{ .ok = .halt };
}

/// §3.7 (v1.6). The slot mask is `operand[7:0]` — eight bits, one per slot T0-T7 —
/// and `operand[47:8]` is reserved and must be zero. v1.5 declared the mask as
/// `operand[4:0]`, which cannot address eight slots: `T0-T7` necessarily writes
/// 0xFF and set the "reserved" bits. The section forbade the word its own slot
/// range required. This check implements the corrected rule.
fn threadOrErr(comptime tag: Opcode, word: u64, op_byte: u8, rs1: u4, operand: u48) DecodeResult {
    const reserved: u40 = @truncate(operand >> 8);
    if (reserved != 0) return .{ .err = threadReservedBitsDiagnostic(word) };

    // §3.7 names `rs1` for `thread.spawn` only ("at address `rs1`"). `join` and
    // `yield` never define it, so a non-zero value there is a word the mnemonic
    // cannot express and re-assembly destroyed it silently (F23:
    // 0x91120000000000F1 lost rs1=2). Reserving it here keeps the check in the
    // decoder as well as the assembler — the F8 two-layer rule.
    if (tag != .thread_spawn and rs1 != 0) {
        return .{ .err = threadUnusedRegisterDiagnostic(word) };
    }
    const insn = Thread{ .op = op_byte, .rs1 = rs1, .slots = @truncate(operand), .operand = operand };
    return .{ .ok = switch (tag) {
        .thread_spawn => .{ .thread_spawn = insn },
        .thread_join => .{ .thread_join = insn },
        else => .{ .thread_yield = insn },
    } };
}

/// §3.5 (amendment 1.11, corrected by 1.14 / defect F15). The whole
/// `operand[47:0]` field is reserved and must be zero — "whole-field, not just
/// the `rs2` bits at `[47:44]`" — and the reservation must be enforced *in the
/// decoder*, because the assembler never sees a hand-built or loaded image and a
/// blob is the primary input of `run-bin`.
///
/// This is what keeps `Cap` narrow (`op`, `rd`, `rs1`): the operand cannot reach
/// the struct, so widening it would carry a field no legal instruction can set.
fn capOrErr(comptime tag: Opcode, word: u64, op_byte: u8, rd: u4, rs1: u4, operand: u48) DecodeResult {
    if (operand != 0) return .{ .err = capReservedBitsDiagnostic(word) };
    const insn = Cap{ .op = op_byte, .rd = rd, .rs1 = rs1 };
    return .{ .ok = switch (tag) {
        .cap_load => .{ .cap_load = insn },
        .cap_store => .{ .cap_store = insn },
        else => .{ .cap_check = insn },
    } };
}

/// §3.4: `stream.setp` defines no `rs1`.
fn setpUnusedRegisterDiagnostic(word: u64) Diagnostic {
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 1, .name = "first source register", .text = "non-zero" },
        .expected = "the first-source register field to be zero, because `stream.setp` names its pointer with `rd` and carries its stride in operand[39:0] (docs/isa-encoding.md §3.4)",
        .detail = "The instruction was not decoded; a field the text form cannot express is rejected rather than silently rewritten.",
    };
}

/// §3.4: `stream.setp`'s operand[47:40] is reserved.
fn setpReservedBitsDiagnostic(word: u64) Diagnostic {
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 2, .name = "reserved stream.setp field", .text = "non-zero" },
        .expected = "operand[47:40] to be zero, because `stream.setp` gives operand[39:0] to the stride and defines nothing above it (docs/isa-encoding.md §3.4)",
        .detail = "The instruction was not decoded; reserved means rejected when set, not ignored.",
    };
}

/// §3.3.1: a bit count outside 1..=64.
fn fieldWidthDiagnostic(word: u64, width: u8) Diagnostic {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{width}) catch "an out-of-range value";
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 2, .name = "field width", .text = text },
        .expected = "a width from 1 to 64 bits, because a register holds exactly 64 bits (docs/isa-encoding.md §3.3.1)",
        .detail = "The instruction was not decoded; a width outside the register size is rejected rather than reinterpreted.",
    };
}

/// §3.3.1: `offset + width` must not exceed 64 bits.
fn fieldRangeDiagnostic(word: u64, offset: u8, width: u8) Diagnostic {
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "offset {d} + width {d} = {d}", .{ offset, width, @as(u16, offset) + @as(u16, width) }) catch "an out-of-range value";
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 2, .name = "field offset and width", .text = text },
        .expected = "an offset and width whose sum is at most 64 bits, because a register holds exactly 64 bits and a field cannot extend past its end (docs/isa-encoding.md §3.3.1)",
        .detail = "The instruction was not decoded; the assembler refuses this form, and the decoder must not accept what the assembler rejects.",
    };
}

/// §4: index 14 (`PC`) in a source position is a diagnostic error. `SP`, `LR`
/// and `FLAGS` are legal sources; only `PC` is not, because a read of it as an
/// ordinary operand has no defined value.
fn pcAsSourceDiagnostic(word: u64) Diagnostic {
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 1, .name = "first source register", .text = "PC" },
        .expected = "a source register other than PC, because the program counter cannot be read as an ordinary operand (docs/isa-encoding.md §4); SP, LR and FLAGS are allowed",
        .detail = "The instruction was not decoded; the assembler refuses this form, and the decoder must not accept what the assembler rejects, or a loaded image would execute an instruction no source line can express.",
    };
}

/// §3.7: `rs1` is named for `thread.spawn` only; `join`/`yield` must have zero.
fn threadUnusedRegisterDiagnostic(word: u64) Diagnostic {
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 1, .name = "unused source register field", .text = "non-zero" },
        .expected = "the first-source register field to be zero, because §3.7 gives `rs1` a meaning for `thread.spawn` only and defines no source for `thread.join` or `thread.yield` (docs/isa-encoding.md §3.7)",
        .detail = "The instruction was not decoded; a field the mnemonic cannot name is rejected rather than silently rewritten, so a loaded image cannot carry bits the text form would destroy.",
    };
}

fn capReservedBitsDiagnostic(word: u64) Diagnostic {
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 1, .name = "capability reserved field", .text = "non-zero" },
        .expected = "the whole reserved operand field to be zero, because §3.5 names the pair with rd and rs1 alone and reserves every operand bit (docs/isa-encoding.md §3.5)",
        .detail = "The instruction was not decoded; a non-zero reserved field is rejected rather than ignored, so a loaded image cannot smuggle bits past the toolchain.",
    };
}

fn fieldReservedBitsDiagnostic(word: u64) Diagnostic {
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 5, .name = "field reserved field", .text = "non-zero" },
        .expected = "the reserved bits below the inserted-value register to be zero, because the encoding contract reserves them (docs/isa-encoding.md §3.3)",
        .detail = "The instruction was not decoded; a non-zero reserved field is rejected rather than ignored.",
    };
}

fn streamReservedBitsDiagnostic(word: u64, op_byte: u8) Diagnostic {
    _ = op_byte;
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 4, .name = "stream reserved field", .text = "non-zero" },
        .expected = "the reserved bits below the element width selector to be zero, because the encoding contract reserves them and reserves them for rejection (docs/isa-encoding.md §3.4)",
        .detail = "The instruction was not decoded; a non-zero reserved field is rejected rather than ignored.",
    };
}

fn threadReservedBitsDiagnostic(word: u64) Diagnostic {
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 1, .name = "thread reserved field", .text = "non-zero" },
        .expected = "the reserved bits above the slot mask to be zero, because the mask is the low eight bits and the rest are reserved (docs/isa-encoding.md §3.7)",
        .detail = "The instruction was not decoded; a non-zero reserved field is rejected rather than ignored.",
    };
}

fn noOperandDiagnostic(word: u64) Diagnostic {
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 1, .name = "operand field", .text = "non-zero" },
        .expected = "every operand bit to be zero, because this instruction takes no operands",
        .detail = "A zero opcode with stray bits set is not a different instruction, so it is rejected rather than silently ignored (docs/isa-encoding.md §3.0).",
    };
}

fn aluReservedBitsDiagnostic(word: u64, reserved: u12) Diagnostic {
    std.debug.assert(reserved != 0);
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 3, .name = "ALU reserved field", .text = "non-zero" },
        .expected = "the reserved bits between the immediate and the width selector to be zero, because the encoding contract reserves them (docs/isa-encoding.md §3.1)",
        .detail = "The instruction was not decoded; a non-zero reserved field is rejected rather than ignored, so the encoding cannot silently acquire a new meaning later.",
    };
}

fn selectReservedBitsDiagnostic(word: u64, reserved: u36) Diagnostic {
    std.debug.assert(reserved != 0);
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .operand = .{ .index = 6, .name = "select reserved field", .text = "non-zero" },
        .expected = "the reserved bits below the false-value register to be zero, because the encoding contract reserves them (docs/isa-encoding.md §3.2.2)",
        .detail = "The instruction was not decoded; a non-zero reserved field is rejected rather than ignored.",
    };
}

fn unknownOpcode(word: u64, op_byte: u8) Diagnostic {
    var d = Diagnostic{
        .stage = "decoding this instruction",
        .action = "decoded",
        .word = word,
        .expected = "an opcode from the Celeris-64 instruction map, such as 0x00 for nop, 0x10 for add, 0x21 for select or 0x40 for stream.add",
        .detail = "The opcode byte was not a defined instruction; the decoder did not guess.",
    };
    // Name the byte in the sentence without a bare hex token: the "opcode"
    // word introduces it, and the decimal is printed beside it.
    d.operand = .{ .name = "opcode", .text = opcodeText(op_byte) };
    d.action = "decoded";
    return d;
}

fn widthDiagnostic(op_byte: u8, raw: u4) Diagnostic {
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .operand = .{ .name = "width suffix", .text = widthText(raw) },
        .expected = "a width of 0 (full 64-bit), 1 (.l, 32-bit), 2 (.w, 16-bit) or 3 (.b, 8-bit)",
        .detail = "Width values 4 through 15 are reserved by the encoding contract, so this instruction was not decoded.",
        .word = (@as(u64, op_byte) << 56) | (@as(u64, raw) << 40),
    };
}

fn matchDiagnostic(raw: u4) Diagnostic {
    return .{
        .stage = "decoding this instruction",
        .action = "decoded",
        .operand = .{ .name = "match value", .text = statusText(raw) },
        .expected = "one of the status values EQUAL (0), LESS (1), GREATER (2), UNSIGNED_LESS (3) or UNSIGNED_GREATER (4)",
        .detail = "Status values 5 through 15 are not defined by the architecture, so the select was not decoded.",
    };
}

// ---------------------------------------------------------------------------
// Operand text. The `Diagnostic` type carries `[]const u8` slices, so these
// buffers are file-scope and are written once per call. A diagnostic is rendered
// immediately after it is produced, and the decoder's own tests render before
// asking for another one, so a single buffer is enough. The bytes are the
// decimal value, never a bare hex code: the sentence names the field first.
// ---------------------------------------------------------------------------

var text_scratch: [64]u8 = undefined;

pub fn opcodeText(op_byte: u8) []const u8 {
    return std.fmt.bufPrint(&text_scratch, "opcode {d} ({d})", .{ op_byte, op_byte }) catch "opcode";
}

pub fn widthText(raw: u4) []const u8 {
    return std.fmt.bufPrint(&text_scratch, "width {d} ({d})", .{ raw, raw }) catch "width";
}

pub fn statusText(raw: u4) []const u8 {
    return std.fmt.bufPrint(&text_scratch, "status value {d} ({d})", .{ raw, raw }) catch "status value";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "encode lays out the §2 fields: opcode[63:56] rd[55:52] rs1[51:48] operand[47:0]" {
    // 0x10 | rd=1 | rs1=2 | operand[47:44]=rs2=3.
    const w = encode(.{ .add = .{ .op = 0x10, .rd = 1, .rs1 = 2, .rs2 = 3, .width = .full, .imm = null } });
    try testing.expectEqual(@as(u8, 0x10), opcodeOfWord(w));
    try testing.expectEqual(@as(u4, 1), rdOfWord(w));
    try testing.expectEqual(@as(u4, 2), rs1OfWord(w));
    try testing.expectEqual(@as(u48, 0x300000000000), operandOfWord(w));
    try testing.expectEqual(@as(u64, 0x1012300000000000), w);
}

test "encode(decode(w)) == w for every opcode in the §3 map" {
    // Every word is built from the decoder's own encode, so the test cannot drift
    // from the §2 layout: it is a round-trip, not a re-derivation. The literal
    // words are chosen so each field exercises a different bit position.
    const words = [_]u64{
        encode(.nop),
        encode(.halt),
        encode(.ret),
        encode(.{ .jump = .{ .opcode = 0x02, .target = 0x1234 } }),
        encode(.{ .call = .{ .opcode = 0x03, .target = 0xABCD } }),
        encode(.{ .add = .{ .op = 0x10, .rd = 1, .rs1 = 2, .rs2 = 3, .width = .full, .imm = null } }),
        encode(.{ .sub = .{ .op = 0x11, .rd = 4, .rs1 = 5, .rs2 = 6, .width = .l, .imm = null } }),
        encode(.{ .mul = .{ .op = 0x12, .rd = 7, .rs1 = 8, .rs2 = 9, .width = .w, .imm = null } }),
        encode(.{ .div = .{ .op = 0x13, .rd = 10, .rs1 = 11, .rs2 = 12, .width = .b, .imm = null } }),
        encode(.{ .and_ = .{ .op = 0x14, .rd = 0, .rs1 = 0, .rs2 = 0, .width = .full, .imm = -7 } }),
        encode(.{ .or_ = .{ .op = 0x15, .rd = 1, .rs1 = 1, .rs2 = 1, .width = .full, .imm = 0x7FFFFFF } }),
        encode(.{ .xor_ = .{ .op = 0x16, .rd = 2, .rs1 = 2, .rs2 = 2, .width = .full, .imm = -0x8000000 } }),
        encode(.{ .shl = .{ .op = 0x17, .rd = 3, .rs1 = 3, .rs2 = 3, .width = .full, .imm = null } }),
        encode(.{ .shr = .{ .op = 0x18, .rd = 4, .rs1 = 4, .rs2 = 4, .width = .full, .imm = null } }),
        encode(.{ .mov = .{ .op = 0x19, .rd = 5, .rs1 = 0, .rs2 = 6, .width = .l, .imm = null } }),
        encode(.{ .compare = .{ .op = 0x20, .rd = 2, .rs1 = 0, .rs2 = 1, .width = .full, .imm = null } }),
        encode(.{ .select = .{ .rd = 3, .rs1 = 2, .match_val = .EQUAL, .true_reg = 4, .false_reg = 5 } }),
        encode(.{ .field_extract = .{ .op = 0x30, .rd = 0, .rs1 = 1, .src2 = 0, .offset = 12, .width = 3 } }),
        encode(.{ .field_insert = .{ .op = 0x31, .rd = 3, .rs1 = 1, .src2 = 2, .offset = 12, .width = 3 } }),
        encode(.{ .stream_add = .{ .op = 0x40, .rd = 0, .rs1 = 1, .rs2 = 2, .chunk = 64, .width = .full, .stride = 0 } }),
        encode(.{ .stream_copy = .{ .op = 0x41, .rd = 1, .rs1 = 2, .rs2 = 3, .chunk = 1, .width = .l, .stride = 0 } }),
        encode(.{ .stream_fill = .{ .op = 0x42, .rd = 2, .rs1 = 3, .rs2 = 0, .chunk = 0xFFFFF, .width = .b, .stride = 0 } }),
        // F19: `stream.setp` names its pointer with `rd` and defines no `rs1`,
        // so this fixture's old `rs1 = 1` is now a rejected word. The encoder
        // still exercises the field — the decode test must use a legal word.
        encode(.{ .stream_setp = .{ .op = 0x43, .rd = 0, .rs1 = 0, .rs2 = 0, .chunk = 0, .width = .full, .stride = -8 } }),
        encode(.{ .cap_load = .{ .op = 0x50, .rd = 0, .rs1 = 1 } }),
        encode(.{ .cap_store = .{ .op = 0x51, .rd = 2, .rs1 = 3 } }),
        encode(.{ .cap_check = .{ .op = 0x52, .rd = 4, .rs1 = 5 } }),
        encode(.{ .thread_spawn = .{ .op = 0x90, .rs1 = 1, .slots = 0b101 } }),
        encode(.{ .thread_join = .{ .op = 0x91, .rs1 = 0, .slots = 0b111 } }),
        encode(.{ .thread_yield = .{ .op = 0x92, .rs1 = 0, .slots = 0 } }),
        encode(.{ .accelerator = .{ .opcode = 0x60, .rd = 1, .rs1 = 2, .rs2 = 0, .rs3 = 0, .count = 0x1234, .operand = 0x1234 } }),
    };
    for (words) |w| {
        const d = decode(w);
        try testing.expect(d == .ok);
        try testing.expectEqual(w, encode(d.ok));
    }
}

test "call and jump keep distinct tags: only call sets LR, so the tag decides" {
    // 0x02 and 0x03 share a payload type, so the tag is the only thing that
    // separates them. Verifier caught this as a real defect: call used to decode
    // as jump and the VM then never set LR.
    const jump_word = encode(.{ .jump = .{ .opcode = 0x02, .target = 0x100 } });
    const call_word = encode(.{ .call = .{ .opcode = 0x03, .target = 0x100 } });
    try testing.expectEqual(@as(u8, 0x02), opcodeOfWord(jump_word));
    try testing.expectEqual(@as(u8, 0x03), opcodeOfWord(call_word));

    const dj = decode(jump_word);
    try testing.expect(dj == .ok and dj.ok == .jump);
    try testing.expectEqual(@as(u64, 0x100), dj.ok.jump.target);

    const dc = decode(call_word);
    try testing.expect(dc == .ok and dc.ok == .call);
    try testing.expectEqual(@as(u64, 0x100), dc.ok.call.target);
}

test "a reserved width encoding (4..15) is refused, not silently decoded as full width" {
    // §5: 4..15 are reserved. A decoder that cast them straight into a Width would
    // silently accept a full-width write, which is the bug registers.fromEncoded kills.
    for (0..16) |raw| {
        if (raw <= 3) continue;
        const word = (@as(u64, 0x10) << 56) | (@as(u64, raw) << 40);
        const d = decode(word);
        try testing.expect(d == .err);
        try testing.expectEqualStrings("width suffix", d.err.operand.?.name);

        var buf: [512]u8 = undefined;
        const text = diag.renderToBuffer(d.err, &buf);
        try testing.expect(std.mem.indexOf(u8, text, "width") != null);
        try testing.expect(!diag.hasBareHexCode(text));
    }
    // A legal width still decodes, and the same field keeps its width.
    const ok = decode(encode(.{ .add = .{ .op = 0x10, .rd = 0, .rs1 = 0, .rs2 = 0, .width = .b, .imm = null } }));
    try testing.expect(ok == .ok);
    try testing.expectEqual(Width.b, ok.ok.add.width);
}

test "an undefined opcode decodes to a diagnostic naming the opcode, never a panic" {
    // 0xAB is outside every §3 group, and the accelerator space 0x60-0x8F is owned
    // by the model modules, so 0xAB is the only kind of word this can hit.
    const word = (@as(u64, 0xAB) << 56);
    const d = decode(word);
    try testing.expect(d == .err);
    try testing.expectEqualStrings("opcode", d.err.operand.?.name);

    var buf: [512]u8 = undefined;
    const text = diag.renderToBuffer(d.err, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "171") != null);
    try testing.expect(std.mem.indexOf(u8, text, "opcode") != null);
    try testing.expect(!diag.hasBareHexCode(text));
}

test "decode is a pure function: the same word always decodes the same" {
    const w = encode(.{ .compare = .{ .op = 0x20, .rd = 2, .rs1 = 0, .rs2 = 1, .width = .full, .imm = null } });
    const first = decode(w);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try testing.expectEqual(first, decode(w));
    }
}

test "F6 REGRESSION: ALU reserved bits [39:28] are rejected with a sentence" {
    // §3.1 amendment 1.2 reserves [39:28]; nothing implemented it, so the
    // contract was normative-but-unimplemented and these words decoded silently.
    const words = [_]u64{
        (@as(u64, 0x10) << 56) | (@as(u64, 1) << 52) | (@as(u64, 2) << 48) | (@as(u64, 1) << 28),
        0x101200fff0000000,
        (@as(u64, 0x19) << 56) | (@as(u64, 1) << 28), // mov
        (@as(u64, 0x20) << 56) | (@as(u64, 1) << 28), // compare shares the layout
    };
    for (words) |word| {
        switch (decode(word)) {
            .ok => return error.TestUnexpectedResult,
            .err => |d| {
                var buf: [1024]u8 = undefined;
                const text = diag.renderToBuffer(d, &buf);
                try testing.expect(std.mem.endsWith(u8, text, "."));
                try testing.expect(!diag.hasBareHexCode(text));
                // Names the field and the actual word.
                try testing.expect(std.mem.indexOf(u8, text, "reserved") != null);
            },
        }
    }
}

test "F6 SCOPING: stream.setp keeps its legal 40-bit stride over the same bits" {
    // THE test that proves the fix was scoped per instruction class. §3.1's
    // [39:28] reservation deliberately overlaps §3.4's signed 40-bit setp
    // stride. A global check would reject every legal setp; this proves it does
    // not, because both words set bits [39:28].
    const strides = [_]u64{ 0x0000_0000FF, 0x0000_00FFFF, 0x0000_FFFF_FFFF, 0x7F_FFFF_FFFF };
    for (strides) |stride| {
        const word = (@as(u64, 0x43) << 56) | stride;
        // Bits [39:28] really are non-zero for the larger strides, so this word
        // would be rejected by an unscoped check.
        switch (decode(word)) {
            .err => return error.TestUnexpectedResult,
            .ok => |ins| try testing.expect(ins == .stream_setp),
        }
        try testing.expectEqual(word, encode(decode(word).ok));
    }
}

test "F6 SELECT: operand[35:0] reserved bits are rejected for 0x21" {
    const word = (@as(u64, 0x21) << 56) | (@as(u64, 1) << 52) | (@as(u64, 2) << 48) | 1;
    switch (decode(word)) {
        .ok => return error.TestUnexpectedResult,
        .err => |d| {
            var buf: [1024]u8 = undefined;
            const text = diag.renderToBuffer(d, &buf);
            try testing.expect(std.mem.endsWith(u8, text, "."));
            try testing.expect(!diag.hasBareHexCode(text));
        },
    }
}

test "F6 NOP/HALT: a stray operand is rejected per section 3.0" {
    // §3.0 says these operands are "unused, must be zero" and nothing checked it.
    const bad = [_]u64{
        (@as(u64, 0x00) << 56) | 1,
        (@as(u64, 0x01) << 56) | 1,
        (@as(u64, 0x00) << 56) | (@as(u64, 1) << 52), // stray rd
        (@as(u64, 0x01) << 56) | (@as(u64, 1) << 48), // stray rs1
    };
    for (bad) |word| {
        switch (decode(word)) {
            .ok => return error.TestUnexpectedResult,
            .err => |d| {
                var buf: [1024]u8 = undefined;
                const text = diag.renderToBuffer(d, &buf);
                try testing.expect(std.mem.endsWith(u8, text, "."));
                try testing.expect(!diag.hasBareHexCode(text));
            },
        }
    }
    // The canonical forms still decode.
    try testing.expect(decode(@as(u64, 0x00) << 56).ok == .nop);
    try testing.expect(decode(@as(u64, 0x01) << 56).ok == .halt);
}

test "BIT POSITION AUDIT: stream.add/copy/fill reserved[19:0] is rejected" {
    // §3.4 declares operand[19:0] reserved and — explicitly — that a non-zero
    // value is a diagnostic error, "matching the rule for every other reserved
    // field". Nothing implemented it. Found by auditing every bit-range claim in
    // the contract rather than by a failing value test.
    const words = [_]u64{
        (@as(u64, 0x40) << 56) | (@as(u64, 1) << 48) | (@as(u64, 2) << 44) | (@as(u64, 4) << 24) | 1,
        (@as(u64, 0x41) << 56) | (@as(u64, 1) << 48) | (@as(u64, 4) << 24) | 1,
        (@as(u64, 0x42) << 56) | (@as(u64, 1) << 48) | (@as(u64, 4) << 24) | 0xF_FFFF,
    };
    for (words) |word| {
        switch (decode(word)) {
            .ok => return error.TestUnexpectedResult,
            .err => |d| {
                var buf: [1024]u8 = undefined;
                const text = diag.renderToBuffer(d, &buf);
                try testing.expect(std.mem.endsWith(u8, text, "."));
                try testing.expect(!diag.hasBareHexCode(text));
                try testing.expect(std.mem.indexOf(u8, text, "reserved") != null);
            },
        }
    }
}

test "BIT POSITION AUDIT: stream.setp is NOT caught by the reserved[19:0] rule" {
    // THE anti-over-reach test. §3.4 reserves [19:0] for add/copy/fill but
    // defines [39:0] as setp's signed 40-bit stride. A shared check would reject
    // every legal setp, so this asserts the scoping directly.
    const strides = [_]u64{ 1, 0xFF, 0x0000_0000_FFFF, 0x7F_FFFF_FFFF };
    for (strides) |stride| {
        const word = (@as(u64, 0x43) << 56) | stride;
        switch (decode(word)) {
            .err => return error.TestUnexpectedResult,
            .ok => |ins| try testing.expect(ins == .stream_setp),
        }
        try testing.expectEqual(word, encode(decode(word).ok));
    }
}

test "BIT POSITION AUDIT: canonical stream.add/copy/fill still decode" {
    const words = [_]u64{
        (@as(u64, 0x40) << 56) | (@as(u64, 1) << 48) | (@as(u64, 2) << 44) | (@as(u64, 4) << 24),
        (@as(u64, 0x41) << 56) | (@as(u64, 1) << 48) | (@as(u64, 4) << 24),
        (@as(u64, 0x42) << 56) | (@as(u64, 1) << 48) | (@as(u64, 4) << 24),
    };
    for (words) |word| {
        switch (decode(word)) {
            .err => return error.TestUnexpectedResult,
            .ok => {},
        }
        try testing.expectEqual(word, encode(decode(word).ok));
    }
}

test "BIT POSITION AUDIT v1.7: field operand[27:0] reserved is rejected" {
    const words = [_]u64{
        // field.extract with [27:0] = 1, and with them all set
        (@as(u64, 0x30) << 56) | (@as(u64, 1) << 48) | (@as(u64, 12) << 40) | (@as(u64, 3) << 32) | 1,
        (@as(u64, 0x30) << 56) | (@as(u64, 1) << 48) | (@as(u64, 12) << 40) | (@as(u64, 3) << 32) | 0x0FFF_FFFF,
        (@as(u64, 0x31) << 56) | (@as(u64, 1) << 48) | (@as(u64, 12) << 40) | (@as(u64, 3) << 32) | 2,
    };
    for (words) |word| {
        switch (decode(word)) {
            .ok => return error.TestUnexpectedResult,
            .err => |d| {
                var buf: [1024]u8 = undefined;
                const text = diag.renderToBuffer(d, &buf);
                try testing.expect(std.mem.endsWith(u8, text, "."));
                try testing.expect(!diag.hasBareHexCode(text));
                try testing.expect(std.mem.indexOf(u8, text, "reserved") != null);
            },
        }
    }
}

test "BIT POSITION AUDIT v1.7: field POSITIVE CONTROL still decodes and round-trips" {
    // The over-reach trap: a check on [27:0] must not touch the legal
    // offset/width/src2 fields above it. The contract's literal example.
    const word = (@as(u64, 0x30) << 56) | (@as(u64, 1) << 48) | (@as(u64, 12) << 40) | (@as(u64, 3) << 32);
    switch (decode(word)) {
        .err => return error.TestUnexpectedResult,
        .ok => |ins| switch (ins) {
            .field_extract => |f| {
                try testing.expectEqual(@as(u8, 12), f.offset);
                try testing.expectEqual(@as(u8, 3), f.width);
            },
            else => return error.TestUnexpectedResult,
        },
    }
    try testing.expectEqual(word, encode(decode(word).ok));
}

test "BIT POSITION AUDIT v1.7: control unused rd/rs1 is rejected" {
    // jump loses its imm48 if rd/rs1 are non-zero, so those words are errors.
    const words = [_]u64{
        (@as(u64, 0x02) << 56) | (@as(u64, 1) << 52) | 16, // jump, rd = 1
        (@as(u64, 0x02) << 56) | (@as(u64, 1) << 48) | 16, // jump, rs1 = 1
        (@as(u64, 0x03) << 56) | (@as(u64, 1) << 52) | 32, // call, rd = 1
        (@as(u64, 0x04) << 56) | (@as(u64, 1) << 48), // ret, rs1 = 1
        (@as(u64, 0x04) << 56) | (@as(u64, 1) << 52), // ret, rd = 1
    };
    for (words) |word| {
        switch (decode(word)) {
            .ok => return error.TestUnexpectedResult,
            .err => |d| {
                var buf: [1024]u8 = undefined;
                const text = diag.renderToBuffer(d, &buf);
                try testing.expect(std.mem.endsWith(u8, text, "."));
                try testing.expect(!diag.hasBareHexCode(text));
            },
        }
    }
}

test "BIT POSITION AUDIT v1.7: control POSITIVE CONTROL with rd/rs1 zero still works" {
    const words = [_]u64{
        (@as(u64, 0x02) << 56) | 16, // jump 16
        (@as(u64, 0x03) << 56) | 32, // call 32
        (@as(u64, 0x04) << 56), // ret
        (@as(u64, 0x02) << 56) | 0xFFFF_FFFF_FFFF, // jump, full imm48
    };
    for (words) |word| {
        switch (decode(word)) {
            .err => return error.TestUnexpectedResult,
            .ok => {},
        }
        try testing.expectEqual(word, encode(decode(word).ok));
    }
}

// ---------------------------------------------------------------------------
// F15 (task-24): §3.5 reserves the WHOLE operand[47:0] for cap.*, and the
// reservation is enforced here because the assembler never sees a loaded blob.
// ---------------------------------------------------------------------------

test "F15: cap.* with a non-zero reserved operand is rejected, not silently discarded" {
    // The Lead's exact reproduction word, plus its cap.store/cap.check siblings
    // with rs2[47:44] set, plus a word with only the lowest reserved bit set.
    // Before this fix all four decoded fine and the bits vanished.
    const words = [_]u64{
        0x5023_4000_0000_0000, // cap.load  R2, R3 with operand[47:44] = 4 (F15)
        0x5123_4000_0000_0000, // cap.store R2, R3, same field
        0x5223_4000_0000_0000, // cap.check R2, R3, same field
        0x5023_0000_0000_0001, // cap.load  R2, R3 with only operand[0] set
        0x5023_0000_0000_FFFF, // cap.load  R2, R3 with the low 16 bits set
        0x5023_FFFF_FFFF_FFFF, // cap.load  R2, R3 with the whole field set
    };
    for (words) |word| {
        switch (decode(word)) {
            .ok => return error.TestUnexpectedResult,
            .err => |d| {
                var buf: [1024]u8 = undefined;
                const text = diag.renderToBuffer(d, &buf);
                try testing.expect(std.mem.endsWith(u8, text, "."));
                try testing.expect(!diag.hasBareHexCode(text));
                // Names the field...
                try testing.expect(std.mem.indexOf(u8, text, "capability reserved field") != null);
                // ...cites the section...
                try testing.expect(std.mem.indexOf(u8, text, "§3.5") != null);
                // ...and says the bits were refused, not dropped.
                try testing.expect(std.mem.indexOf(u8, text, "rejected rather than ignored") != null);
            },
        }
    }
}

test "F15 POSITIVE CONTROL: legal cap.* words still decode and round-trip" {
    // The F14 failure mode is a check that also rejects legal words, so the
    // legal forms are asserted explicitly: zero operand, and the exact clean
    // `cap.check R1, R2` word named in the task.
    const cases = [_]struct { word: u64, variant: enum { load, store, check } }{
        .{ .word = 0x5212_0000_0000_0000, .variant = .check }, // cap.check R1, R2
        .{ .word = 0x5000_0000_0000_0000, .variant = .load }, // cap.load R0, R0
        .{ .word = 0x5100_0000_0000_0000, .variant = .store }, // cap.store R0, R0
        .{ .word = 0x52FF_0000_0000_0000, .variant = .check }, // cap.check FLAGS, FLAGS (max indices)
    };
    for (cases) |c| {
        const d = decode(c.word);
        try testing.expect(d == .ok);
        switch (d.ok) {
            .cap_load => |ins| {
                try testing.expectEqual(@as(u8, 0x50), ins.op);
                try testing.expectEqual(@as(u4, 0), ins.rd);
                try testing.expect(c.variant == .load);
            },
            .cap_store => |ins| {
                try testing.expectEqual(@as(u8, 0x51), ins.op);
                try testing.expect(c.variant == .store);
            },
            .cap_check => |ins| {
                try testing.expectEqual(@as(u8, 0x52), ins.op);
                try testing.expect(c.variant == .check);
            },
            else => return error.TestUnexpectedResult,
        }
        // A legal word must still re-encode to itself: the check must not have
        // narrowed the encoding it accepts.
        try testing.expectEqual(c.word, encode(d.ok));
    }
}

test "F15: the clean cap.check word named in the task decodes to R1, R2 exactly" {
    const d = decode(0x5212_0000_0000_0000);
    try testing.expect(d == .ok);
    try testing.expectEqual(@as(u8, 0x52), d.ok.cap_check.op);
    try testing.expectEqual(@as(u4, 1), d.ok.cap_check.rd);
    try testing.expectEqual(@as(u4, 2), d.ok.cap_check.rs1);
}
