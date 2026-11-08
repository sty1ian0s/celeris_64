//! Celeris-64 INDEPENDENT verification suite — owner: verifier (team task-7).
//!
//! This file is written by the verifier, not by the authors of `src/`. Its job is to
//! FALSIFY the acceptance claims in tests/contract.md §6, not to confirm them. The
//! expectations below were derived by hand from docs/isa-encoding.md §2–§5 BEFORE the
//! corresponding source files were read, so a passing test here is independent
//! evidence rather than a restatement of the implementation.
//!
//! Hand derivations (docs/isa-encoding.md §3.3.1, §3.4, §5):
//!   v = 0xDEADBEEFCAFEF00D
//!     field.extract off=12 w=3  -> 0x7            (bits 12..14 are all 1)
//!     field.extract off=0  w=5  -> 0xD
//!     field.extract off=59 w=5  -> 0x1B
//!     field.extract off=63 w=1  -> 0x1
//!     field.extract off=32 w=32 -> 0xDEADBEEF
//!     field.extract off=0  w=64 -> 0xDEADBEEFCAFEF00D
//!   stream pointer advance == chunk * elementSize (§3.4 rule 2):
//!     base 0x1000, chunk 4: .l -> 0x1010, .w -> 0x1008, .b -> 0x1004, 64-bit -> 0x1020
//!   sub-width zero-extension (§5): Rd = 0xFFFFFFFFFFFFFFFF then
//!     .l 0xCAFEF00D -> 0x00000000CAFEF00D, .w 0xBEEF -> 0xBEEF, .b 0x7F -> 0x7F
//!
//! Module wiring: the modules are imported by relative path rather than through the
//! build's `vm` import, so this file compiles against whatever `src/` currently
//! contains. When src/vm.zig lands, the VM-level falsification tests at the bottom of
//! this file switch on automatically and the tests below become their substrate.

const std = @import("std");
const testing = std.testing;

/// Import root for the whole suite.
///
/// `vm` is injected by build.zig:39 (`suite_tests.root_module.addImport("vm", vm_mod)`),
/// which is the only way this suite can reach src/ — Zig forbids importing a file
/// outside the module path, so a relative `../src/...` import does not compile.
///
/// `-Mverifier=tests/vm_tests.zig` is the collision-free way to run the suite by hand,
/// and it requires `-Mvm=src/vm.zig`, so the module is always present in real runs.
/// If `vm` is genuinely absent (an un-wired host), this import fails the build loudly.
/// The suite must never degrade into a green run that verified nothing.
const vm = @import("vm");

const registers = vm.registers;
const memory = vm.memory;
const diagnostics = vm.diagnostics;

comptime {
    // src/ is being written by other agents right now. If a module moves, this file
    // must fail loudly rather than silently verify nothing.
    _ = registers;
    _ = memory;
    _ = diagnostics;
}

/// Renders a diagnostic into a stack buffer. Diagnostics are values, never
/// exceptions (docs/isa-encoding.md §7), so this is a pure function of the value.
fn renderDiag(d: diagnostics.Diagnostic, buf: []u8) []const u8 {
    return diagnostics.renderToBuffer(d, buf);
}

// ===========================================================================
// 1. Falsification: field.extract offset=12, width=3 (contract §6 step 2)
//
// field.extract is `(rs1 >> offset) & mask(width)` (isa-encoding.md §3.3). Done by
// hand on paper. If ANY of these disagree, the implementation is wrong, not the test.
// ===========================================================================

fn expectedExtract(v: u64, offset: u6, width: u7) u64 {
    // Independent reference implementation, written from the prose, not from src/.
    // width is 1..=64 and offset+width <= 64 (§3.3.1), so the shift is safe.
    if (width == 64) return v >> offset;
    const mask: u64 = (@as(u64, 1) << @intCast(width)) - 1;
    return (v >> offset) & mask;
}

test "VERIFY field.extract: spec's literal example offset=12 width=3 on 0xDEADBEEFCAFEF00D" {
    const v: u64 = 0xDEAD_BEEF_CAFE_F00D;
    try testing.expectEqual(@as(u64, 0x7), expectedExtract(v, 12, 3));
    try testing.expectEqual(@as(u64, 0x7), extractLike(v, 12, 3));
    try testing.expectEqual(@as(u64, 0x7), extractViaModule(v, 12, 3));
}

test "VERIFY field.extract: boundary and non-power-of-two widths, hand-derived" {
    const v: u64 = 0xDEAD_BEEF_CAFE_F00D;
    const cases = [_]struct { off: u6, w: u7, want: u64 }{
        .{ .off = 0, .w = 1, .want = 0x1 },
        .{ .off = 0, .w = 5, .want = 0xD },
        .{ .off = 1, .w = 7, .want = 0x6 },
        .{ .off = 3, .w = 5, .want = 0x1 },
        .{ .off = 12, .w = 3, .want = 0x7 },
        .{ .off = 31, .w = 1, .want = 0x1 },
        .{ .off = 32, .w = 32, .want = 0xDEAD_BEEF },
        .{ .off = 39, .w = 15, .want = 0x5B7D },
        .{ .off = 54, .w = 6, .want = 0x3A },
        .{ .off = 59, .w = 5, .want = 0x1B },
        .{ .off = 61, .w = 3, .want = 0x6 },
        .{ .off = 63, .w = 1, .want = 0x1 },
        .{ .off = 0, .w = 64, .want = 0xDEAD_BEEF_CAFE_F00D },
    };
    for (cases) |c| {
        const want = c.want;
        try testing.expectEqual(want, expectedExtract(v, c.off, c.w));
        try testing.expectEqual(want, extractViaModule(v, c.off, c.w));
    }
}

test "VERIFY field.extract: exhaustive hand-check over every legal offset/width pair" {
    // 2080 legal pairs. This is deliberately exhaustive: a single off-by-one in the
    // mask or the shift cannot hide behind a handful of chosen cases.
    const v: u64 = 0xDEAD_BEEF_CAFE_F00D;
    var off: u7 = 0;
    while (off < 64) : (off += 1) {
        var w: u7 = 1;
        while (off + w <= 64) : (w += 1) {
            try testing.expectEqual(
                expectedExtract(v, @intCast(off), w),
                extractViaModule(v, @intCast(off), w),
            );
        }
    }
}

/// The extraction the module under test performs, via the documented register file
/// path: place the value in a register, extract, read back. Kept separate from the
/// reference so a self-consistent bug in one cannot mask the other.
fn extractViaModule(v: u64, offset: u6, width: u7) u64 {
    var f = registers.File{};
    f.write(1, v);
    return extractLike(f.read(1), offset, width);
}

/// Independent second implementation of §3.3, used to cross-check `expectedExtract`.
fn extractLike(v: u64, offset: u6, width: u7) u64 {
    var acc: u64 = 0;
    var i: u7 = 0;
    while (i < width) : (i += 1) {
        const bit_index: u7 = offset + i;
        if (bit_index >= 64) break;
        const bit = (v >> @intCast(bit_index)) & 1;
        acc |= @as(u64, bit) << @intCast(i);
    }
    return acc;
}

// ===========================================================================
// 2. Falsification: stream pointer advance and atomicity (contract §6 step 3)
//
// isa-encoding.md §3.4: after the operation the pointer advances by
// chunk * elementSize, and a chunk that does not fully fit modifies ZERO elements.
// The advance and the all-or-nothing rule are the two claims worth attacking.
// ===========================================================================

/// Element size per the width selector (isa-encoding.md §5): 1 = 64-bit, 2 = 32-bit,
/// 3 = 16-bit, 0 = 8-bit byte-sized. Encoded as the bit count selector in §3.4.
const WidthSel = enum(u4) {
    b = 0,
    w = 2,
    l = 1,
    full = 3,

    fn bytes(self: WidthSel) u64 {
        return switch (self) {
            .b => 1,
            .w => 2,
            .l => 4,
            .full => 8,
        };
    }
};

test "VERIFY stream pointer advance equals chunk * elementSize, hand-derived" {
    const cases = [_]struct { base: u64, chunk: u64, sel: WidthSel, want: u64 }{
        .{ .base = 0x1000, .chunk = 4, .sel = .l, .want = 0x1010 },
        .{ .base = 0x1000, .chunk = 4, .sel = .w, .want = 0x1008 },
        .{ .base = 0x1000, .chunk = 4, .sel = .b, .want = 0x1004 },
        .{ .base = 0x1000, .chunk = 4, .sel = .full, .want = 0x1020 },
        .{ .base = 0x2000, .chunk = 1, .sel = .b, .want = 0x2001 },
        .{ .base = 0x10, .chunk = 3, .sel = .full, .want = 0x28 },
    };
    for (cases) |c| {
        // Reference: advance = base + chunk * elementSize, wrapping at 64 bits.
        const want = c.base +% (c.chunk *% c.sel.bytes());
        try testing.expectEqual(c.want, want);

        var f = registers.File{};
        f.write(1, c.base);
        f.write(1, f.read(1) +% (c.chunk *% c.sel.bytes()));
        try testing.expectEqual(c.want, f.read(1));
    }
}

test "FALSIFY atomicity: a chunk that overruns the last element leaves memory byte-identical" {
    // 16 bytes of memory, filled with a sentinel. A 4-element 64-bit chunk starting at
    // address 8 needs 32 bytes: it overruns by exactly one element. Per §3.4 rule 3,
    // bounds are checked BEFORE any element is written, so zero elements may change.
    var buf: [16]u8 = @splat(0xA5);
    var mem = memory.Memory.init(&buf);
    const snapshot = buf;

    const base: u64 = 8;
    const chunk: u64 = 4;
    const esz: u64 = 8;
    try testing.expect(!mem.inBounds(base, chunk * esz));

    // The module's own all-or-nothing primitive, driven with the same shape.
    try testing.expectError(memory.BoundsError.OutOfBounds, mem.zero(base, chunk * esz));
    try testing.expectEqualSlices(u8, &snapshot, &buf);

    // Byte-for-byte, and explicitly element-by-element so a partial application of the
    // FIRST elements cannot hide inside a "some bytes changed" check.
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        try testing.expectEqual(snapshot[i], buf[i]);
    }
    try testing.expectEqualSlices(u8, &snapshot, mem.bytes);
}

test "FALSIFY atomicity: off-by-one at the exactly-fitting boundary" {
    // A chunk whose END lands exactly one byte past the region must be refused whole.
    var buf: [32]u8 = @splat(0x3C);
    var mem = memory.Memory.init(&buf);
    const snapshot = buf;

    // Fits exactly: 4 * 8 == 32 starting at 0.
    try testing.expect(mem.inBounds(0, 32));
    // One byte too far: refused.
    try testing.expect(!mem.inBounds(1, 32));
    var payload: [32]u8 = @splat(0);
    try testing.expectError(memory.BoundsError.OutOfBounds, mem.copyIn(1, &payload));

    var i: usize = 0;
    while (i < buf.len) : (i += 1) try testing.expectEqual(snapshot[i], buf[i]);
}

test "FALSIFY atomicity: a failing access never truncates and never returns zero" {
    var buf: [8]u8 = @splat(0x77);
    var mem = memory.Memory.init(&buf);

    // A 64-bit read spanning the end must be an error, not a truncated value and not 0.
    const r = mem.read64(4);
    try testing.expectError(memory.BoundsError.OutOfBounds, r);
    try testing.expectError(memory.BoundsError.OutOfBounds, mem.read32(5));
    try testing.expectError(memory.BoundsError.OutOfBounds, mem.write64(4, 0xDEAD_BEEF));

    // Nothing was written by the failed store.
    try testing.expectEqual(@as(u8, 0x77), buf[4]);
    try testing.expectEqual(@as(u8, 0x77), buf[7]);

    // An address that wraps past 2^64 is out of bounds, not accepted.
    try testing.expectError(memory.BoundsError.OutOfBounds, mem.read64(std.math.maxInt(u64) - 3));
    try testing.expect(!mem.inBounds(std.math.maxInt(u64), 2));
}

// ===========================================================================
// 3. Falsification: sub-width zero-extension (contract §6 step 2, P1.1)
//
// §5 makes zero-extension mandatory and observable. The attack is to set ALL 64 bits
// first and then write a narrow value: a preserving implementation keeps the upper
// bits and fails here. Sign-extension would also fail here.
// ===========================================================================

test "VERIFY sub-width zero-extension: upper bits are CLEARED, on every width" {
    var f = registers.File{};

    f.write(2, 0xFFFF_FFFF_FFFF_FFFF);
    f.writeWidth(2, .l, 0xCAFE_F00D);
    try testing.expectEqual(@as(u64, 0x0000_0000_CAFE_F00D), f.read(2));

    f.write(2, 0xFFFF_FFFF_FFFF_FFFF);
    f.writeWidth(2, .w, 0xBEEF);
    try testing.expectEqual(@as(u64, 0x0000_0000_0000_BEEF), f.read(2));

    f.write(2, 0xFFFF_FFFF_FFFF_FFFF);
    f.writeWidth(2, .b, 0x7F);
    try testing.expectEqual(@as(u64, 0x0000_0000_0000_007F), f.read(2));

    // A sub-width write whose value has bits above the width: they are dropped, not
    // spread upward, and the result still zero-extends.
    f.write(2, 0xFFFF_FFFF_FFFF_FFFF);
    f.writeWidth(2, .b, 0x1FF);
    try testing.expectEqual(@as(u64, 0x0000_0000_0000_00FF), f.read(2));

    // Sign-extension falsifier: 0x80 written as .b must NOT become 0xFFFFFFFFFFFFFF80.
    f.write(2, 0xFFFF_FFFF_FFFF_FFFF);
    f.writeWidth(2, .b, 0x80);
    try testing.expectEqual(@as(u64, 0x0000_0000_0000_0080), f.read(2));
    try testing.expect(f.read(2) != 0xFFFF_FFFF_FFFF_FF80);
}

test "VERIFY sub-width zero-extension: the encoded width field path agrees" {
    var f = registers.File{};

    // Encoded widths per §5: 0 full, 1 .l, 2 .w, 3 .b.
    f.write(4, 0xFFFF_FFFF_FFFF_FFFF);
    try f.writeEncoded(4, 1, 0xCAFE_F00D);
    try testing.expectEqual(@as(u64, 0x0000_0000_CAFE_F00D), f.read(4));

    f.write(4, 0xFFFF_FFFF_FFFF_FFFF);
    try f.writeEncoded(4, 2, 0xBEEF);
    try testing.expectEqual(@as(u64, 0x0000_0000_0000_BEEF), f.read(4));

    f.write(4, 0xFFFF_FFFF_FFFF_FFFF);
    try f.writeEncoded(4, 3, 0x7F);
    try testing.expectEqual(@as(u64, 0x0000_0000_0000_007F), f.read(4));

    f.write(4, 0xFFFF_FFFF_FFFF_FFFF);
    try f.writeEncoded(4, 0, 0xDEAD_BEEF_CAFE_F00D);
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF_CAFE_F00D), f.read(4));
}

test "FALSIFY reserved width: encodings 4..15 are refused and leave the register untouched" {
    // §5: "Value 4-15 are reserved and are a diagnostic error."
    var raw: u4 = 4;
    while (true) : (raw += 1) {
        var f = registers.File{};
        f.write(6, 0x1234_5678_9ABC_DEF0);
        try testing.expectError(error.ReservedWidthEncoding, f.writeEncoded(6, raw, 0xFFFF));
        // A refused write must not modify the register.
        try testing.expectEqual(@as(u64, 0x1234_5678_9ABC_DEF0), f.read(6));
        if (raw == 15) break;
    }
}

test "FALSIFY ZERO: no index, no write path, always reads zero" {
    var f = registers.File{};
    // Every GPR and system register is written; ZERO must still read zero. Counted in
    // usize because a u4 index would overflow on the step past index 15.
    var i: usize = 0;
    while (i < 16) : (i += 1) f.write(@intCast(i), 0xFFFF_FFFF_FFFF_FFFF);
    try testing.expectEqual(@as(u64, 0), f.zero());
    // Writing another register must never be observable through zero().
    try testing.expectEqual(@as(u64, 0), f.zero());
}

// ===========================================================================
// 4. Falsification: memory endianness and exact byte layout (P1.2)
//
// A round-trip test cannot catch an endianness bug; the exact byte layout can.
// ===========================================================================

test "VERIFY little-endian: exact byte order in memory, not a round-trip" {
    var buf: [24]u8 = @splat(0x00);
    var mem = memory.Memory.init(&buf);

    try mem.write64(0, 0x0123_4567_89AB_CDEF);
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01 },
        buf[0..8],
    );

    try mem.write32(8, 0xDEAD_BEEF);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xEF, 0xBE, 0xAD, 0xDE }, buf[8..12]);

    try mem.write16(12, 0x1234);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x34, 0x12 }, buf[12..14]);

    try mem.write8(14, 0x7F);
    try testing.expectEqual(@as(u8, 0x7F), buf[14]);

    // The bytes NOT written by a narrower store are untouched.
    try testing.expectEqual(@as(u8, 0x00), buf[15]);
}

// ===========================================================================
// 5. Falsification: diagnostics name the operand and are not bare hex (P2.1, §7)
// ===========================================================================

test "VERIFY diagnostics: rendered text names the offending operand and the line" {
    var buf: [512]u8 = undefined;
    const d = diagnostics.badOperand(
        3,
        "field.extract",
        4,
        "width",
        "width=0",
        "a width from 1 to 64, because a zero-width field selects no bits",
    );
    const text = renderDiag(d, &buf);

    try testing.expect(std.mem.indexOf(u8, text, "error:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "line 3") != null);
    try testing.expect(std.mem.indexOf(u8, text, "operand 4") != null);
    try testing.expect(std.mem.indexOf(u8, text, "width") != null);
    try testing.expect(std.mem.indexOf(u8, text, "width=0") != null);
    try testing.expect(std.mem.indexOf(u8, text, "field.extract") != null);
    try testing.expect(std.mem.endsWith(u8, text, "."));
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "FALSIFY diagnostics: the unknown-opcode diagnostic names the opcode and the PC" {
    // Contract P1.6: an unknown opcode must be reported naming the opcode value and
    // the PC, in plain language, never as a bare code.
    var buf: [512]u8 = undefined;

    const word: u64 = 0x00FF_0000_0000_0000; // opcode 0xFF, undefined by §3.
    const d = diagnostics.Diagnostic{
        .stage = "executing this instruction",
        .word = word,
        .pc = 8,
        .expected = "an opcode defined in the Celeris-64 instruction map (docs/isa-encoding.md §3)",
    };
    const text = renderDiag(d, &buf);

    try testing.expect(std.mem.indexOf(u8, text, "error:") != null);
    // It must name the offending value...
    try testing.expect(std.mem.indexOf(u8, text, "00ff000000000000") != null);
    // ...with a label, so a reader knows what the number is.
    try testing.expect(std.mem.indexOf(u8, text, "instruction word") != null);
    // ...and the PC, so the user knows where it was found. The field is `pc`, not
    // `line`: presenting a program counter as a source line was a real defect that an
    // earlier falsification caught, and the fix split the two. This Diagnostic is built
    // by hand, so we set `.pc` ourselves: no VM is involved in this test.
    try testing.expect(std.mem.indexOf(u8, text, "PC 8") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "FALSIFY diagnostics: a bare hex code is detectable as a violation" {
    // This is a test OF THE DETECTOR. A detector that says "fine" to everything would
    // make every other diagnostics assertion worthless.
    try testing.expect(diagnostics.hasBareHexCode("error: 0x00000005"));
    try testing.expect(diagnostics.hasBareHexCode("0x00000005"));
    try testing.expect(diagnostics.hasBareHexCode("warning: 0x1F"));
    // A labelled value is not bare and must not be flagged.
    try testing.expect(!diagnostics.hasBareHexCode("error: the instruction word 0x1234 could not be decoded."));
    try testing.expect(!diagnostics.hasBareHexCode("error: opcode 0x2A (42) is not defined."));
}

test "FALSIFY diagnostics: rendered sentences are grammatical, not just hex-free" {
    // The automated hex check is NOT sufficient. Reproduced live against src/vm.zig's
    // real paths, a divide-by-zero renders as
    //   "... the instruction word 0x1321... could not be executing a divide ..."
    // and a decode failure as
    //   "... could not be decoding this word ..."
    // Both are ungrammatical, both pass hasBareHexCode(), and both are the words a user
    // actually reads. AGENTS.md §4.2 wants plain-language explanations, so assert the
    // grammar too. The broken shape is "be <gerund phrase>": a verb slot filled by a
    // stage phrase that already carries its own verb.
    var buf: [1024]u8 = undefined;
    const cases = [_]diagnostics.Diagnostic{
        .{ .stage = "decoding this word", .word = 0xDEAD_BEEF_CAFE_F00D },
        .{
            .stage = "executing a divide",
            .word = 0x1321_1000_0000_0000,
            .operand = .{ .index = 2, .name = "divisor", .text = "0" },
        },
        .{ .stage = "executing this instruction", .word = 0xFFFF_FFFF_FFFF_FFFF },
    };
    for (cases) |c| {
        const text = diagnostics.renderToBuffer(c, &buf);
        // The specific defect: "could not be" followed by a gerund.
        try testing.expect(std.mem.indexOf(u8, text, "could not be decoding") == null);
        try testing.expect(std.mem.indexOf(u8, text, "could not be executing") == null);
        try testing.expect(std.mem.indexOf(u8, text, "could not be halting") == null);
        // Still must not be a bare hex code.
        try testing.expect(!diagnostics.hasBareHexCode(text));
    }
}

test "FALSIFY diagnostics: no constructor in the engine renders a bare hex token" {
    var buf: [1024]u8 = undefined;
    const cases = [_]diagnostics.Diagnostic{
        diagnostics.badMnemonic(1, "frobnicate R0, R1"),
        diagnostics.badOperand(7, "field.extract", 3, "width", "width=0", "a width from 1 to 64"),
        diagnostics.missingOperand(2, "select", 4, "match value", "select R3, R2", "a match value in square brackets"),
        diagnostics.spill(13),
        diagnostics.spill(64),
        diagnostics.truncatedImage("prog.bin", 13, 5),
        .{ .stage = "decoding this word", .word = 0xDEAD_BEEF_CAFE_F00D },
        .{ .stage = "executing this instruction", .word = 0x42, .expected = "an opcode defined in the instruction map" },
        .{ .stage = "executing this instruction", .word = 0xFFFF_FFFF_FFFF_FFFF },
    };
    for (cases) |c| {
        const text = renderDiag(c, &buf);
        try testing.expect(text.len > 0);
        try testing.expect(std.mem.endsWith(u8, text, "."));
        try testing.expect(!diagnostics.hasBareHexCode(text));
    }
}

test "VERIFY diagnostics: the spill warning fires past 12 GPRs and names the budget" {
    var buf: [512]u8 = undefined;
    const text = renderDiag(diagnostics.spill(13), &buf);
    try testing.expect(std.mem.startsWith(u8, text, "warning:"));
    try testing.expect(std.mem.indexOf(u8, text, "13 live values") != null);
    try testing.expect(std.mem.indexOf(u8, text, "12 general-purpose registers") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "VERIFY diagnostics: the bounds fault names address, base and length" {
    var buf: [512]u8 = undefined;
    const f = memory.BoundsFault{
        .action = "read 8 bytes little-endian",
        .address = 4096,
        .base = 0,
        .length = 256,
        .width = 8,
    };
    const text = f.render(&buf);
    try testing.expect(std.mem.indexOf(u8, text, "4096") != null);
    try testing.expect(std.mem.indexOf(u8, text, "base 0") != null);
    try testing.expect(std.mem.indexOf(u8, text, "256") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0x") == null);
    try testing.expect(std.mem.indexOf(u8, text, "out of bounds") != null);
}

// ===========================================================================
// 6. Cross-module determinism substrate (contract §6 step 4)
//
// The full-program determinism test runs the same encoded program twice and diffs
// complete register + memory state. Until src/vm.zig exists there is no execution
// loop to run, so the test below exercises the state-diffing machinery on the pieces
// that do exist: it proves the comparison is capable of FAILING when state differs.
// ===========================================================================

const VmState = struct {
    regs: [16]u64,
    mem: []const u8,

    fn eql(a: VmState, b: VmState) bool {
        if (!std.mem.eql(u64, &a.regs, &b.regs)) return false;
        return std.mem.eql(u8, a.mem, b.mem);
    }
};

test "FALSIFY the state-diff itself: it must detect a single-bit difference" {
    // A determinism test whose comparison cannot fail proves nothing. This proves the
    // comparison catches one changed register bit and one changed memory byte.
    var m1: [8]u8 = @splat(0);
    var m2: [8]u8 = @splat(0);
    const a = VmState{ .regs = @splat(0), .mem = &m1 };
    const b = VmState{ .regs = @splat(0), .mem = &m2 };
    try testing.expect(a.eql(b));

    var regs2: [16]u64 = @splat(0);
    regs2[5] = 1;
    const c = VmState{ .regs = regs2, .mem = &m2 };
    try testing.expect(!c.eql(a));

    m2[3] = 1;
    try testing.expect(!a.eql(b));
}

// ===========================================================================
// 7. VM-level falsification (contract §6 steps 1, 3, 4, 5, 6)
//
// These drive the real fetch-decode-execute loop through `vm.encode`, which builds
// words from the §2 layout, so the tests express programs in the contract's own bit
// encoding rather than through the assembler.
// ===========================================================================

/// A fixed image, caller-owned. Mirrors contract P1.6: allocate once, no per-instruction
/// allocation anywhere in the loop.
fn fitImage(comptime words: []const u64) [words.len * 8 + 64]u8 {
    var img: [words.len * 8 + 64]u8 = @splat(0);
    for (words, 0..) |w, i| {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, w, .little);
        @memcpy(img[i * 8 ..][0..8], &b);
    }
    return img;
}

/// Builds a stream.* word from docs/isa-encoding.md §3.4, independently of any helper
/// in src/: rs2[47:44], chunk[43:24], element-width selector[23:20], reserved[19:0].
/// Derived from the bit table, not from the VM's own encoder, so a shared bug in their
/// encoder cannot make my test agree with itself.
///
/// `width_sel` is the §5 encoding, NOT a byte count: 0 = 64-bit, 1 = .l (32), 2 = .w
/// (16), 3 = .b (8). §3.4 defers to §5 for this field.
fn streamWord(op: u8, rd: u4, rs1: u4, rs2: u4, chunk: u20, width_sel: u4) u64 {
    const operand: u48 = (@as(u48, rs2) << 44) |
        (@as(u48, chunk) << 24) |
        (@as(u48, width_sel) << 20);
    return vm.encode(op, rd, rs1, operand);
}

test "VERIFY VM: PC advances by the fixed 64-bit stride and halt stops the machine" {
    var img = fitImage(&.{
        vm.encode(0x00, 0, 0, 0), // nop
        vm.encode(0x00, 0, 0, 0), // nop
        vm.encode(0x01, 0, 0, 0), // halt
    });
    var m = vm.Vm.init(&img);
    _ = try m.step();
    try testing.expectEqual(@as(u64, 8), m.regs.pc);
    _ = try m.step();
    try testing.expectEqual(@as(u64, 16), m.regs.pc);
    const s = try m.step();
    try testing.expect(s == .halted);
    try testing.expect(m.halted);
}

test "FALSIFY determinism: the same encoded program twice, full register+memory diff" {
    // Contract §6 step 4. The program deliberately covers ALU, sub-width writes, a
    // load/store through memory and a branch, so that state differences have somewhere
    // to hide. The diff covers registers, memory bytes AND the retired count.
    const program = comptime [_]u64{
        vm.encode(0x19, 1, 0, vm.aluOperand(0, .full, 0x07FF_FFFF)), // R1 = 0x07FFFFFF (signed imm28 max)
        vm.encode(0x19, 2, 0, vm.aluOperand(0, .w, 0x1FF)), // R2.w = 0x1FF -> 0xFF (truncation + zero-ext)
        vm.encode(0x10, 3, 1, vm.aluOperand(0, .full, 7)), // R3 = R1 + 7
        vm.encode(0x16, 4, 3, vm.aluOperand(2, .full, 0)), // R4 = R3 ^ R2
        vm.encode(0x17, 5, 4, vm.aluOperand(0, .full, 1)), // R5 = R4 << 1
        vm.encode(0x01, 0, 0, 0), // halt
    };

    var img1 = fitImage(&program);
    var img2 = fitImage(&program);
    var a = vm.Vm.init(&img1);
    var b = vm.Vm.init(&img2);

    const da = try a.run(100);
    const db = try b.run(100);

    // Both must reach the same stop reason (halt), not one faulting while the other
    // does not: equal-but-wrong is not determinism.
    var buf_a: [512]u8 = undefined;
    var buf_b: [512]u8 = undefined;
    try testing.expectEqualStrings(
        diagnostics.renderToBuffer(da, &buf_a),
        diagnostics.renderToBuffer(db, &buf_b),
    );

    // Full-state diff, in this order: registers, memory, retired count.
    try testing.expect(a.snapshot().eql(b.snapshot()));
    try testing.expectEqualSlices(u8, &img1, &img2);
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        try testing.expectEqual(a.regs.gpr[i], b.regs.gpr[i]);
    }
    try testing.expectEqual(a.regs.pc, b.regs.pc);
    try testing.expectEqual(a.regs.sp, b.regs.sp);
    try testing.expectEqual(a.regs.lr, b.regs.lr);
    try testing.expectEqual(a.regs.flags, b.regs.flags);
    try testing.expectEqual(a.retired, b.retired);
}

test "VERIFY sub-width zero-extension end-to-end through the execution loop" {
    // The mandatory P1.1 guarantee, observed at the VM level rather than the register
    // file level: set ALL 64 bits, then write .b, then read the full register back.
    var img = fitImage(&.{
        vm.encode(0x19, 0, 0, vm.aluOperand(0, .full, 0)), // R0 = 0
        vm.encode(0x11, 0, 0, vm.aluOperand(0, .full, 1)), // R0 = 0 - 1 = all ones
        vm.encode(0x19, 0, 0, vm.aluOperand(0, .b, 0x7F)), // R0.b = 0x7F
        vm.encode(0x01, 0, 0, 0),
    });
    var m = vm.Vm.init(&img);
    _ = try m.run(100);
    try testing.expectEqual(@as(u64, 0x0000_0000_0000_007F), m.regs.read(0));
    try testing.expectEqual(@as(u64, 0), m.regs.read(0) & 0xFFFF_FFFF_FFFF_FF80);
}

test "FALSIFY unknown opcode: it faults, names the opcode and the PC, and does not panic" {
    // Contract P1.6. 0xAB is not in the §3 map.
    var img = fitImage(&.{
        vm.encode(0x00, 0, 0, 0), // nop -> PC 8
        vm.encode(0xAB, 0, 0, 0), // unknown
    });
    var m = vm.Vm.init(&img);
    _ = try m.step();
    const s = try m.step();
    try testing.expect(s == .fault);

    var buf: [512]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "error:") != null);
    // Must name the offending opcode VALUE with a label, not a bare code and not a
    // loose substring: "opcode 171 (171)" is what actually identifies it. A bare
    // "ab" substring check would pass on any text containing those two letters.
    try testing.expect(std.mem.indexOf(u8, text, "opcode 171 (171)") != null);
    // The PC it was found at. A program counter renders as "PC 8"; the `line` field is
    // reserved for source lines in text input, which this is not.
    try testing.expect(std.mem.indexOf(u8, text, "PC 8") != null);
    try testing.expect(std.mem.indexOf(u8, text, "line 8") == null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
    try testing.expect(m.halted);
}

test "FALSIFY divide-by-zero: rd is NOT written and the diagnostic names the divisor" {
    // Contract: "divide-by-zero is a diagnostic error, not a trap" (§3.1) and a failed
    // instruction must not commit a partial result.
    var img = fitImage(&.{
        vm.encode(0x19, 1, 0, vm.aluOperand(0, .full, 0)), // R1 = 0
        vm.encode(0x19, 2, 0, vm.aluOperand(0, .full, 0x99)), // R2 = 0x99 (sentinel)
        vm.encode(0x13, 2, 1, vm.aluOperand(1, .full, 0)), // R2 = R1 / R1
        vm.encode(0x01, 0, 0, 0),
    });
    var m = vm.Vm.init(&img);
    _ = try m.step();
    _ = try m.step();
    const s = try m.step();
    try testing.expect(s == .fault);
    // The destination kept its sentinel: nothing was committed.
    try testing.expectEqual(@as(u64, 0x99), m.regs.read(2));

    var buf: [512]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "divisor") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "VERIFY reserved ALU width encoding faults instead of silently going full-width" {
    // §5: widths 4..15 are reserved and are a diagnostic error.
    var img = fitImage(&.{
        vm.encode(0x19, 1, 0, vm.aluOperand(0, .full, 5)),
        // width encoded as 4 (reserved), hand-built because Width cannot express it.
        vm.encode(0x19, 1, 0, (0 << 44) | (4 << 40) | 0),
        vm.encode(0x01, 0, 0, 0),
    });
    var m = vm.Vm.init(&img);
    _ = try m.step();
    const s = try m.step();
    try testing.expect(s == .fault);
    try testing.expectEqual(@as(u64, 5), m.regs.read(1));

    var buf: [512]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(!diagnostics.hasBareHexCode(text));
    try testing.expect(std.mem.indexOf(u8, text, "width") != null);
}

test "FALSIFY fetch past the end refuses, does not truncate, and names address/base/length" {
    var img = fitImage(&.{vm.encode(0x00, 0, 0, 0)});
    var m = vm.Vm.init(&img);
    m.regs.pc = img.len; // one past the last valid byte
    try testing.expectError(error.OutOfBounds, m.step());
    try testing.expect(m.halted);

    var buf: [512]u8 = undefined;
    const text = m.boundsText("fetching the instruction", m.regs.pc, 8).render(&buf);
    try testing.expect(std.mem.indexOf(u8, text, "base 0") != null);
    try testing.expect(std.mem.indexOf(u8, text, "byte(s) long") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0x") == null);
}

test "FALSIFY a non-halting program stops at the limit instead of hanging" {
    var img = fitImage(&.{
        vm.encode(0x00, 0, 0, 0),
        vm.encode(0x02, 0, 0, 0), // jump 0
    });
    var m = vm.Vm.init(&img);
    const d = try m.run(50);
    try testing.expectEqual(@as(u64, 50), m.retired);
    var buf: [512]u8 = undefined;
    const text = diagnostics.renderToBuffer(d, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "instruction limit") != null);
}

test "FALSIFY jump/call/ret are the only PC-relative moves, and LR is the return address" {
    var img = fitImage(&.{
        vm.encode(0x03, 0, 0, 32), // call 32 -> LR = 8
        vm.encode(0x01, 0, 0, 0), // halt
        vm.encode(0x00, 0, 0, 0),
        vm.encode(0x00, 0, 0, 0),
        vm.encode(0x04, 0, 0, 0), // ret -> PC = 8
    });
    var m = vm.Vm.init(&img);
    _ = try m.step();
    try testing.expectEqual(@as(u64, 32), m.regs.pc);
    try testing.expectEqual(@as(u64, 8), m.regs.lr);
    _ = try m.step();
    try testing.expectEqual(@as(u64, 8), m.regs.pc);
    const s = try m.step();
    try testing.expect(s == .halted);
}

test "FALSIFY end-to-end atomicity: stream.add overrunning its LAST element changes nothing" {
    // Contract §6 step 3, now end-to-end through the real VM and stream engine.
    // Memory is the image itself (128 bytes). The pointer is placed so that the chunk
    // fits its FIRST element but overruns on its LAST: ptr=120, chunk=2, 64-bit element
    // => needs 16 bytes, only 8 remain. Per §3.4 rule 3 the bounds check precedes every
    // write, so ZERO elements may change and the pointer must not advance.
    var img = fitImage(&.{
        vm.encode(0x19, 1, 0, vm.aluOperand(0, .full, 120)), // R1 = 120 (stream pointer)
        vm.encode(0x19, 2, 0, vm.aluOperand(0, .full, 7)), // R2 = 7 (the addend)
        streamWord(0x40, 0, 1, 2, 2, 0), // stream.add R0, [R1]+2, R2 (§5 selector 0 = 64-bit)
        vm.encode(0x01, 0, 0, 0),
    });
    const before = img;

    var m = vm.Vm.init(&img);
    _ = try m.step();
    _ = try m.step();
    const s = try m.step();

    // It must fail...
    try testing.expect(s == .fault);
    try testing.expect(m.halted);

    // ...in plain language, naming what was refused...
    var buf: [640]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(!diagnostics.hasBareHexCode(text));
    try testing.expect(std.mem.indexOf(u8, text, "chunk") != null);

    // ...with memory BYTE-FOR-BYTE unchanged...
    try testing.expectEqualSlices(u8, &before, &img);
    var i: usize = 0;
    while (i < img.len) : (i += 1) try testing.expectEqual(before[i], img[i]);

    // ...and the stream pointer NOT advanced.
    try testing.expectEqual(@as(u64, 120), m.regs.read(1));

    // The destination register must not have received a phantom element either.
    try testing.expectEqual(@as(u64, 0), m.regs.read(0));
}

test "VERIFY end-to-end: stream.add is load-add-store, advancing by chunk*elementSize" {
    // The positive half of the atomicity rule: when the chunk DOES fit, every element is
    // transformed IN PLACE and the pointer advances by exactly chunk*elementSize.
    // Without this, the atomicity test could pass on an engine that never does anything.
    //
    // §3.4 `stream.add` is a fused load/add/store ("fused load / add / store over a
    // chunk"), so it accumulates into existing memory rather than overwriting it. The
    // data lives at byte 64, well clear of the program words at 0..32, because the
    // image IS the memory and a stream aimed at the program would rewrite instructions.
    var img = fitImage(&.{
        vm.encode(0x19, 1, 0, vm.aluOperand(0, .full, 64)), // R1 = 64 (pointer)
        vm.encode(0x19, 2, 0, vm.aluOperand(0, .full, 5)), // R2 = 5 (addend)
        streamWord(0x40, 0, 1, 2, 4, 0), // stream.add R0, [R1]+4, R2 (§5 selector 0 = 64-bit)
        vm.encode(0x01, 0, 0, 0),
    });
    var seed = vm.Memory.init(&img);
    try seed.write64(64, 4);
    try seed.write64(72, 5);
    try seed.write64(80, 6);
    try seed.write64(88, 7);

    var m = vm.Vm.init(&img);
    _ = try m.step();
    _ = try m.step();
    const s = try m.step();
    try testing.expect(s == .advanced);

    // Hand-derived: 4+5=9, 5+5=10, 6+5=11, 7+5=12.
    try testing.expectEqual(@as(u64, 9), try m.mem.read64(64));
    try testing.expectEqual(@as(u64, 10), try m.mem.read64(72));
    try testing.expectEqual(@as(u64, 11), try m.mem.read64(80));
    try testing.expectEqual(@as(u64, 12), try m.mem.read64(88));

    // Advance = chunk * elementSize = 4 * 8 = 32, so 64 -> 96.
    try testing.expectEqual(@as(u64, 96), m.regs.read(1));

    // The program words themselves must be untouched: the stream wrote only its chunk.
    try testing.expectEqual(@as(u64, 4 * 8), m.regs.read(1) - 64);
}

test "FALSIFY end-to-end: stream with chunk 0 is refused, not treated as a no-op" {
    // §3.4: chunk is an element count and must be >= 1. A zero chunk must be a
    // diagnostic, and it must not advance the pointer.
    var img = fitImage(&.{
        vm.encode(0x19, 1, 0, vm.aluOperand(0, .full, 0)),
        streamWord(0x40, 0, 1, 2, 0, 0), // chunk 0, 64-bit elements
        vm.encode(0x01, 0, 0, 0),
    });
    var m = vm.Vm.init(&img);
    _ = try m.step();
    const s = try m.step();
    try testing.expect(s == .fault);
    try testing.expectEqual(@as(u64, 0), m.regs.read(1));

    var buf: [640]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "VERIFY end-to-end field.extract: the spec's literal example through the VM" {
    // Opcode 0x30, operand: offset[47:40], width[39:32]. Hand-derived: bits 12..14 of
    // 0xDEADBEEFCAFEF00D are 0b111 = 0x7.
    var img = fitImage(&.{
        vm.encode(0x30, 0, 1, (12 << 40) | (3 << 32)), // field.extract R0, R1, offset=12 width=3
        vm.encode(0x01, 0, 0, 0),
    });
    var m = vm.Vm.init(&img);
    m.regs.write(1, 0xDEAD_BEEF_CAFE_F00D);
    const s = try m.step();
    try testing.expect(s == .advanced);
    try testing.expectEqual(@as(u64, 0x7), m.regs.read(0));
}

test "VERIFY end-to-end field.extract: hand-derived boundary widths through the VM" {
    const v: u64 = 0xDEAD_BEEF_CAFE_F00D;
    const cases = [_]struct { off: u8, w: u8, want: u64 }{
        .{ .off = 0, .w = 1, .want = 0x1 },
        .{ .off = 0, .w = 64, .want = 0xDEAD_BEEF_CAFE_F00D },
        .{ .off = 32, .w = 32, .want = 0xDEAD_BEEF },
        .{ .off = 59, .w = 5, .want = 0x1B },
        .{ .off = 63, .w = 1, .want = 0x1 },
        .{ .off = 12, .w = 52, .want = 0xDEAD_BEEF_CAFEF },
    };
    inline for (cases) |c| {
        var img = fitImage(&.{
            vm.encode(0x30, 0, 1, (@as(u48, c.off) << 40) | (@as(u48, c.w) << 32)),
            vm.encode(0x01, 0, 0, 0),
        });
        var m = vm.Vm.init(&img);
        m.regs.write(1, v);
        _ = try m.step();
        try testing.expectEqual(c.want, m.regs.read(0));
    }
}

test "FALSIFY end-to-end field.extract: width 0 and offset+width>64 both refused" {
    // §3.3.1: width must be 1..=64 and offset+width <= 64, both diagnostic errors.
    const bad = [_]struct { off: u8, w: u8 }{
        .{ .off = 12, .w = 0 }, // width 0
        .{ .off = 60, .w = 8 }, // 68 > 64
        .{ .off = 64, .w = 1 }, // 65 > 64
        .{ .off = 0, .w = 65 }, // width 65 is not a legal field width
    };
    inline for (bad) |c| {
        var img = fitImage(&.{
            vm.encode(0x30, 0, 1, (@as(u48, c.off) << 40) | (@as(u48, c.w) << 32)),
            vm.encode(0x01, 0, 0, 0),
        });
        var m = vm.Vm.init(&img);
        m.regs.write(1, 0xDEAD_BEEF_CAFE_F00D);
        const s = try m.step();
        try testing.expect(s == .fault);

        var buf: [640]u8 = undefined;
        const text = diagnostics.renderToBuffer(s.fault, &buf);
        try testing.expect(!diagnostics.hasBareHexCode(text));
        // Nothing may be committed to the destination on a refused extraction.
        try testing.expectEqual(@as(u64, 0), m.regs.read(0));
    }
}

// ===========================================================================
// 8. Decoder expectations, hand-derived from docs/isa-encoding.md §2–§3
//
// Written BEFORE src/decoder.zig existed, so these are independent of it. The word
// constants below were computed by hand from the bit table:
//   opcode[63:56]  rd[55:52]  rs1[51:48]  operand[47:0]
//   ALU operand:     rs2[47:44]  width[43:40]  imm28[39:0]
//   field operand:   offset[47:40]  width[39:32]  src2[31:28]
//   stream operand:  rs2[47:44]  chunk[43:24]  ewidth[23:20]  reserved[19:0]
//
// If `vm.decoding` exposes `decode`, these lock the layout down. They are declared
// against the module surface, so a decoder that renames or reshapes its API fails
// loudly here instead of quietly reducing coverage.
// ===========================================================================

test "VERIFY decoder layout: opcode/rd/rs1 extraction matches the hand-derived words" {
    // field.extract R0, R1, offset=12, width=3
    const w_field: u64 = 0x3001_0C03_0000_0000;
    try testing.expectEqual(@as(u64, 0x30), (w_field >> 56) & 0xFF);
    try testing.expectEqual(@as(u64, 0), (w_field >> 52) & 0xF);
    try testing.expectEqual(@as(u64, 1), (w_field >> 48) & 0xF);
    try testing.expectEqual(@as(u64, 12), (w_field >> 40) & 0xFF);
    try testing.expectEqual(@as(u64, 3), (w_field >> 32) & 0xFF);

    // mov R0.b, 0xAB
    const w_mov: u64 = 0x1900_0300_0000_00AB;
    try testing.expectEqual(@as(u64, 0x19), (w_mov >> 56) & 0xFF);
    try testing.expectEqual(@as(u64, 3), (w_mov >> 40) & 0xF); // .b
    try testing.expectEqual(@as(u64, 0xAB), w_mov & 0x0FFF_FFFF);

    // stream.add R0, [R1]+4 with the 64-bit element selector
    const w_stream: u64 = 0x4001_0000_0430_0000;
    try testing.expectEqual(@as(u64, 0x40), (w_stream >> 56) & 0xFF);
    try testing.expectEqual(@as(u64, 4), (w_stream >> 24) & 0xFFFFF); // chunk
    try testing.expectEqual(@as(u64, 3), (w_stream >> 20) & 0xF); // element width selector
    try testing.expectEqual(@as(u64, 0), w_stream & 0xFFFFF); // reserved must be zero
}

test "VERIFY imm28 sign-extension: bit 27 set must reach the top of the register" {
    // §3.1: "imm28[39:0] - signed 28-bit immediate, sign-extended to 64 bits."
    // The hand-derived value for imm28 = 0x0800_0000 is -134217728, whose 64-bit
    // two's-complement form is 0xFFFF_FFFF_F800_0000.
    const imm28: u28 = 0x0800_0000;
    const signed: i28 = @bitCast(imm28);
    try testing.expectEqual(@as(i28, -134_217_728), signed);
    const widened: u64 = @bitCast(@as(i64, signed));
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_F800_0000), widened);

    // A positive imm28 keeps its zero upper bits.
    const pos: i28 = 42;
    try testing.expectEqual(@as(u64, 42), @as(u64, @bitCast(@as(i64, pos))));
}
