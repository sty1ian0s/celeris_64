//! Celeris-64 disassembler: 64-bit instruction words -> assembly text.
//!
//! Normative reference: docs/isa-encoding.md §2 (word layout), §3 (opcode map),
//! §4 (register indices), §5 (width suffixes).
//!
//! The acceptance criterion (tests/contract.md P2.2) is a *byte-exact* round
//! trip: asm -> decode -> asm must reproduce the original instruction word for
//! every opcode in the §3 map. That property is what this module is built
//! around, so the text it emits is chosen to re-assemble to the same word, not
//! merely to look tidy. In particular:
//!
//!   * every numeric field is printed in the form the assembler parses back,
//!   * the width suffix is printed whenever the width field is non-zero,
//!   * accelerator mnemonics print their sub-opcode name, which the assembler
//!     maps back to the same opcode byte.
//!
//! Decoding itself is NOT implemented here. Per the task split, this module
//! consumes `src/decoder.zig`, which hw-primitives owns. Duplicating the bit
//! layout in two places is exactly how an assembler and a disassembler drift
//! apart.

const std = @import("std");
const diag = @import("diagnostics.zig");
const decoding = @import("decoder.zig");
// The §3.6 accelerator table is normative and lives in one place. Importing it
// here (rather than repeating the opcode/name mapping) is what keeps the
// assembler and disassembler from drifting apart.
const assembler_accel = @import("assembler.zig");

pub const Diagnostic = diag.Diagnostic;
pub const Instruction = decoding.Instruction;

/// Re-exported so a test root can pin the assembler's encoder against this one.
/// The two are independent implementations of the same §3 layouts; the
/// round-trip fuzzer only exercises the assembler's, so they need an explicit
/// agreement check.
pub const encode = decoding.encode;

/// Renders `word` as one line of Celeris-64 assembly.
///
/// On an undecodable word the diagnostic from the decoder is returned unchanged,
/// so the caller reports the same sentence the VM would report.
pub fn disassemble(word: u64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (decoding.decode(word)) {
        .err => |d| try d.render(w),
        .ok => |ins| try render(ins, w),
    }
}

/// Decodes a word for callers that want to inspect it before rendering, such as
/// the trace mode. Returns null when the word is not a defined instruction.
pub fn decodeWord(word: u64) ?Instruction {
    return switch (decoding.decode(word)) {
        .ok => |ins| ins,
        .err => null,
    };
}

/// Renders an already-decoded instruction. Split out so the trace mode and the
/// CLI can reuse it without decoding twice.
pub fn render(ins: Instruction, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (ins) {
        .nop => try w.writeAll("nop"),
        .halt => try w.writeAll("halt"),
        .ret => try w.writeAll("ret"),
        .branch => |b| try branch(b, w),

        .load => |m| try mem(m, w, true),
        .store => |m| try mem(m, w, false),
        .jump => |i| try w.print("jump {d}", .{i.target}),
        .call => |i| try w.print("call {d}", .{i.target}),

        .add => |i| try alu("add", i, w),
        .sub => |i| try alu("sub", i, w),
        .mul => |i| try alu("mul", i, w),
        .div => |i| try alu("div", i, w),
        .and_ => |i| try alu("and", i, w),
        .or_ => |i| try alu("or", i, w),
        .xor_ => |i| try alu("xor", i, w),
        .shl => |i| try alu("shl", i, w),
        .shr => |i| try alu("shr", i, w),
        .mov => |i| try mov(i, w),

        .compare => |i| try compare(i, w),
        .select => |i| try select(i, w),

        .field_extract => |i| try field("field.extract", i, w, false),
        .field_insert => |i| try field("field.insert", i, w, true),

        .stream_add => |i| try stream("stream.add", i, w),
        .stream_copy => |i| try stream("stream.copy", i, w),
        .stream_fill => |i| try stream("stream.fill", i, w),
        .stream_setp => |i| try w.print("stream.setp {s}, {d}", .{ regName(i.rd), i.stride }),

        .cap_load => |i| try cap("cap.load", i, w),
        .cap_store => |i| try cap("cap.store", i, w),
        .cap_check => |i| try cap("cap.check", i, w),

        .thread_spawn => |i| try w.print("thread.spawn {f}, {s}", .{ slots(i.slots), regName(i.rs1) }),
        .thread_join => |i| try w.print("thread.join {f}", .{slots(i.slots)}),
        .thread_yield => try w.writeAll("thread.yield"),

        // §3.6: the operand field is defined by the model module, not by the
        // encoding contract, and this build does not assemble these mnemonics.
        // The word is therefore rendered as a COMMENTED byte dump: it is honest
        // about what the bits are, and it cannot be mistaken for assembler input
        // that would re-encode to a different instruction. The round-trip test
        // excludes this range for exactly this reason.
        .accelerator => |i| try accelerator(i, w),
    }
}

/// §3.6 (amendment 1.1). An assigned opcode renders as its mnemonic with
/// positional registers and, when the word carries one, `count=`. A RESERVED
/// opcode in the range renders as `.raw` carrying the exact bytes, so it
/// round-trips without being reinterpreted as a neighbouring operation.
fn accelerator(i: anytype, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const spec = assembler_accel.acceleratorByOpcode(i.opcode);
    if (spec == null) {
        // Reserved: keep every bit and reinterpret nothing. `.raw` takes the
        // opcode byte, the full 48-bit operand, and (F20) the `rd`/`rs1` indices
        // that live OUTSIDE the operand field in bits [55:48]. Emitting only the
        // operand lost those two fields, so a reserved word re-assembled to a
        // different word — silently, at exit 0.
        return rawFallback(i, w);
    }
    const a = spec.?;

    // §3.6 says a register field that the operation does not use is 0. A word
    // carrying a non-zero value in an unused slot is therefore NOT canonical: it
    // cannot be expressed by the mnemonic, so rendering the mnemonic would drop
    // bits and silently change the word. Fall back to `.raw`, which preserves it.
    const unused_nonzero = (a.sources < 3 and i.rs3 != 0) or
        (a.sources < 2 and i.rs2 != 0) or
        (!a.takes_count and i.count != 0);
    if (unused_nonzero) {
        return rawFallback(i, w);
    }

    try w.print("{s} {s}", .{ a.name, regName(i.rd) });
    if (a.sources >= 1) try w.print(", {s}", .{regName(i.rs1)});
    if (a.sources >= 2) try w.print(", {s}", .{regName(i.rs2)});
    if (a.sources >= 3) try w.print(", {s}", .{regName(i.rs3)});
    // §3.6: count 0 means "derive from the destination register", which is the
    // form emitted when the source wrote no count. Emitting it would be
    // redundant, and omitting it keeps exactly one canonical text per word.
    if (a.takes_count and i.count != 0) try w.print(", count={d}", .{i.count});
}

fn alu(mnemonic: []const u8, i: anytype, w: *std.Io.Writer) std.Io.Writer.Error!void {
    // §3.1: imm28 == 0 means the source is the rs2 register; a non-zero imm28
    // means immediate form, and there `rs2` is IGNORED but still occupies
    // bits [47:44]. F21: printing the immediate form dropped a non-zero `rs2`
    // on the floor, so `0x1012300000000005` (rs2=3) and `0x1012000000000005`
    // (rs2=0) both rendered as "add R1, R2, 5" and the first was rewritten into
    // the second. A word the mnemonic cannot express falls back to `.raw`, which
    // preserves every bit — the same rule §3.6 already used.
    if (i.imm) |imm| {
        if (i.rs2 != 0) return rawFallback(i, w);
        try w.print("{s} {s}{s}, {s}, {d}", .{
            mnemonic, regName(i.rd), widthSuffix(i.width), regName(i.rs1), imm,
        });
    } else {
        try w.print("{s} {s}{s}, {s}, {s}", .{
            mnemonic, regName(i.rd), widthSuffix(i.width), regName(i.rs1), regName(i.rs2),
        });
    }
}

/// F20/F21/F22/F23/F25/F26/F29. A word whose register/operand bits the mnemonic
/// cannot name is emitted as `.raw`, carrying the opcode byte, the 48-bit operand
/// and the two register indices. Rendering the mnemonic instead would drop those
/// bits and silently rewrite the word — the defect class this whole family shares.
fn rawFallback(i: anytype, w: *std.Io.Writer) std.Io.Writer.Error!void {
    // Most payloads name the opcode byte `op`; `Accelerator` calls it `opcode`.
    const T = @TypeOf(i);
    const op: u8 = if (@hasField(T, "opcode")) i.opcode else i.op;
    try w.print(".raw {d}, {d}, {d}, {d}", .{ op, i.operand, i.rd, i.rs1 });
}

/// §3.0.1: `branch rs1, [MATCH], offset`. The offset is printed as the signed
/// byte displacement the word carries, not as a resolved absolute address,
/// because the word does not store an absolute address and printing one would
/// make the text re-assemble to a different word whenever the program moved.
fn branch(b: anytype, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const name = statusName(b.match_val) orelse {
        // A match value outside the enum is not expressible text, so the word goes
        // out verbatim rather than being rendered as a branch that cannot fire.
        try w.print(".raw {d}, {d}, 0, {d}", .{ b.op, b.operand, b.rs1 });
        return;
    };
    try w.print("branch {s}, [{s}], {d}", .{ regName(b.rs1), name, b.offset });
}

/// §3.1.1: `load rd, [rs1+off]` and `store rs2, [rs1+off], src`.
fn mem(m: anytype, w: *std.Io.Writer, is_load: bool) std.Io.Writer.Error!void {
    if (is_load) {
        // `load` has no source register; a word carrying one is not expressible.
        if (m.rs2 != 0) return rawFallback(m, w);
        try w.print("load {s}{s}, [{s}", .{ regName(m.rd), widthSuffix(m.width), regName(m.rs1) });
        try printOffset(w, m.offset);
        try w.writeAll("]");
    } else {
        // `store` writes no register, so a non-zero rd is not expressible.
        if (m.rd != 0) return rawFallback(m, w);
        // `store src, [base+off]` — the source appears ONCE. The width suffix
        // belongs to the source register, which is the value being narrowed.
        try w.print("store {s}{s}, [{s}", .{ regName(m.rs2), widthSuffix(m.width), regName(m.rs1) });
        try printOffset(w, m.offset);
        try w.writeAll("]");
    }
}

/// Prints a displacement with an explicit leading sign, so `[R4+16]` cannot be
/// misread as a register named `R416`. Written as a helper rather than a custom
/// `format` hook because the two sign cases need different format strings.
fn printOffset(w: *std.Io.Writer, off: i64) std.Io.Writer.Error!void {
    if (off < 0) {
        try w.print("{d}", .{off});
    } else {
        try w.print("+{d}", .{off});
    }
}

/// The five status enum names from §3.2.1. Returns null for a value the enum does
/// not define, which the decoder rejects but a hand-built word could still carry.
fn statusName(v: u4) ?[]const u8 {
    return switch (v) {
        0 => "EQUAL",
        1 => "LESS",
        2 => "GREATER",
        3 => "UNSIGNED_LESS",
        4 => "UNSIGNED_GREATER",
        else => null,
    };
}

fn mov(i: anytype, w: *std.Io.Writer) std.Io.Writer.Error!void {
    // §3.1: `mov rd, src2`; rs1 is ignored, so it is not printed. F22: ignored
    // is not the same as absent — a non-zero rs1 still occupies bits [51:48] and
    // is destroyed by re-assembly, so such a word must go to `.raw`.
    if (i.rs1 != 0) return rawFallback(i, w);
    if (i.imm) |imm| {
        try w.print("mov {s}{s}, {d}", .{ regName(i.rd), widthSuffix(i.width), imm });
    } else {
        try w.print("mov {s}{s}, {s}", .{ regName(i.rd), widthSuffix(i.width), regName(i.rs2) });
    }
}

fn compare(i: anytype, w: *std.Io.Writer) std.Io.Writer.Error!void {
    // The spec's literal spelling, celeris_64-architecture-specification.md §3.2:
    //     compare R0, R1 -> R2
    // F29: §3.2.1 shares §3.1's ALU operand layout ([47:44] rs2, [43:40] width,
    // [39:28] reserved, [27:0] imm28) but says nothing about a width suffix, and
    // this renderer emitted none — so a word with a non-zero width nibble was
    // silently rewritten with width 0 (`0x201D830000000000` -> `...80...`).
    // The suffix belongs to the operand register, exactly as it does for the ALU
    // opcodes, so it is emitted here too.
    const suffix = widthSuffix(i.width);
    if (i.imm) |imm| {
        if (i.rs2 != 0) return rawFallback(i, w);
        try w.print("compare {s}{s}, {d} -> {s}", .{ regName(i.rs1), suffix, imm, regName(i.rd) });
    } else {
        try w.print("compare {s}{s}, {s}{s} -> {s}", .{
            regName(i.rs1), suffix, regName(i.rs2), suffix, regName(i.rd),
        });
    }
}

fn select(i: anytype, w: *std.Io.Writer) std.Io.Writer.Error!void {
    // The spec's literal spelling, §3.2.2:
    //     select R3, R2, [EQUAL], R4, R5
    try w.print("select {s}, {s}, [{s}], {s}, {s}", .{
        regName(i.rd), regName(i.rs1), i.match_val.name(), regName(i.true_reg), regName(i.false_reg),
    });
}

fn field(mnemonic: []const u8, i: anytype, w: *std.Io.Writer, with_src: bool) std.Io.Writer.Error!void {
    // The spec's literal spelling, §3.3:
    //     field.extract R0, R1, offset=12, width=3
    // F25: §3.3 defines src2[31:28] for `field.insert` only. `field.extract`
    // leaves it unused and the renderer dropped it, so a word carrying a
    // non-zero src2 was silently rewritten. Unused is not absent.
    if (!with_src and i.src2 != 0) return rawFallback(i, w);
    try w.print("{s} {s}, {s}, offset={d}, width={d}", .{
        mnemonic, regName(i.rd), regName(i.rs1), i.offset, i.width,
    });
    if (with_src) try w.print(", {s}", .{regName(i.src2)});
}

fn stream(mnemonic: []const u8, i: anytype, w: *std.Io.Writer) std.Io.Writer.Error!void {
    // F26: `stream.setp` (0x43) uses [39:0] as its stride and defines no rs2,
    // so a word carrying one there cannot be expressed. The other three all have
    // an offset register per §3.4 and the renderer already prints it.
    if (i.op == 0x43 and i.rs2 != 0) return rawFallback(i, w);
    // The spec's literal spelling, §3.4:
    //     stream.add R0, [R1]+CHUNK_SIZE, R2
    // `CHUNK_SIZE` is the spec's own name for one hardware chunk; we print the
    // literal element count instead so the text re-assembles to the exact word
    // regardless of how many elements the chunk holds.
    // §3.4/v1.10: the §5 width suffix attaches to the ELEMENT REGISTER (`rd`),
    // which is the operand the width describes — not to the bracketed chunk.
    // Width 0 emits no suffix, because "no suffix" is the canonical form for
    // full 64-bit elements and is what every pre-fix word encodes.
    try w.print("{s} {s}{s}, [{s}]+{d}, {s}", .{
        mnemonic,
        regName(i.rd),
        widthSuffix(i.width),
        regName(i.rs1),
        i.chunk,
        regName(i.rs2),
    });
}

fn cap(mnemonic: []const u8, i: anytype, w: *std.Io.Writer) std.Io.Writer.Error!void {
    // §3.5 reserves the whole operand[47:0]; a word reaching the renderer with a
    // non-zero operand is not expressible as two registers.
    if (i.operand != 0) return rawFallback(i, w);
    try w.print("{s} {s}, {s}", .{ mnemonic, regName(i.rd), regName(i.rs1) });
}

/// A step-by-step trace of an instruction, showing the mutations it causes.
/// tests/contract.md P2.2 asks for register mutations and stream pointer
/// movement in plain text.
pub fn traceLine(
    ins: Instruction,
    pc: u64,
    before: []const u64,
    after: []const u64,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try w.print("  {d:0>6}  ", .{pc});
    try render(ins, w);

    // Report every register whose value changed (stream pointer movement shows
    // up here as an ordinary change to the pointer register).
    var changed_any = false;
    for (before, after, 0..) |b, a, index| {
        if (b == a) continue;
        if (!changed_any) {
            try w.writeAll("   # ");
            changed_any = true;
        } else {
            try w.writeAll(", ");
        }
        try w.print("{s} <- 0x{x:0>16}", .{ regName(@intCast(index)), a });
    }
    if (!changed_any) try w.writeAll("   # no register changed");
}

/// §5 width suffix. The decoder hands us its Width enum, which is the register
/// file's, so the spelling is taken from that one place.
pub fn widthSuffix(width: decoding.Width) []const u8 {
    return width.suffix();
}

/// §4: 0-11 are R0-R11, then SP, LR, PC and FLAGS.
pub fn regName(index: u4) []const u8 {
    const names = [_][]const u8{
        "R0",  "R1",  "R2",  "R3",  "R4",  "R5", "R6", "R7",
        "R8",  "R9",  "R10", "R11", "SP",  "LR", "PC", "FLAGS",
    };
    return names[index];
}

fn slots(mask: u8) Slots {
    return .{ .mask = mask };
}

const Slots = struct {
    mask: u8,

    pub fn format(self: Slots, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var first = true;
        for (0..8) |slot| {
            // Widen before shifting: a u5 cannot represent bit 7.
            const bit: u8 = @as(u8, 1) << @intCast(slot);
            if (self.mask & bit == 0) continue;
            // §3.7 (amendment 1.1): slots are enumerated individually and
            // comma-separated, so exactly one canonical text exists per word.
            if (!first) try w.writeAll(", ");
            try w.print("T{d}", .{slot});
            first = false;
        }
        // §3.7: the field is a bitmask, and a zero mask names no slot. There is
        // no `T-none` slot in the architecture, so inventing that name would put
        // a word in the user's mouth; "no slots" says what the bits actually are.
        if (first) try w.writeAll("no slots");
    }
};

// -- tests --------------------------------------------------------------------
//
// The round-trip test below is the acceptance criterion: for every opcode in the
// §3 map, assembling the disassembled text must reproduce the exact original
// word. It is deliberately driven by a table of *words*, not by source text, so
// a passing result cannot come from echoing the input back.

const testing = std.testing;
const Diag = diag.Diagnostic;

/// Re-encodes disassembler text. This intentionally imports the assembler, the
/// independent implementation, so the test proves the two agree.
fn reencode(text: []const u8) !u64 {
    const assembler = @import("assembler.zig");
    var a = assembler.Assembler.init(testing.allocator);
    defer a.deinit();
    var d: Diagnostic = .{};
    const prog = a.assembleSource("roundtrip.asm", text, &d) catch {
        std.debug.print("round-trip failed to re-assemble \"{s}\": {}\n", .{ text, d });
        return error.TestUnexpectedResult;
    };
    if (prog.words.len != 1) return error.TestUnexpectedResult;
    return prog.words[0];
}

test "disassembler renders the four spec examples back to the same words" {
    const assembler = @import("assembler.zig");
    const samples = [_][]const u8{
        "stream.add R0, [R1]+64, R2",
        "compare R0, R1 -> R2",
        "select R3, R2, [EQUAL], R4, R5",
        "field.extract R0, R1, offset=12, width=3",
    };
    for (samples) |src| {
        var a = assembler.Assembler.init(testing.allocator);
        defer a.deinit();
        var d: Diagnostic = .{};
        const prog = try a.assembleSource("s.asm", src, &d);
        const original = prog.words[0];

        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try disassemble(original, &w);
        const text = w.buffered();

        const again = try reencode(text);
        try testing.expectEqual(original, again);
    }
}

test "width suffixes survive the round trip" {
    const assembler = @import("assembler.zig");
    const samples = [_][]const u8{
        "add R0.l, R1, R2",
        "add R0.w, R1, R2",
        "add R0.b, R1, R2",
        "add R0, R1, R2",
    };
    for (samples) |src| {
        var a = assembler.Assembler.init(testing.allocator);
        defer a.deinit();
        var d: Diagnostic = .{};
        const prog = try a.assembleSource("s.asm", src, &d);
        const original = prog.words[0];

        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try disassemble(original, &w);

        const again = try reencode(w.buffered());
        try testing.expectEqual(original, again);
    }
}

test "an undecodable word renders a sentence, not a bare hex code" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    // 0xFF is not a defined opcode in the §3 map.
    try disassemble(0xFF00_0000_0000_0000, &w);
    const text = w.buffered();
    try testing.expect(text.len > 0);
    try testing.expect(std.mem.endsWith(u8, text, "."));
    try testing.expect(!diag.hasBareHexCode(text));
}

test "status enum names render for every defined value" {
    try testing.expectEqualStrings("EQUAL", decoding.Status.EQUAL.name());
    try testing.expectEqualStrings("LESS", decoding.Status.LESS.name());
    try testing.expectEqualStrings("GREATER", decoding.Status.GREATER.name());
    try testing.expectEqualStrings("UNSIGNED_LESS", decoding.Status.UNSIGNED_LESS.name());
    try testing.expectEqualStrings("UNSIGNED_GREATER", decoding.Status.UNSIGNED_GREATER.name());
}

test "register names cover the full index encoding" {
    try testing.expectEqualStrings("R0", regName(0));
    try testing.expectEqualStrings("R11", regName(11));
    try testing.expectEqualStrings("SP", regName(12));
    try testing.expectEqualStrings("LR", regName(13));
    try testing.expectEqualStrings("PC", regName(14));
    try testing.expectEqualStrings("FLAGS", regName(15));
}

test "thread slot masks render as readable slot names" {
    // §3.7 (amendment 1.1): the canonical form enumerates slots separated by
    // commas. The `|` form was the pre-1.1 spelling and is still ACCEPTED on
    // input, but the disassembler emits only this one shape.
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{slots(0b0000_0101)});
    try testing.expectEqualStrings("T0, T2", w.buffered());
}

test "DELIBERATE CONTRACT UPDATE 1.1: assigned accelerators render as mnemonics" {
    // This test previously asserted that 0x60 rendered as a "# accelerator ..."
    // comment, which was a v1.0 workaround: §3.6 deferred the operand layout, so
    // no mnemonic existed and commented bytes were the honest alternative to
    // emitting text the assembler would reject.
    //
    // Amendment 1.1 assigns the layout and 13 mnemonics, so the workaround is
    // obsolete. An ASSIGNED opcode now renders as a real, reassemblable mnemonic.
    // A RESERVED opcode still must not invent syntax, and is covered separately.
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try disassemble(0x60_00_00_00_00_00_00_00, &w);
    try testing.expectEqualStrings("matrix.det R0, R0", w.buffered());
}

test "a zero thread slot mask does not invent a slot name" {
    // §3.7 is a bitmask; mask 0 names no slot. "T-none" is not a register the
    // architecture defines, so printing it puts a word in the user's mouth.
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{slots(0)});
    try testing.expectEqualStrings("no slots", w.buffered());
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "T-none") == null);
}

// -- §3.6 / §3.7 round-trip acceptance (contract v1.1) -------------------------

test "all 13 §3.6 accelerators round-trip verbatim through dis then asm" {
    var buf: [256]u8 = undefined;
    for (assembler_accel.accelerators) |a| {
        // Build a CANONICAL word: §3.6 defines an unused register field as 0, so
        // only the slots this operation names may be non-zero.
        var word: u64 = (@as(u64, a.opcode) << 56) | (@as(u64, 1) << 52);
        if (a.sources >= 1) word |= @as(u64, 2) << 48;
        if (a.sources >= 2) word |= @as(u64, 3) << 44;
        if (a.sources >= 3) word |= @as(u64, 4) << 40;
        if (a.takes_count) word |= 16;

        var w = std.Io.Writer.fixed(&buf);
        try disassemble(word, &w);
        const text = w.buffered();
        try testing.expect(std.mem.startsWith(u8, text, a.name));

        const again = try reencode(text);
        try testing.expectEqual(word, again);
    }
}

test "a RESERVED accelerator opcode round-trips as raw bytes, not as a neighbour" {
    var buf: [256]u8 = undefined;
    // 0x6F is unassigned; 0x6E and 0x70 are not. It must not become either.
    const word: u64 = (@as(u64, 0x6F) << 56) | (@as(u64, 0x1234));
    var w = std.Io.Writer.fixed(&buf);
    try disassemble(word, &w);
    const text = w.buffered();

    try testing.expect(std.mem.startsWith(u8, text, ".raw"));
    const again = try reencode(text);
    try testing.expectEqual(word, again);
    // The opcode byte survived exactly.
    try testing.expectEqual(@as(u8, 0x6F), @as(u8, @truncate(again >> 56)));
}

test "thread.spawn with no slot list is mask 0 and prints exactly 'no slots'" {
    const assembler = @import("assembler.zig");
    var a = assembler.Assembler.init(testing.allocator);
    defer a.deinit();
    var d: Diag = .{};
    const prog = try a.assembleSource("t.asm", "thread.spawn no slots, R1\n", &d);
    const word = prog.words[0];

    // §3.7: operand[4:0] == 0, a legal encoding naming no slot.
    try testing.expectEqual(@as(u64, 0), word & 0x1F);

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try disassemble(word, &w);
    try testing.expectEqualStrings("thread.spawn no slots, R1", w.buffered());

    const again = try reencode(w.buffered());
    try testing.expectEqual(word, again);
}

test "slots enumerate individually so there is one canonical text per word" {
    var buf: [128]u8 = undefined;
    // Mask 0b101 must print "T0, T2", never a range, so re-assembly is exact.
    const word: u64 = (@as(u64, 0x90) << 56) | (@as(u64, 1) << 48) | 0b101;
    var w = std.Io.Writer.fixed(&buf);
    try disassemble(word, &w);
    try testing.expectEqualStrings("thread.spawn T0, T2, R1", w.buffered());
    try testing.expectEqual(word, try reencode(w.buffered()));
}

test "count=N survives the round trip and omitting it encodes 0" {
    const assembler = @import("assembler.zig");

    var with = assembler.Assembler.init(testing.allocator);
    defer with.deinit();
    var d1: Diag = .{};
    const p1 = try with.assembleSource("c.asm", "fft.forward R0, R1, count=64\n", &d1);
    try testing.expectEqual(@as(u64, 64), p1.words[0] & 0xFFFF_FFFF);

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try disassemble(p1.words[0], &w);
    try testing.expectEqualStrings("fft.forward R0, R1, count=64", w.buffered());
    try testing.expectEqual(p1.words[0], try reencode(w.buffered()));

    // Omitted count encodes as 0 and prints nothing extra.
    var without = assembler.Assembler.init(testing.allocator);
    defer without.deinit();
    var d2: Diag = .{};
    const p2 = try without.assembleSource("c.asm", "fft.forward R0, R1\n", &d2);
    try testing.expectEqual(@as(u64, 0), p2.words[0] & 0xFFFF_FFFF);

    var buf2: [128]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    try disassemble(p2.words[0], &w2);
    try testing.expectEqualStrings("fft.forward R0, R1", w2.buffered());
    try testing.expectEqual(p2.words[0], try reencode(w2.buffered()));
}

test "non-zero reserved bits are reported as a sentence, not a bare hex token" {
    // §3.6: reserved[39:32] must be zero.
    const word: u64 = (@as(u64, 0x60) << 56) | (@as(u64, 0xFF) << 32) | 7;
    switch (decoding.decode(word)) {
        .ok => return error.TestUnexpectedResult,
        .err => |d| {
            var buf: [512]u8 = undefined;
            const text = diag.renderToBuffer(d, &buf);
            try testing.expect(text.len > 0);
            try testing.expect(std.mem.endsWith(u8, text, "."));
            try testing.expect(!diag.hasBareHexCode(text));
            // It names the field that was wrong.
            try testing.expect(std.mem.indexOf(u8, text, "reserved") != null);
        },
    }
}
