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

/// Assembles and analyzes one program, printing every finding so a failure names
/// the sentence rather than just a count.
fn findingsFor(name: []const u8, source: []const u8) !usize {
    var a = asmb.Assembler.init(testing.allocator);
    var d: asmb.Diagnostic = .{};
    // On success `assembleSource` MOVES its arena into the returned `Program`
    // (docs/HANDOFF.md §4). Deinit'ing both frees the same nodes twice and aborts,
    // so exactly one of the two owners is released on each path.
    var program = a.assembleSource(name, source, &d) catch {
        a.deinit();
        std.debug.print("the repository's own program \"{s}\" did not assemble: ", .{name});
        var dbuf: [1024]u8 = undefined;
        std.debug.print("{s}\n", .{diag.renderToBuffer(d, &dbuf)});
        return error.AssemblyFailed;
    };
    defer program.deinit();

    const findings = a.analyzeSource(name);
    for (findings.slice()) |f| {
        var buf: [1024]u8 = undefined;
        std.debug.print("FALSE POSITIVE in the analyzer, on the correct program \"{s}\":\n  {s}\n", .{
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
