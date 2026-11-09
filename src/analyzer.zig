//! Static analysis of CLS64 programs: WARNINGS about a program that still
//! assembles and runs (the AGENTS.md §4.3 precedent — `Assembler.checkSpill`).
//!
//! Shape: `assembleSource` records one `Analyzed` row per emitted instruction —
//! nothing allocated per instruction — and `analyze` walks that table once, after
//! labels are resolved. Callers pass their own findings array, so `asm`, `run` and
//! `trace` print the same sentences for the same program.
//!
//! SOUNDNESS RULES, because a warning on a correct program is the same failure as a
//! confident wrong statement (AGENTS.md §4.2, docs/fidelity.md §3):
//!
//! 1. A finding is emitted only when the instruction list decides it. Where a rule
//!    would need dataflow this module does not have, the answer is "unknown" and
//!    nothing is reported — never a guess.
//! 2. The rules are purely syntactic and local: each looks at one instruction and,
//!    at most, the address its target resolves to, taken from the assembler's own
//!    label resolution rather than re-derived here. No rule reasons about which paths
//!    execute, so `call`, `ret`, `thread.*`, the §3.6 accelerators and data-dependent
//!    branch decisions cannot mislead any of them.
//! 3. Every rule was run over every CLS64 program in this repository while it was
//!    written; the tests at the bottom fail if a correct program is ever flagged.
//!
//! Deliberately NOT reported, each checked against a real program here:
//!   - "a label on an instruction that cannot be a transfer target". `loop: add
//!     R1, R1, 1` followed by `jump loop` is a correct loop (it halts after 41
//!     simulated instructions), so the shape says nothing about reachability. A
//!     first draft reported it and was deleted after it fired on that program.
//!   - "unreachable code after a jump or halt". `tests/crosscheck/p3_callret.asm`
//!     is correct and ends in `ret` then `jump`; the shape is also what `run-bin`
//!     callers use to reach cells of a flat image, and §2.3 makes that legal.
//!   - "a register is written and never read". The example kernels write `R9` for
//!     `compare` on every pass after the first, and `p2_aluimm.asm` writes R0..R9 and
//!     never reads them. Both are correct, so the rule as stated cries wolf.
//!   - "a sub-width write loses bits". §3.1's immediate is SIGN-extended, so
//!     `add R3, R3, -1` then `add R3.w, R3, 0` narrows correctly, and `load R0.l`
//!     reads an address whose contents the program cannot know.
//!   - "a loop that cannot terminate". A branch that always falls through is the
//!     only writable loop shape while §3.0.1 refuses to combine a label with an
//!     offset, so this rule would fire on correct code, and reaching it at all
//!     needs path reachability that `call`/`ret`/`thread.*` leave unknown.
//!   - "a `store` with no matching `load`". A program may legitimately exit by
//!     storing, and nothing in the encoding says which addresses a program owns.
//!   - "an instruction repeated verbatim elsewhere in the program". `matmul_8x8`
//!     repeats `mov R7, R4` / `mul R7, R7, 64` / `mul R10, R10, 8` / `add R7, R7,
//!     R10` in its `k_loop` and again in its store-address block; both copies are
//!     correct and the repeat is what the two identical address computations ARE.
//!     The rule fired thirteen times on correct programs and was deleted.
//!   - "a register written and then overwritten by the very next instruction".
//!     `tests/crosscheck/p1_zeroext.asm` is a chain of exactly that — `mov R0,
//!     134217727` then `mov R0.w, 65535` then `mov R0.l, ...` then `mov R0.b, ...` —
//!     and it is the zero-extension cross-check program, whose whole point is to
//!     write R0 five times in a row. The shape says nothing about whether the
//!     intermediate values mattered.
//!   - "a write to R0 is a write to a hardwired zero register". R0 is an ordinary
//!     general-purpose register in this architecture (§2.1 lists ZERO as a separate
//!     system register, expressed by OMITTING a write target, §4). `p1_zeroext.asm`
//!     and `p2_aluimm.asm` both write R0 as their destination and are correct.
//!   - "a control transfer to an address outside this source". `tests/mulout_e2e.sh`
//!     deliberately assembles `jump 400000` as its mismatch trap: leaving the image
//!     faults loudly, which is what that program WANTS. §2.3 makes a flat image's
//!     cells addressable, so an out-of-range target is a legal program shape.
//!   - "a `branch` that tests a status `compare` cannot produce near it". §3.2.1's
//!     `compare` yields EQUAL/LESS/GREATER, so UNSIGNED_LESS/UNSIGNED_GREATER look
//!     unreachable; but the tested register may be written by any earlier
//!     instruction on any path, and `count_rises` legitimately pairs a `compare`
//!     with `[GREATER]` — adjacent in the listing, which is NOT adjacent at run
//!     time, because `call`, `ret`, `jump` and `thread.*` all move control.
//!   - "a `select` whose arms are one register", "a `field.extract` at offset 0
//!     width 64" and "a `field.insert` at offset 0 width 64" ARE reported: each is
//!     decided by the instruction word alone, and none appears in any program this
//!     repository ships. They are the first three rules below.

const std = @import("std");
const diag = @import("diagnostics.zig");
const asmb = @import("assembler.zig");

const Diagnostic = diag.Diagnostic;
const Opcode = asmb.Opcode;

/// §1: every instruction is exactly 8 bytes, so an index times this is an address.
const insn_bytes: u64 = asmb.insn_bytes;

/// Upper bound on findings from one program. Fixed at assembly time, so analysis
/// allocates nothing (AGENTS.md §4.1). More real findings than this are reported
/// as truncated, never as a complete list.
pub const max_findings = 24;

/// One emitted instruction, recorded during assembly: what it is and where it came
/// from. `text` slices the caller's source buffer, which outlives the `Program`.
pub const Analyzed = struct {
    insn: asmb.Instruction,
    /// 1-based source line the instruction was written on.
    line: usize,
    /// The instruction's own source text, quoted back in a finding.
    text: []const u8,
    /// The absolute byte address the target resolves to. For `branch`, §3.0.1
    /// makes the signed offset relative to the branch itself. Written by the
    /// assembler's label-patching pass for every control transfer; 0 otherwise.
    target: u64 = 0,
};

pub const Findings = struct {
    items: [max_findings]Diagnostic = undefined,
    len: usize = 0,
    /// True when a real finding had to be dropped because `max_findings` was
    /// reached. The CLI says so rather than presenting the list as complete.
    truncated: bool = false,

    pub fn slice(self: *const Findings) []const Diagnostic {
        return self.items[0..self.len];
    }
};

/// Runs every rule over the instruction table.
pub fn analyze(insns: []const Analyzed, file: []const u8) Findings {
    var out = Findings{};
    for (insns, 0..) |a, i| {
        transferToNext(a, i, file, &out);
        // Every rule here reads ONE instruction and nothing else, so none of them
        // needs a second pass, a worklist, or any state that outlives this loop.
        degenerateSelect(a, file, &out);
        degenerateField(a, file, &out);
    }
    return out;
}

fn add(out: *Findings, d: Diagnostic) void {
    if (out.len == out.items.len) {
        out.truncated = true;
        return;
    }
    out.items[out.len] = d;
    out.len += 1;
}

/// A transfer whose target IS the instruction after it. Both forms assemble: a
/// `jump` to the next address still moves `PC`, and a `branch` with an offset of
/// one instruction (`8`, §3.0.1) takes its edge to its own fall-through. `len` is
/// not needed: the next address is well defined even past the last instruction,
/// where the transfer simply ends the program (§2.3).
fn transferToNext(a: Analyzed, i: usize, file: []const u8, out: *Findings) void {
    switch (a.insn.opcode) {
        .jump => {
            // Applies to a label and to a literal alike: the assembler resolves a
            // label to an absolute address before this runs, so both are just
            // addresses here. A jump to a label written one line too low is the
            // usual form of this mistake.
            if (a.target != indexAddress(i + 1)) return;
            add(out, diag.transferToNext(
                file,
                a.line,
                a.text,
                "no control transfer at all, because this one lands on the instruction that already follows it",
            ));
        },
        .branch => {
            // A labelled branch resolves to the same absolute address a literal
            // offset does, so both are compared in addresses rather than in the
            // immediate: §3.1 sign-extends imm28, so `-1` means -1 and not `8 - 1`.
            if (a.target != indexAddress(i + 1)) return;
            add(out, diag.transferToNext(
                file,
                a.line,
                a.text,
                "the branch to keep the branch it is testing, or to fall through with an offset of zero, because an offset of one instruction only transfers when the branch already would have fallen through",
            ));
        },
        else => {},
    }
}

fn indexAddress(index: usize) u64 {
    return @as(u64, @intCast(index)) * insn_bytes;
}

/// A `select` whose two arms name the SAME register.
///
/// §3.2.2 selects bitwise: `result = (true & mask) | (false & ~mask)`. When both
/// arms are one register every bit of the result comes from it whichever way the
/// mask falls, so the instruction equals a `mov` of that register and the status
/// register it tests cannot affect anything the program does. `select.zig`'s
/// `select()` is the model: with `true_value == false_value` the two masked halves
/// are complementary parts of one 64-bit value, so their union is that value.
///
/// Only the register INDICES are compared, which is exactly what the instruction
/// word carries. Two different instructions that would compute the same value are
/// not this: the rule needs the same register named twice, not an equality argument.
fn degenerateSelect(a: Analyzed, file: []const u8, out: *Findings) void {
    if (a.insn.opcode != .select) return;
    if (a.insn.true_reg != a.insn.false_reg) return;
    add(out, diag.selectSameArms(file, a.line, a.text));
}

/// `field.extract` at offset 0 width 64, and `field.insert` at offset 0 width 64.
///
/// §3.3 defines `extract` as `(rs1 >> offset) & mask(width)` and `insert` as `rs1`
/// with `width` bits of `src2` placed at `offset`. At offset 0 the mask is the whole
/// 64-bit word (§3.3.1 permits width 64, and `field.zig`'s `mask(64)` is all ones),
/// so `extract` returns its source unchanged and `insert` clears every bit of its
/// base before writing, returning the inserted value. Both are decided by the
/// instruction word alone; neither reads anything the analyzer cannot see.
///
/// Width 64 at a NON-zero offset cannot be assembled — §3.3.1 refuses `offset +
/// width > 64` — so offset 0 is the only place this shape exists.
fn degenerateField(a: Analyzed, file: []const u8, out: *Findings) void {
    if (a.insn.field_offset != 0 or a.insn.field_width != 64) return;
    switch (a.insn.opcode) {
        .field_extract => add(out, diag.extractIdentity(file, a.line, a.text)),
        .field_insert => add(out, diag.insertIdentity(file, a.line, a.text)),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Tests
//
// The NEGATIVE cases are the important ones: this module's whole claim is that a
// finding is never raised on a correct program. The last test runs the rules over
// every CLS64 program this repository ships and fails if one is flagged.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Assembles `source` and returns the findings, rendering each one into `bufs`.
const Rendered = struct {
    findings: Findings,
    texts: [max_findings][]const u8 = undefined,

    fn check(self: *Rendered, needle: []const u8) bool {
        for (self.texts[0..self.findings.len]) |t| {
            if (std.mem.indexOf(u8, t, needle) != null) return true;
        }
        return false;
    }
};

/// An arena that outlives the Program, so the findings' slices stay valid. The
/// caller owns nothing: `analyzeSource` allocates nothing beyond what assembly did.
fn run(name: []const u8, source: []const u8, r: *Rendered, bufs: *[max_findings][1024]u8) !void {
    const alloc = testing.allocator;
    var a = asmb.Assembler.init(alloc);
    var d: asmb.Diagnostic = .{};
    // On success the arena MOVES into the Program (docs/HANDOFF.md §4): free exactly
    // one of the two, or the same nodes are freed twice and the test aborts.
    var prog = a.assembleSource(name, source, &d) catch {
        a.deinit();
        return error.AssemblyFailed;
    };
    defer prog.deinit();
    r.findings = a.analyzeSource(name);
    for (r.findings.slice(), 0..) |f, i| r.texts[i] = diag.renderToBuffer(f, &bufs[i]);
}

test "a jump to the next instruction is reported, as a warning that still assembles" {
    var r: Rendered = undefined;
    var bufs: [max_findings][1024]u8 = undefined;
    try run("t.asm", "mov R1, 5\njump done\ndone:\nnop\nhalt\n", &r, &bufs);

    try testing.expectEqual(@as(usize, 1), r.findings.len);
    const text = r.texts[0];
    try testing.expect(std.mem.startsWith(u8, text, "warning:"));
    try testing.expect(std.mem.indexOf(u8, text, "line 2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "jump done") != null);
    try testing.expect(std.mem.indexOf(u8, text, "transfers to the instruction immediately after itself") != null);
    // WHAT (the transfer), WHERE (the line) and WHY (it changes nothing) are all
    // present, and no bare hex code appears (AGENTS.md §4.2).
    try testing.expect(std.mem.indexOf(u8, text, "without changing what the program does") != null);
    try testing.expect(!diag.hasBareHexCode(text));
}

test "a branch whose only edge lands on its own fall-through is reported" {
    var r: Rendered = undefined;
    var bufs: [max_findings][1024]u8 = undefined;
    try run("t.asm", "mov R1, 14\nbranch R1, [EQUAL], 8\nnop\nhalt\n", &r, &bufs);

    try testing.expectEqual(@as(usize, 1), r.findings.len);
    try testing.expect(std.mem.indexOf(u8, r.texts[0], "branch R1, [EQUAL], 8") != null);
    try testing.expect(std.mem.indexOf(u8, r.texts[0], "line 2") != null);
}

test "NEGATIVE: a loop header and its back edge are not reported" {
    // The ordinary counted loop, in both placements of the label. `jump loop` goes
    // to the label's address, which is NOT the instruction after the jump, so there
    // is nothing to report. A first draft of this module reported the inline form
    // and was deleted: this program halts after 41 simulated instructions.
    var r: Rendered = undefined;
    var bufs: [max_findings][1024]u8 = undefined;
    try run(
        "t.asm",
        "mov R1, 0\nloop:\nadd R1, R1, 1\ncompare R2, R1, 10\nbranch R2, [EQUAL], done\njump loop\ndone:\nhalt\n",
        &r,
        &bufs,
    );
    try testing.expectEqual(@as(usize, 0), r.findings.len);

    var r2: Rendered = undefined;
    var bufs2: [max_findings][1024]u8 = undefined;
    try run(
        "t.asm",
        "mov R1, 0\nloop: add R1, R1, 1\ncompare R2, R1, 10\nbranch R2, [EQUAL], done\njump loop\ndone:\nhalt\n",
        &r2,
        &bufs2,
    );
    try testing.expectEqual(@as(usize, 0), r2.findings.len);
}

test "NEGATIVE: a call, a ret and a jump over padding are not reported" {
    // tests/crosscheck/p3_callret.asm, verbatim. It is correct, and every one of
    // its transfers goes somewhere other than the instruction after it.
    var r: Rendered = undefined;
    var bufs: [max_findings][1024]u8 = undefined;
    try run(
        "p3_callret.asm",
        "mov R1, 9\ncall 40\nhalt\nnop\nnop\nret\njump 64\nnop\nhalt\n",
        &r,
        &bufs,
    );
    try testing.expectEqual(@as(usize, 0), r.findings.len);
}

test "NEGATIVE: a negative branch offset is not confused with one instruction" {
    // §3.1 sign-extends imm28, so -1 is a byte offset of -1 (backwards), not 7. The
    // assembler refuses a misaligned branch offset, so what is checked here is that
    // the SIGNED value never compares equal to the 8 that means "the next word".
    var r: Rendered = undefined;
    var bufs: [max_findings][1024]u8 = undefined;
    try run("t.asm", "mov R1, 0\nback:\nadd R1, R1, 1\nbranch R1, [LESS], back\nhalt\n", &r, &bufs);
    try testing.expectEqual(@as(usize, 0), r.findings.len);
}

test "NEGATIVE: no finding on any CLS64 program this repository ships" {
    // The claim this module exists to keep is that a finding is never raised on a
    // correct program. Every CLS64 program in the repository is assembled here and
    // must produce zero findings: the example kernels (src/examples.zig), the
    // four cross-check programs (tests/crosscheck/), and the programs the shell
    // scripts in tools/ drive. A regression in any rule shows up as the name below.
    const cases = [_]struct { name: []const u8, src: []const u8 }{
        // tests/crosscheck/p1_zeroext.asm
        .{ .name = "p1_zeroext", .src = "mov R0, 134217727\nmov R0.w, 65535\nmov R0.l, 134217727\nmov R0.b, 255\nmov R0, -1\nmov R0.w, 4660\nhalt\n" },
        // tests/crosscheck/p2_aluimm.asm
        .{ .name = "p2_aluimm", .src = "mov R0, 100\nadd R1, R0, 50\nsub R2, R1, 25\nmul R3, R2, 4\nand R4, R3, 255\nor R5, R4, 256\nxor R6, R5, 15\nshl R7, R6, 2\nshr R8, R7, 1\nmov R9, -1\nhalt\n" },
        // tests/crosscheck/p4x.asm
        .{ .name = "p4x", .src = "mov R1, 256\nstream.add R0, [R1]+4, R0.w\nmov R2, 10\nstream.add R3, [R1]+8, R3.l\nhalt\n" },
        // tools/accel_e2e.sh
        .{ .name = "fnv1a", .src = "mov R2, 0x1000\ncodec.fnv1a R1, R2, count=3\nhalt\n" },
        .{ .name = "fnv1a_4", .src = "mov R2, 0x1000\ncodec.fnv1a R1, R2, count=4\nhalt\n" },
        .{ .name = "identity", .src = "mov R1, 0x1000\nmov R2, 2\nmatrix.identity R1, R2\nhalt\n" },
        .{ .name = "misaligned", .src = "mov R1, 0x1002\nmov R2, 2\nmatrix.identity R1, R2\nhalt\n" },
        .{ .name = "compress", .src = "mov R2, 0x1000\ncodec.compress R1, R2, count=8\nhalt\n" },
        .{ .name = "decompress", .src = "codec.decompress R1, R2, count=8\nhalt\n" },
        .{ .name = "matrix_mul", .src = "matrix.mul R1, R2, R3\nhalt\n" },
        // The syntax contract's own examples (docs/isa-encoding.md, assembler.zig header).
        .{ .name = "stream_chunk", .src = "stream.add R0, [R1]+CHUNK_SIZE, R2\nhalt\n" },
        .{ .name = "compare_select", .src = "compare R0, R1 -> R2\nselect R3, R2, [EQUAL], R4, R5\nhalt\n" },
        .{ .name = "field", .src = "field.extract R0, R1, offset=12, width=3\nfield.insert R2, R1, offset=4, width=4, R3\nhalt\n" },
        .{ .name = "setp", .src = "stream.setp R1, -16\nhalt\n" },
        .{ .name = "cap", .src = "cap.load R2, R3\ncap.store R3, R2\ncap.check R0, R1\nhalt\n" },
        .{ .name = "thread", .src = "thread.spawn T0, R1\nthread.join T2\nthread.yield\nhalt\n" },
        .{ .name = "stream_widths", .src = "stream.copy R0.b, [R1]+8\nstream.fill R0.w, [R1]+2\nhalt\n" },
    };

    var total: usize = 0;
    for (cases) |c| {
        var r: Rendered = undefined;
        var bufs: [max_findings][1024]u8 = undefined;
        try run(c.name, c.src, &r, &bufs);
        if (r.findings.len != 0) {
            std.debug.print("FALSE POSITIVE on the repository's own program \"{s}\":\n", .{c.name});
            for (r.texts[0..r.findings.len]) |t| std.debug.print("  {s}\n", .{t});
        }
        total += r.findings.len;
    }
    try testing.expectEqual(@as(usize, 0), total);
}
