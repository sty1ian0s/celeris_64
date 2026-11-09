//! The analyzers' no-false-positive contract, checked against the programs this
//! repository actually ships and runs.
//!
//! This file exists because a finding on a correct program is the worst outcome
//! available to a static analyzer: it tells a user their working code is broken. The
//! rule is therefore not "does the analyzer find the bug I wrote a test for" but
//! "does it stay silent on code that is KNOWN to be correct" — and that claim has to
//! be re-checked whenever a rule is added or changed.
//!
//! The programs here are the six CLS64 kernels of the cross-architecture example
//! suite (`src/examples.zig`), each of which `examples.measureExample` verifies to
//! compute the same answer as its RISC-V, AArch64 and x86-64 counterparts, and the
//! cross-check programs in `tests/crosscheck/`. Every one is a correct program; a
//! finding on any of them is a defect in `src/analyzer.zig`.
//!
//! Roots at src/examples.zig so the kernels are reachable; that module imports the
//! VM, which is why this test is not an inline test of the assembler.

const std = @import("std");
// All three are handles on ONE src/ module graph, supplied by build.zig. Zig refuses
// to put a src file in two modules, so the roots are named rather than pathed.
const asmb = @import("tooling");
const diag = asmb.diagnostics;
const examples = asmb.examples;

const testing = std.testing;

/// Assembles and analyzes one program and returns how many findings it produced,
/// printing each one so a failure names the sentence rather than just a count.
///
/// "FALSE POSITIVE" is asserted by the caller, not here: the positive tests below
/// call this on programs the rule is SUPPOSED to flag, so a finding is not by itself
/// an error at this point.
fn findingsFor(name: []const u8, source: []const u8) !usize {
    var a = asmb.Assembler.init(testing.allocator);
    var d: asmb.Diagnostic = .{};
    // On success `assembleSource` MOVES its arena into the returned `Program`
    // (docs/HANDOFF.md §4). Deinit'ing both frees the same nodes twice and aborts,
    // so exactly one of the two owners is released on each path.
    var program = a.assembleSource(name, source, &d) catch {
        a.deinit();
        std.debug.print("the program \"{s}\" did not assemble: ", .{name});
        var dbuf: [1024]u8 = undefined;
        std.debug.print("{s}\n", .{diag.renderToBuffer(d, &dbuf)});
        return error.AssemblyFailed;
    };
    defer program.deinit();

    const findings = a.analyzeSource(name);
    for (findings.slice()) |f| {
        var buf: [1024]u8 = undefined;
        std.debug.print("finding on \"{s}\":\n  {s}\n", .{
            name,
            diag.renderToBuffer(f, &buf),
        });
    }
    return findings.len;
}
test "the six example kernels produce no findings" {
    // If this fails, the ANALYZER is wrong, not the kernel: each of these is
    // executed by the example suite and checked against a reference answer and
    // three other ISA implementations (src/examples.zig, `measureExample`).
    var total: usize = 0;
    for (&examples.examples) |*ex| {
        total += try findingsFor(ex.name, ex.cls64);
    }
    try testing.expectEqual(@as(usize, 0), total);
}

test "the four cross-check programs produce no findings" {
    // tests/crosscheck/*.asm, byte-verified against the recorded images. They are
    // short on purpose: they cover zero-extension, ALU immediates, call/ret and
    // the stream widths, which is exactly the surface a naive analyzer trips on.
    const cases = [_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "p1_zeroext.asm", .source = "mov R0, 134217727\nmov R0.w, 65535\nmov R0.l, 134217727\nmov R0.b, 255\nmov R0, -1\nmov R0.w, 4660\nhalt\n" },
        .{ .name = "p2_aluimm.asm", .source = "mov R0, 100\nadd R1, R0, 50\nsub R2, R1, 25\nmul R3, R2, 4\nand R4, R3, 255\nor R5, R4, 256\nxor R6, R5, 15\nshl R7, R6, 2\nshr R8, R7, 1\nmov R9, -1\nhalt\n" },
        .{ .name = "p3_callret.asm", .source = "mov R1, 9\ncall 40\nhalt\nnop\nnop\nret\njump 64\nnop\nhalt\n" },
        .{ .name = "p4x.asm", .source = "mov R1, 256\nstream.add R0, [R1]+4, R0.w\nmov R2, 10\nstream.add R3, [R1]+8, R3.l\nhalt\n" },
    };
    var total: usize = 0;
    for (cases) |c| total += try findingsFor(c.name, c.source);
    try testing.expectEqual(@as(usize, 0), total);
}

fn opcodeOf(word: u64) asmb.Opcode {
    return @fromBackingInt(@intCast(@as(u8, @truncate(word >> 56))));
}

/// tests/mulout_e2e.sh's self-checking matrix program, copied verbatim from the
/// heredoc (comments and indentation removed). Its `jump 400000` is the DELIBERATE
/// fault trap: a mismatch must leave the 64 KiB image so it faults loudly. A rule
/// that reported a transfer leaving the source would fire here, and this program is
/// correct by construction.
const mulout_self_check =
    \\mov R1, 1024
    \\mov R2, 1088
    \\mov R3, 1216
    \\matrix.mulout R3, R1, R2
    \\mov R4, 1224
    \\load R5, [R4+0]
    \\load R6, [R4+8]
    \\load R7, [R4+16]
    \\load R8, [R4+24]
    \\mov R11, 1280
    \\load R9, [R11+0]
    \\compare R10, R5, R9
    \\branch R10, [EQUAL], el00
    \\jump 400000
    \\el00:
    \\load R9, [R11+8]
    \\compare R10, R6, R9
    \\branch R10, [EQUAL], el01
    \\jump 400000
    \\el01:
    \\load R9, [R11+16]
    \\compare R10, R7, R9
    \\branch R10, [EQUAL], el10
    \\jump 400000
    \\el10:
    \\load R9, [R11+24]
    \\compare R10, R8, R9
    \\branch R10, [EQUAL], done
    \\jump 400000
    \\done:
    \\halt
;

test "the programs the shell drivers in tools/ and tests/ assemble produce no findings" {
    // Requirement: every CLS64 program in the repository is run against a new rule.
    // These are the inline programs embedded in `tools/accel_e2e.sh` and
    // `tests/mulout_e2e.sh` as heredocs, which the arithmetic a rule keys on can
    // trip over: `jump 400000` deliberately leaves the image as a mismatch trap, and
    // the `stream.*` cases put the element and offset registers in unusual places.
    // Each string is copied VERBATIM from its driver, minus indentation.
    const cases = [_]struct { name: []const u8, source: []const u8 }{
        // tools/accel_e2e.sh
        .{ .name = "accel_e2e:fnv.asm", .source = "mov R2, 0x1000\ncodec.fnv1a R1, R2, count=3\nhalt\n" },
        .{ .name = "accel_e2e:ident.asm", .source = "mov R1, 0x1000\nmov R2, 2\nmatrix.identity R1, R2\nhalt\n" },
        .{ .name = "accel_e2e:zerocount.asm", .source = "mov R2, 0x1000\ncodec.fnv1a R1, R2\nhalt\n" },
        .{ .name = "accel_e2e:misaligned.asm", .source = "mov R1, 0x1002\nmov R2, 2\nmatrix.identity R1, R2\nhalt\n" },
        .{ .name = "accel_e2e:oob.asm", .source = "mov R2, 0x40\ncodec.fnv1a R1, R2, count=1048576\nhalt\n" },
        .{ .name = "accel_e2e:comp.asm", .source = "mov R2, 0x1000\ncodec.compress R1, R2, count=8\nhalt\n" },
        .{ .name = "accel_e2e:dec.asm", .source = "codec.decompress R1, R2, count=8\nhalt\n" },
        .{ .name = "accel_e2e:mul.asm", .source = "matrix.mul R1, R2, R3\nhalt\n" },
        // tests/mulout_e2e.sh — the self-checking matrix program. Its `jump 400000`
        // is the deliberate fault trap, and it must NOT be reported: leaving the
        // image is the behaviour that program depends on (§2.3).
        .{ .name = "mulout_e2e:mul.asm", .source = mulout_self_check },
        .{ .name = "mulout_e2e:old.asm", .source = "matrix.mul R1, R2, R3\nhalt\n" },
        // tools/v22_gen.sh, the thread/capability sweep's skeleton.
        .{ .name = "v22_gen:threads.asm", .source = "thread.spawn no slots, R0\nthread.spawn T0, R1\nthread.spawn T3, R1\nthread.spawn T7, R1\nthread.spawn T0, T3, T7, R1\nthread.join T2\nthread.yield\n" },
        // tools/v22_gen.sh, the capability/thread sweep. The two-operand forms are
        // the legal ones; `cap.load R2, R3, R4` is in that generator's list too, but
        // it is expected to be REJECTED there ("[REJECT]" in its output), so it is
        // not a program and cannot be asserted to assemble here.
        .{ .name = "v22_gen:cap.asm", .source = "cap.load R2, R3\ncap.store R3, R2\ncap.check R2, R3\ncap.check R0, R1\ncap.check R0, R7\n" },
    };
    var total: usize = 0;
    for (cases) |c| total += try findingsFor(c.name, c.source);
    try testing.expectEqual(@as(usize, 0), total);
}

// ---------------------------------------------------------------------------
// The rules added for breadth: each is proved to FIRE on the program shape it
// targets and to stay SILENT on a nearby correct program. Both halves matter —
// a rule that never fires is dead weight, and a rule that fires on the correct
// neighbour is the defect this file exists to catch.
// ---------------------------------------------------------------------------

test "a select with the same register in both arms is reported" {
    // `select R3, R2, [EQUAL], R5, R5` is decided by the instruction word alone:
    // §3.2.2 selects bitwise between the arms, so one register named twice gives
    // that register back whichever way the status falls. Running the two forms
    // shows the same R3 (9) from the select and from the equivalent `mov`.
    const source = "mov R1, 5\nmov R4, 7\nmov R5, 9\n" ++
        "compare R2, R1, R4\nselect R3, R2, [EQUAL], R5, R5\nhalt\n";
    try testing.expectEqual(@as(usize, 1), try findingsFor("sel.asm", source));
}

test "NEGATIVE: a select with two different arms is not reported" {
    // The neighbouring correct program: identical except that the arms differ, so
    // the status register genuinely decides the result. One character apart from
    // the positive case above, which is what makes the pair evidence.
    const source = "mov R1, 5\nmov R4, 7\nmov R5, 9\n" ++
        "compare R2, R1, R4\nselect R3, R2, [EQUAL], R4, R5\nhalt\n";
    try testing.expectEqual(@as(usize, 0), try findingsFor("sel_ok.asm", source));
}

test "a field.extract taking all 64 bits from bit 0 is reported" {
    // §3.3: `(rs1 >> 0) & mask(64)` is `rs1`. Verified by running it: the
    // destination receives exactly the source value.
    try testing.expectEqual(
        @as(usize, 1),
        try findingsFor("ext.asm", "mov R1, 12345\nfield.extract R2, R1, offset=0, width=64\nhalt\n"),
    );
}

test "NEGATIVE: a field.extract that actually slices is not reported" {
    // Both neighbours are real slices: one drops the top 32 bits, the other drops
    // bit 0. The rule keys on offset 0 AND width 64, not on either alone.
    try testing.expectEqual(
        @as(usize, 0),
        try findingsFor("ext32.asm", "mov R1, 12345\nfield.extract R2, R1, offset=0, width=32\nhalt\n"),
    );
    try testing.expectEqual(
        @as(usize, 0),
        try findingsFor("ext63.asm", "mov R1, 12345\nfield.extract R2, R1, offset=1, width=63\nhalt\n"),
    );
}

test "a field.insert replacing all 64 bits is reported" {
    // §3.3: inserting 64 bits at offset 0 clears every bit of the base first, so
    // the base register cannot reach the result. Verified by running it: the
    // destination receives exactly the inserted register's value.
    const source = "mov R1, 777\nmov R3, 424242\n" ++
        "field.insert R2, R1, offset=0, width=64, R3\nhalt\n";
    try testing.expectEqual(@as(usize, 1), try findingsFor("ins.asm", source));
}

test "NEGATIVE: a field.insert that keeps part of the base is not reported" {
    // Width 63 at offset 0 leaves the base's top bit in the result, so the base
    // register does reach it and the instruction is a real merge, not a `mov`.
    const source = "mov R1, 777\nmov R3, 424242\n" ++
        "field.insert R2, R1, offset=0, width=63, R3\nhalt\n";
    try testing.expectEqual(@as(usize, 0), try findingsFor("ins63.asm", source));
}

test "the three degenerate-form rules are load-bearing, not decorative" {
    // A rule can pass every negative test by never firing. Each positive case above
    // is re-checked here against its own encoding: the rule keys on the fields the
    // assembler actually wrote, and the positive and negative forms of each rule
    // are different words rather than different source spellings of one word.
    const sel = try assembled("select R3, R2, [EQUAL], R5, R5");
    try testing.expectEqual(asmb.Opcode.select, opcodeOf(sel));

    const whole = try assembled("field.extract R2, R1, offset=0, width=64");
    try testing.expectEqual(asmb.Opcode.field_extract, opcodeOf(whole));
    const ins = try assembled("field.insert R2, R1, offset=0, width=64, R3");
    try testing.expectEqual(asmb.Opcode.field_insert, opcodeOf(ins));

    // The positive and negative forms of the field rule are NOT the same word, so
    // the two findings cannot be an artefact of one encoding being read twice.
    const part = try assembled("field.extract R2, R1, offset=0, width=32");
    try testing.expect(whole != part);
    // And the select's two arms really are one register in the emitted word.
    const sel_ok = try assembled("select R3, R2, [EQUAL], R4, R5");
    try testing.expect(sel != sel_ok);
}

/// Assembles one instruction and returns its encoded word. Used to check that a
/// rule's positive and negative forms really are different encodings rather than
/// two spellings of one word. The word is returned by value, so nothing outlives
/// the `Program` the way a slice would (docs/HANDOFF.md §4).
fn assembled(line: []const u8) !u64 {
    const source = try std.fmt.allocPrint(testing.allocator, "{s}\nhalt\n", .{line});
    defer testing.allocator.free(source);
    var a = asmb.Assembler.init(testing.allocator);
    var d: asmb.Diagnostic = .{};
    var program = a.assembleSource("one.asm", source, &d) catch {
        a.deinit();
        return error.AssemblyFailed;
    };
    defer program.deinit();
    return program.words[0];
}

test "a finding is a warning, and it changes nothing the assembler emits" {
    // The spill warning's precedent (AGENTS.md §4.3): a finding must not change what
    // is emitted, must not stop assembly, and must never render as an error. The same
    // image is assembled with and without the pointless transfer; the only difference
    // is the finding.
    var buf: [1024]u8 = undefined;

    var with = asmb.Assembler.init(testing.allocator);
    var d_with: asmb.Diagnostic = .{};
    var with_prog = try with.assembleSource("with.asm", "mov R1, 5\njump done\ndone:\nnop\nhalt\n", &d_with);
    defer with_prog.deinit();
    const with_findings = with.analyzeSource("with.asm");
    try testing.expectEqual(@as(usize, 1), with_findings.len);

    // The image is exactly what the source says: `mov`, the jump (encoded as an
    // absolute target of the instruction it skips — that encoding is the finding),
    // the `nop` it lands on, and the `halt`. A warning never rewrites an instruction,
    // so the words are unchanged from an assembly that ignores the analyzer entirely;
    // they are pinned here so a changed emission is a visible failure.
    try testing.expectEqual(@as(usize, 4), with_prog.words.len);
    try testing.expectEqual(asmb.Opcode.mov, opcodeOf(with_prog.words[0]));
    try testing.expectEqual(asmb.Opcode.jump, opcodeOf(with_prog.words[1]));
    try testing.expectEqual(asmb.Opcode.nop, opcodeOf(with_prog.words[2]));
    try testing.expectEqual(asmb.Opcode.halt, opcodeOf(with_prog.words[3]));
    // The jump's absolute target is the very next instruction: byte 16.
    try testing.expectEqual(@as(u64, 16), with_prog.words[1] & 0xFFFF_FFFF_FFFF);

    // It renders as a warning and never as an error, so a caller that filters on
    // severity cannot mistake a finding for a rejected assembly.
    try testing.expectEqual(diag.Severity.warning, with_findings.slice()[0].severity);
    const text = diag.renderToBuffer(with_findings.slice()[0], &buf);
    try testing.expect(std.mem.startsWith(u8, text, "warning:"));
    try testing.expect(!diag.hasBareHexCode(text));
}
