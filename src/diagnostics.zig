//! Celeris-64 diagnostics engine.
//!
//! AGENTS.md §4.2 and docs/isa-encoding.md §7: no user-visible failure is ever a
//! bare hexadecimal code. Every failure is a *sentence* that names the
//! instruction, the offending operand, and what was expected.
//!
//! Diagnostics are values, not exceptions: callers return a `Diagnostic`
//! through the normal call path and the CLI prints it.

const std = @import("std");

pub const Severity = enum {
    /// The input cannot be encoded or executed. Rendering starts with "error:".
    err,
    /// The input is accepted, but the software is doing something the mandate
    /// asks us to flag. Rendering starts with "warning:". See AGENTS.md §4.3
    /// (register spilling).
    warning,
};

/// How a user-visible number is written. This exists for one reason: to make it
/// impossible to emit a bare hex code by accident. `enum` is the only variant
/// that may print `0x...`, and it is always inside a sentence that also names
/// what the value is.
pub const Value = union(enum) {
    reg: u8,
    word: u64,
    number: u64,
    signed: i64,
    /// An opcode / status enum / thread slot: worth showing in both bases.
    opcode: u64,
    width: u8,
    text: []const u8,

    pub fn write(self: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .reg => |r| try writeReg(w, r),
            .word => |v| try w.print("0x{x:0>16}", .{v}),
            .number => |v| try w.print("{d}", .{v}),
            .signed => |v| try w.print("{d}", .{v}),
            .opcode => |v| try w.print("0x{x:0>2} ({d})", .{ v, v }),
            .width => |bits| try w.print("{d} bits", .{bits}),
            .text => |t| try w.writeAll(t),
        }
    }
};

/// One operand of the instruction that failed, plus how far along the parser
/// got. `text` is the *offending text* the acceptance criteria demand.
pub const Operand = struct {
    /// 1-based position in the operand list.
    index: usize = 1,
    /// What the operand is, e.g. "destination register".
    name: []const u8 = "operand",
    /// The literal source text, e.g. "R99" or "R0.!". Never invented.
    text: []const u8 = "",
    present: bool = true,
};

/// The one place diagnostic text is produced. Every field has a default so a
/// call site only fills in what it actually knows; nothing is ever printed as a
/// raw number without a label in front of it.
pub const Diagnostic = struct {
    severity: Severity = .err,
    /// Optional source file name, printed before the line number.
    file: ?[]const u8 = null,
    /// 1-based source line. Null when the diagnostic is not attached to text.
    line: ?usize = null,
    /// 1-based source column of the offending token.
    column: ?usize = null,
    /// The program counter the failure was observed at. A runtime fault has a
    /// PC, not a source line; the two are distinct and are labelled distinctly.
    pc: ?u64 = null,
    /// The activity the tool was engaged in, as a *location* phrase:
    /// "assembling this line", "decoding this word". Used after "while".
    stage: []const u8 = "processing",
    /// The activity as a *verb phrase*, for the slot "could not be <action>":
    /// "decoded", "executed". Kept separate from `stage` because the two need
    /// different grammar; one field cannot serve both without producing
    /// sentences like "could not be decoding this word".
    action: ?[]const u8 = null,
    /// Total size of an input image, in bytes, when a size check failed.
    image_bytes: ?usize = null,
    /// Bytes left over past the last whole instruction word.
    image_remainder: ?usize = null,
    /// The instruction mnemonic, e.g. "stream.add".
    mnemonic: ?[]const u8 = null,
    /// The offending operand.
    operand: ?Operand = null,
    /// The whole offending line or value, quoted in the sentence.
    offending: ?[]const u8 = null,
    /// The raw instruction word, when a decode or execute step failed.
    word: ?u64 = null,
    /// Admitted total register demand, for spill warnings.
    registers_used: ?usize = null,
    /// R0-R11, the architectural GPR budget (AGENTS.md §4.3).
    registers_available: ?usize = null,
    /// What the tool wanted to find.
    expected: ?[]const u8 = null,
    /// Which operands *are* legal here.
    detail: ?[]const u8 = null,
    /// The last successfully parsed token, so the user knows how far it got.
    after: ?[]const u8 = null,
    /// A finding from src/analyzer.zig whose own sentence needs neither a number
    /// nor a quoted instruction: WHAT was found and WHY it matters.
    finding: ?[]const u8 = null,

    pub fn render(self: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(switch (self.severity) {
            .err => "error:",
            .warning => "warning:",
        });

        // Location clause: "at demo.asm, line 3, column 17: while assembling this line".
        // `stage` is a location phrase; it is never used as a verb.
        //
        // Only open an "at" clause when a location VALUE exists. A decoder is a pure
        // function of the word, so it cannot know the PC and leaves it null; emitting
        // a bare "at" there rendered as "at  while decoding...", which reads as a typo.
        const has_location = self.file != null or self.line != null or
            self.column != null or self.pc != null;

        // A finding (src/analyzer.zig) is not a failure to name an operand, so it
        // renders as its own sentence: the location, then WHAT was found. Without
        // this branch `finding` would be spliced onto "...the input", which reads
        // as a parse error rather than as a finding.
        if (self.finding) |f| {
            if (has_location) try w.writeAll(" at ");
            var wrote_any = false;
            if (self.file) |file| {
                try w.writeAll(file);
                wrote_any = true;
            }
            if (self.line) |ln| {
                if (wrote_any) try w.writeAll(", ");
                try w.print("line {d}", .{ln});
                wrote_any = true;
            }
            if (self.pc) |address| {
                if (wrote_any) try w.writeAll(", ");
                try w.print("PC {d}", .{address});
            }
            // The quoted text, when there is one, names WHICH thing the finding is
            // about: "at prog.asm, line 5 the instruction \"jump loop\" transfers
            // to the instruction immediately after itself".
            if (self.offending) |text| {
                try w.print(", where the instruction \"{s}\" {s}", .{ text, f });
            } else {
                try w.print(", where it {s}", .{f});
            }
            try w.writeAll(".");
            if (self.expected) |e| try w.print(" Expected {s}.", .{e});
            if (self.detail) |d| try w.print(" {s}", .{d});
            return;
        }

        if (has_location or self.stage.len != 0) {
            if (has_location) {
                try w.writeAll(" at ");
                var wrote_any = false;
                if (self.file) |f| {
                    try w.writeAll(f);
                    wrote_any = true;
                }
                if (self.line) |ln| {
                    if (wrote_any) try w.writeAll(", ");
                    try w.print("line {d}", .{ln});
                    wrote_any = true;
                }
                if (self.column) |c| {
                    if (wrote_any) try w.writeAll(", ");
                    try w.print("column {d}", .{c});
                    wrote_any = true;
                }
                if (self.pc) |address| {
                    if (wrote_any) try w.writeAll(", ");
                    // "PC" is the architecture's own name for this register
                    // (spec §2.1), so it is the clearest label for a reader.
                    try w.print("PC {d}", .{address});
                    wrote_any = true;
                }
            }
            if (self.stage.len != 0) {
                if (has_location) try w.writeAll(":");
                try w.print(" while {s}", .{self.stage});
            }
        }

        if (self.registers_used) |used| {
            const avail = self.registers_available orelse 12;
            try w.print(
                " the program holds {d} live values but Celeris-64 has only {d} general-purpose registers (R0 through R11)",
                .{ used, avail },
            );
        } else if (self.image_bytes) |bytes| {
            try w.print(
                " the image is {d} bytes long, which is {d} bytes past the last whole 8-byte instruction",
                .{ bytes, self.image_remainder orelse 0 },
            );
        } else if (self.word) |word| {
            // `action` is a verb phrase; fall back to a neutral one rather than
            // splicing `stage` (a location phrase) into this slot.
            try w.print(
                " the instruction word 0x{x:0>16} could not be {s}",
                .{ word, self.action orelse "decoded" },
            );
            // When an operand is also named, this clause must END rather than
            // run into the operand clause below, or the sentence reads
            // "...could not be decoded operand 3 (...)".
            if (self.operand != null) try w.writeAll(", because");
        } else if (self.mnemonic) |m| {
            try w.print(" the instruction \"{s}\"", .{m});
        } else {
            try w.writeAll(" the input");
        }

        if (self.operand) |op| {
            try w.print(" operand {d} ({s})", .{ op.index, op.name });
            if (op.present and op.text.len != 0) {
                try w.print(" is \"{s}\"", .{op.text});
                try w.writeAll(", which is not valid here");
            } else {
                try w.writeAll(" is missing");
            }
        } else if (self.offending) |bad| {
            try w.print(" cannot be read from \"{s}\"", .{bad});
        }

        if (self.after) |a| try w.print(", after \"{s}\"", .{a});

        try w.writeAll(".");
        if (self.expected) |e| try w.print(" Expected {s}.", .{e});
        if (self.detail) |d| try w.print(" {s}", .{d});
    }

    /// Convenience for tests and for callers that print to stderr directly.
    pub fn format(self: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.render(w);
    }
};

/// Registers are named, never numbered: "R99" is the offending text, but a
/// legal index renders as its architectural name.
pub fn writeReg(w: *std.Io.Writer, index: u8) std.Io.Writer.Error!void {
    switch (index) {
        0...11 => try w.print("R{d}", .{index}),
        12 => try w.writeAll("SP"),
        13 => try w.writeAll("LR"),
        14 => try w.writeAll("PC"),
        15 => try w.writeAll("FLAGS"),
        else => try w.print("reserved register index {d} (valid indices are R0 through R11, then SP at 12, LR at 13, PC at 14 and FLAGS at 15)", .{index}),
    }
}

/// Renders a diagnostic into a caller-provided buffer. Used by the CLI and by
/// tests that assert on the exact sentence.
pub fn renderToBuffer(diag: Diagnostic, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    diag.render(&w) catch {};
    return w.buffered();
}

/// The acceptance test in tests/contract.md P2.1 asks for a check that the
/// rendered text contains no standalone hex-only error token. A value is
/// "bare" when a `0x` run is *not* introduced by a label: "error: 0x00000005"
/// is bare, while "opcode 0x2A (42) is not defined" is not, because the run is
/// preceded by a word naming it.
pub fn hasBareHexCode(text: []const u8) bool {
    // The severity prefix is not a label: "error: 0x1F" names nothing.
    const body = if (std.mem.startsWith(u8, text, "error:"))
        text["error:".len..]
    else if (std.mem.startsWith(u8, text, "warning:"))
        text["warning:".len..]
    else
        text;

    var i: usize = 0;
    while (std.mem.indexOfPos(u8, body, i, "0x")) |at| {
        if (!isLabelled(body, at)) return true;
        i = at + 2;
    }
    return false;
}

/// True when the `0x` run at `at` is preceded by a word that names it, e.g.
/// "word 0x…", "opcode 0x…", "address 0x…", or by punctuation directly after
/// such a word ("(0x…)", "= 0x…"). The point is that a reader can tell what the
/// number means, which is exactly what AGENTS.md §4.2 requires.
fn isLabelled(text: []const u8, at: usize) bool {
    var k = at;
    // Step back over spaces and any single punctuation character.
    while (k > 0) {
        const c = text[k - 1];
        if (c == ' ' or c == '\t' or c == '(' or c == '[' or c == '=' or c == ':' or c == ',') {
            k -= 1;
        } else break;
    }
    if (k == 0) return false;
    // The preceding token must be a word (letters) to count as a label.
    const word_end = k;
    while (k > 0 and isTokenChar(text[k - 1])) : (k -= 1) {}
    return k != word_end;
}

fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// -- constructors for the failures the tooling actually hits ------------------

/// v1.17 labels: the same name defined twice.
pub fn duplicateLabel(line: usize, label: []const u8, file: []const u8) Diagnostic {
    return .{
        .line = line,
        .file = file,
        .stage = "collecting labels",
        .offending = label,
        .expected = "a label name that is not already defined in this program, because a second definition would make every reference to it ambiguous",
        .detail = "The label was rejected rather than the later definition silently winning; assembly stopped here.",
    };
}

/// v1.17 labels: a referenced name that is never defined.
pub fn unknownLabel(line: usize, label: []const u8, file: []const u8) Diagnostic {
    return .{
        .line = line,
        .file = file,
        .stage = "resolving labels",
        .offending = label,
        .expected = "the name of a label defined somewhere in this program, written as \"name:\" on a line of its own or before an instruction",
        .detail = "The reference was not resolved to address 0 or to anything else; assembly stopped here.",
    };
}

/// v1.17 labels: a branch whose target is further away than the 28-bit signed
/// offset can reach.
pub fn labelOutOfRange(line: usize, label: []const u8, delta: i64, file: []const u8) Diagnostic {
    _ = delta;
    return .{
        .line = line,
        .file = file,
        .stage = "resolving labels",
        .offending = label,
        .expected = "a target within 134217727 bytes either side of the branch, because a branch offset is a signed 28-bit field",
        .detail = "The branch was not encoded; a truncated offset would send control somewhere unintended, so assembly stopped here.",
    };
}

pub fn badMnemonic(line: usize, text: []const u8) Diagnostic {
    return .{
        .line = line,
        .stage = "assembling this line",
        .offending = text,
        .expected = "an instruction mnemonic from the Celeris-64 opcode map, such as \"add\", \"stream.add\", \"compare\", \"select\" or \"field.extract\"",
        .detail = "The line was not silently skipped; assembly stopped here.",
    };
}

pub fn badOperand(
    line: usize,
    mnemonic: []const u8,
    index: usize,
    name: []const u8,
    text: []const u8,
    expected: []const u8,
) Diagnostic {
    return .{
        .line = line,
        .stage = "assembling this line",
        .mnemonic = mnemonic,
        .operand = .{ .index = index, .name = name, .text = text },
        .expected = expected,
    };
}

pub fn missingOperand(
    line: usize,
    mnemonic: []const u8,
    index: usize,
    name: []const u8,
    after: []const u8,
    expected: []const u8,
) Diagnostic {
    return .{
        .line = line,
        .stage = "assembling this line",
        .mnemonic = mnemonic,
        .operand = .{ .index = index, .name = name, .present = false },
        .after = after,
        .expected = expected,
    };
}

pub fn spill(used: usize) Diagnostic {
    return .{
        .severity = .warning,
        .stage = "assembling this program",
        .registers_used = used,
        .registers_available = 12,
        .expected = "the program to reuse registers, to keep values in memory, or to process the work in batches with the stream engine so fewer values are live at once",
        .detail = "Celeris-64 has no spill-and-reload hardware; every spilled value costs an explicit memory round trip (AGENTS.md §4.3).",
    };
}

/// A static-analysis finding (src/analyzer.zig). Warnings, like `spill`: the
/// program still assembles and runs, and the sentence says WHY the pattern is
/// worth knowing about rather than forbidding it.
///
/// A transfer that lands on the instruction after itself. Both forms assemble: a
/// `jump` to the next address still moves PC, and a `branch` with an offset of one
/// instruction takes its edge to its own fall-through.
pub fn transferToNext(file: []const u8, line: usize, text: []const u8, expected: []const u8) Diagnostic {
    return .{
        .severity = .warning,
        .file = file,
        .line = line,
        .finding = "transfers to the instruction immediately after itself",
        .offending = text,
        .expected = expected,
        .detail = "It changes control flow without changing what the program does, which is usually a label placed one line too low or a jump meant for somewhere else.",
    };
}

/// A label written on the line of an instruction that cannot be a transfer target.
/// `text` is the whole line (the label and its instruction), because that is what
/// the reader has to look at to see the problem.
pub fn lostLabel(file: []const u8, line: usize, label: []const u8, expected: []const u8) Diagnostic {
    return .{
        .severity = .warning,
        .file = file,
        .line = line,
        .finding = "is a label that no jump, call or branch can reach",
        .offending = label,
        .expected = expected,
        .detail = "A label names an address, and the only instructions that read one are jump, call and branch (docs/isa-encoding.md §3.0), so this label names somewhere no transfer can land.",
    };
}

/// Truncated flat image: a whole number of 64-bit instruction words is
/// required, because instruction width is fixed (docs/isa-encoding.md §1).
pub fn truncatedImage(file: []const u8, bytes: usize, remainder: usize) Diagnostic {
    return .{
        .file = file,
        .stage = "loading this binary image",
        .expected = "the image size to be a whole number of 8-byte instruction words, because every Celeris-64 instruction is exactly 64 bits",
        .detail = "The image holds a partial instruction at the end, so it is truncated or misaligned and cannot be executed.",
        .image_bytes = bytes,
        .image_remainder = remainder,
    };
}

test "diagnostics render as full sentences and name the operand" {
    var buf: [512]u8 = undefined;
    const d = badOperand(3, "add", 2, "first source register", "R99", "a register from R0 through R11, or SP, LR, PC, FLAGS");

    const text = renderToBuffer(d, &buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "error:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "line 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "operand 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "R99") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "add") != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "."));
    try std.testing.expect(!hasBareHexCode(text));
}

test "no diagnostic constructor emits a bare hex token" {
    var buf: [1024]u8 = undefined;
    const cases = [_]Diagnostic{
        badMnemonic(1, "frobnicate R0, R1"),
        badOperand(7, "field.extract", 3, "width", "width=0", "a width from 1 to 64"),
        missingOperand(2, "select", 4, "match value", "select R3, R2", "a match value in square brackets, such as [EQUAL]"),
        spill(13),
        .{ .stage = "decoding this word", .action = "decoded", .word = 0xDEADBEEFCAFEF00D },
        .{ .stage = "executing this instruction", .action = "executed", .word = 0x0000000000000042, .expected = "an opcode defined in the instruction map" },
        // src/analyzer.zig's findings. A finding carries a sentence instead of a
        // value, and must be as free of bare hex as an error is.
        transferToNext("t.asm", 3, "jump done", "no control transfer at all, because this one lands on the instruction that already follows it"),
        lostLabel("t.asm", 4, "copy: mov R0, R1", "a label on its own line above a jump, call or branch"),
    };
    for (cases) |c| {
        const text = renderToBuffer(c, &buf);
        try std.testing.expect(text.len > 0);
        try std.testing.expect(std.mem.endsWith(u8, text, "."));
        try std.testing.expect(!hasBareHexCode(text));
    }
}

test "hex values are always introduced by a label" {
    var buf: [256]u8 = undefined;
    const d = Diagnostic{ .stage = "decoding this word", .action = "decoded", .word = 0x123456789ABCDEF0 };
    const text = renderToBuffer(d, &buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "instruction word 0x123456789abcdef0") != null);
    try std.testing.expect(!hasBareHexCode(text));
}

test "spill warning is a sentence naming the register budget" {
    var buf: [512]u8 = undefined;
    const text = renderToBuffer(spill(14), &buf);
    try std.testing.expect(std.mem.startsWith(u8, text, "warning:"));
    try std.testing.expect(std.mem.indexOf(u8, text, "14 live values") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "12 general-purpose registers") != null);
    try std.testing.expect(!hasBareHexCode(text));
}

test "bare hex detector catches a code-only message and ignores labelled ones" {
    try std.testing.expect(hasBareHexCode("0x00000005"));
    try std.testing.expect(hasBareHexCode("error: 0x1F"));
    try std.testing.expect(!hasBareHexCode("error: opcode 0x2A (42) is not defined."));
    try std.testing.expect(!hasBareHexCode("error: nothing to see"));
}

test "value renderer names registers and widths" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try (Value{ .reg = 12 }).write(&w);
    try std.testing.expectEqualStrings("SP", w.buffered());
}

test "rendered sentences are grammatical, not just hex-free" {
    // The verifier's falsification caught a real defect here: `stage` is a
    // location phrase ("while decoding this word") and was being spliced into
    // the verb slot "could not be {stage}", producing
    // "could not be decoding this word". Grammar is part of "plain language".
    var buf: [1024]u8 = undefined;
    const cases = [_]Diagnostic{
        .{ .stage = "decoding this word", .action = "decoded", .word = 0xDEAD_BEEF },
        .{ .stage = "executing this instruction", .action = "executed", .word = 0x42 },
        .{ .stage = "executing a divide", .action = "executed", .word = 0x13, .operand = .{ .index = 2, .name = "divisor", .text = "0" } },
        .{ .stage = "decoding this word", .word = 0x99 }, // action omitted: neutral fallback
    };
    for (cases) |c| {
        const text = renderToBuffer(c, &buf);
        // "could not be decoding" / "could not be executing" are the defects.
        try std.testing.expect(std.mem.indexOf(u8, text, "could not be decoding") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "could not be executing") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "could not be assembling") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "could not be loading") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, " could not be ") != null);
        try std.testing.expect(!hasBareHexCode(text));
    }
}

test "a runtime fault labels its program counter as PC, not as a source line" {
    var buf: [512]u8 = undefined;
    const d = Diagnostic{
        .stage = "executing this instruction",
        .action = "executed",
        .word = 0xFE00,
        .pc = 24,
        .expected = "an opcode defined in the instruction map",
    };
    const text = renderToBuffer(d, &buf);
    try std.testing.expect(std.mem.indexOf(u8, text, "PC 24") != null);
    // A PC is not a source line and must not be presented as one.
    try std.testing.expect(std.mem.indexOf(u8, text, "line 24") == null);
    try std.testing.expect(!hasBareHexCode(text));
}
