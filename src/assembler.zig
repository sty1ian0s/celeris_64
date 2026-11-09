//! Celeris-64 assembler: text source -> 64-bit instruction words.
//!
//! Normative reference: docs/isa-encoding.md §2 (word layout), §3 (opcode map),
//! §4 (register indices), §5 (width suffixes). The literal syntax contract is
//! celeris_64-architecture-specification.md §3:
//!
//!     stream.add R0, [R1]+CHUNK_SIZE, R2
//!     compare R0, R1 -> R2
//!     select R3, R2, [EQUAL], R4, R5
//!     field.extract R0, R1, offset=12, width=3
//!
//! Rejects malformed input with a Diagnostic carrying the line number and the
//! offending text. It never crashes and never silently skips a line.

const std = @import("std");
const diag = @import("diagnostics.zig");
const analyzer = @import("analyzer.zig");

pub const Diagnostic = diag.Diagnostic;

/// Same one-module reason as `disassembler` below: a test root that needs the
/// diagnostics renderer reaches it through this handle, because diagnostics.zig is
/// already in this module's graph and may not be imported into a second one.
pub const diagnostics = diag;

/// The example suite's CLS64 kernels, so `tests/analyzer_no_false_positives.zig` can
/// analyse the programs this repository actually ships. Re-exported for the same
/// one-module reason as `disassembler`: nothing on the tooling path follows this
/// reference, so a root that does not name it does not build examples.zig.
pub const examples = @import("examples.zig");

/// Re-exported so a test root can reach both tools through one module. They
/// share diagnostics.zig, and Zig refuses to put one file in two modules.
pub const disassembler = @import("disassembler.zig");

/// Operand width suffix, docs/isa-encoding.md §5.
///
/// Declared here rather than imported from registers.zig so this module does not
/// drag the register file into the CLI's module graph; the numeric encoding is
/// normative and the round-trip tests pin it against the encoder.
pub const Width = enum(u4) {
    full = 0,
    l = 1,
    w = 2,
    b = 3,

    pub fn bits(self: Width) u8 {
        return switch (self) {
            .full => 64,
            .l => 32,
            .w => 16,
            .b => 8,
        };
    }

    pub fn mask(self: Width) u64 {
        return switch (self) {
            .full => std.math.maxInt(u64),
            .l => 0xFFFF_FFFF,
            .w => 0xFFFF,
            .b => 0xFF,
        };
    }

    pub fn suffix(self: Width) []const u8 {
        return switch (self) {
            .full => "",
            .l => ".l",
            .w => ".w",
            .b => ".b",
        };
    }
};

/// R0-R11: the architectural general-purpose register budget (AGENTS.md §2.2).
pub const gpr_count = 12;

/// Status enum values materialised by `compare` (§3.2.1).
pub const Status = enum(u4) {
    EQUAL = 0,
    LESS = 1,
    GREATER = 2,
    UNSIGNED_LESS = 3,
    UNSIGNED_GREATER = 4,

    pub fn fromName(tok: []const u8) ?Status {
        const info = @typeInfo(Status).@"enum";
        inline for (info.field_names, info.field_values) |fname, fvalue| {
            if (std.mem.eql(u8, fname, tok)) return @enumFromInt(fvalue);
        }
        return null;
    }

    /// Names accepted in `[BRACKETS]`, including the spec's snake_case spelling.
    pub fn fromToken(tok: []const u8) ?Status {
        if (fromName(tok)) |s| return s;
        if (std.ascii.eqlIgnoreCase(tok, "unsigned_less")) return .UNSIGNED_LESS;
        if (std.ascii.eqlIgnoreCase(tok, "unsigned_greater")) return .UNSIGNED_GREATER;
        return null;
    }

    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .EQUAL => "EQUAL",
            .LESS => "LESS",
            .GREATER => "GREATER",
            .UNSIGNED_LESS => "UNSIGNED_LESS",
            .UNSIGNED_GREATER => "UNSIGNED_GREATER",
        };
    }
};

/// §3.6 (amendment 1.1; operands re-derived by amendment 1.18) accelerator
/// operations, in opcode order. Each entry names its operands positionally.
///
/// The two fields below describe the TEXTUAL form only. Since amendment 1.18, a
/// `sources` count of 0 does not mean the operation has no register operand — it
/// means its register does not appear in the source syntax (`matrix.identity`'s
/// order travels in `rs1` but is written as `count=N`). What each register MEANS
/// at run time is §3.6 rule E, not this table.
pub const Accelerator = struct {
    opcode: u8,
    name: []const u8,
    /// How many source registers the mnemonic WRITES: 1 = rs1, 2 = rs1+rs2,
    /// 3 = rs1+rs2+rs3. This is the textual count, not the number of registers the
    /// operation touches.
    sources: u2,
    /// Whether the mnemonic accepts `count=N`. False means the field must stay zero
    /// in the word, because the operation has no counted length.
    takes_count: bool,
};

pub const accelerators = [_]Accelerator{
    .{ .opcode = 0x60, .name = "matrix.det", .sources = 1, .takes_count = false },
    .{ .opcode = 0x61, .name = "matrix.invert", .sources = 2, .takes_count = false },
    .{ .opcode = 0x62, .name = "matrix.mul", .sources = 2, .takes_count = false },
    .{ .opcode = 0x63, .name = "matrix.transform", .sources = 1, .takes_count = true },
    // §3.6 rule E: the order is written as `count=N` and lands in `rs1`, so the
    // textual form is one named operand and no positional register. With
    // `.sources = 0` there was no way to fill `rs1` at all, which made the row
    // unreachable from source; with `.takes_count = true` alone the only spelling
    // available was the one the VM rejects (a non-zero count field).
    .{ .opcode = 0x64, .name = "matrix.identity", .sources = 1, .takes_count = false },
    .{ .opcode = 0x70, .name = "fft.forward", .sources = 1, .takes_count = true },
    .{ .opcode = 0x71, .name = "fft.inverse", .sources = 1, .takes_count = true },
    .{ .opcode = 0x72, .name = "fft.ntt", .sources = 2, .takes_count = true },
    .{ .opcode = 0x73, .name = "fft.ntt.inverse", .sources = 2, .takes_count = true },
    .{ .opcode = 0x80, .name = "codec.compress", .sources = 1, .takes_count = true },
    .{ .opcode = 0x81, .name = "codec.decompress", .sources = 1, .takes_count = true },
    // §3.6 amendment 1.18 rule E: the count's unit is BYTES, and count=0 is a
    // diagnostic, so the count is the only way these can ever execute from source.
    .{ .opcode = 0x82, .name = "codec.fnv1a", .sources = 1, .takes_count = true },
    .{ .opcode = 0x83, .name = "codec.checksum16", .sources = 1, .takes_count = true },
};

/// Looks up a §3.6 operation by its opcode byte, or null when reserved.
pub fn acceleratorByOpcode(op: u8) ?Accelerator {
    for (accelerators) |a| {
        if (a.opcode == op) return a;
    }
    return null;
}

/// Looks up a §3.6 operation by mnemonic suffix (the part after the dot).
pub fn acceleratorByName(op_name: []const u8) ?Accelerator {
    for (accelerators) |a| {
        const dot = std.mem.indexOfScalar(u8, a.name, '.') orelse continue;
        if (std.mem.eql(u8, a.name[dot + 1 ..], op_name)) return a;
    }
    return null;
}

/// True when the byte is in the §3.6 accelerator range.
pub fn isAcceleratorOpcode(op: u8) bool {
    return op >= 0x60 and op <= 0x8F;
}

/// The single opcode map, §3. The disassembler renders these back to text and
/// the test suite iterates this list to prove the round-trip for every entry.
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

    /// §3.6 sentinel. Not an encoding: the real opcode byte (0x60-0x8F) travels in
    /// `Instruction.accel_opcode`, because this enum cannot hold the 32 reserved
    /// bytes in that range and they must still round-trip.
    accelerator = 0xFD,

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
            else => @tagName(self),
        };
    }

    pub fn fromMnemonic(text: []const u8) ?Opcode {
        const info = @typeInfo(Opcode).@"enum";
        inline for (info.field_values) |fvalue| {
            const op: Opcode = @enumFromInt(fvalue);
            // `.accelerator` is a sentinel, not an encoding, so its tag name is
            // never a mnemonic. §3.6 names are matched from the table instead.
            if (op == .accelerator) continue;
            if (std.mem.eql(u8, op.mnemonic(), text)) return op;
        }
        // §3.6 RESERVED opcodes disassemble to `.raw opcode, operand` so they
        // round-trip without being reinterpreted as a neighbouring operation.
        if (std.mem.eql(u8, text, ".raw")) return .accelerator;

        // §3.6 accelerator mnemonics, matched from the normative table.
        if (std.mem.startsWith(u8, text, "matrix.")) return fromAccelerator(0x60, text["matrix.".len..]);
        if (std.mem.startsWith(u8, text, "fft.")) return fromAccelerator(0x70, text["fft.".len..]);
        if (std.mem.startsWith(u8, text, "codec.")) return fromAccelerator(0x80, text["codec.".len..]);
        return null;
    }

    /// §3.6 (amendment 1.1): the 13 assigned accelerator mnemonics. Everything
    /// else in 0x60-0x8F is RESERVED and has no mnemonic; it is decoded and
    /// disassembled as raw bytes instead.
    ///
    /// The returned tag is always `.accelerator`; the real opcode byte travels in
    /// `Instruction.accel_opcode`. That keeps this enum finite while letting all
    /// 48 bytes of the range round-trip.
    fn fromAccelerator(base: u8, op_name: []const u8) ?Opcode {
        _ = base;
        // `op_name` is the text after the dot, e.g. "det" for "matrix.det".
        // acceleratorByName does that comparison in one place.
        return if (acceleratorByName(op_name) != null) .accelerator else null;
    }

    pub fn isAccelerator(self: Opcode) bool {
        const v = @intFromEnum(self);
        return v >= 0x60 and v <= 0x8F;
    }

    /// Classifies how an opcode's operand field is laid out, §3.
    pub fn kind(self: Opcode) Kind {
        if (self == .accelerator) return .accelerator;
        const v = @intFromEnum(self);
        if (v <= 0x05) return .control;
        if (v >= 0x10 and v <= 0x1B) return .alu;
        if (v == 0x20 or v == 0x21) return .compare_select;
        if (v == 0x30 or v == 0x31) return .field;
        if (v >= 0x40 and v <= 0x43) return .stream;
        if (v >= 0x50 and v <= 0x52) return .capability;
        if (v >= 0x60 and v <= 0x8F) return .accelerator;
        if (v >= 0x90 and v <= 0x92) return .thread;
        return .unknown;
    }
};

pub const Kind = enum {
    control,
    alu,
    compare_select,
    field,
    stream,
    capability,
    accelerator,
    thread,
    unknown,
};

/// An assembled instruction, retained so the disassembler and the round-trip
/// test can work on structure rather than on re-emitted source text.
pub const Instruction = struct {
    opcode: Opcode,
    /// Set when the source named a LABEL where an immediate was expected. The
    /// text is patched into the word by `assembleSource`'s final pass, once every
    /// label's address is known. Kept as text rather than a resolved value
    /// because a forward reference has no value at parse time.
    label_ref: ?[]const u8 = null,
    rd: u4 = 0,
    rs1: u4 = 0,
    /// ALU second source register, ignored when `imm` is non-zero (§3.1).
    rs2: u4 = 0,
    width: Width = .full,
    imm: i64 = 0,
    /// field.* operand.
    field_offset: u8 = 0,
    field_width: u8 = 0,
    /// stream.* chunk element count, §3.4.
    chunk: u32 = 0,
    /// select match value, §3.2.2.
    match: Status = .EQUAL,
    /// select arms.
    true_reg: u4 = 0,
    false_reg: u4 = 0,
    /// thread slot bitmask, §3.7.
    slot_mask: u8 = 0,
    /// Accelerator sub-opcode text, §3.6.
    accel_name: []const u8 = "",
    /// The raw accelerator opcode byte (0x60-0x8F), §3.6. Held separately from
    /// `opcode` because the Opcode enum cannot represent every reserved byte in
    /// the range, and a reserved opcode must round-trip unconverted.
    accel_opcode: u8 = 0,
    /// §3.6 rs3[43:40]: third source register. 0 means unused.
    rs3: u4 = 0,
    /// §3.6 reserved[39:32]: must be zero.
    accel_reserved: u8 = 0,
    /// §3.6 count[31:0]: 0 means "derive from the destination register".
    count: u32 = 0,
    /// True when the source wrote no count, so the disassembler can omit it and
    /// the round trip stays canonical.
    count_explicit: bool = false,

    pub fn word(self: Instruction) u64 {
        const op: u64 = @intFromEnum(self.opcode);
        var out: u64 = op << 56;
        out |= @as(u64, self.rd) << 52;
        out |= @as(u64, self.rs1) << 48;

        switch (self.opcode.kind()) {
            .control => {
                if (self.opcode == .branch) {
                    // §3.0.1: rs2[47:44] = match value, width[43:40], reserved
                    // [39:28] = 0, offset[27:0] = signed byte displacement. This arm
                    // previously handled only jump/call, so a `branch` assembled to
                    // operand 0 — a branch that tested EQUAL against a zero offset
                    // and fell through, making every loop run forever.
                    // §3.0.1: [43:40] is reserved for a branch, so no width is
                    // written. A branch narrows nothing.
                    out |= @as(u64, @intFromEnum(self.match)) << 44;
                    out |= @as(u64, @bitCast(self.imm)) & 0x0FFF_FFFF;
                } else if (self.opcode == .jump or self.opcode == .call) {
                    out |= @as(u64, @bitCast(self.imm)) & 0xFFFF_FFFF_FFFF;
                }
            },
            .alu => {
                if (self.opcode == .load or self.opcode == .store) {
                    // §3.1.1: same layout as §3.1, but `rs1` is the base register
                    // and already placed above, and offset[27:0] is the signed
                    // displacement. `load` leaves rs2 zero, `store` sets it.
                    out |= @as(u64, self.rs2) << 44;
                    out |= @as(u64, @intFromEnum(self.width)) << 40;
                    out |= @as(u64, @bitCast(self.imm)) & 0x0FFF_FFFF;
                } else {
                    out |= @as(u64, self.rs2) << 44;
                    out |= @as(u64, @intFromEnum(self.width)) << 40;
                    out |= @as(u64, @bitCast(self.imm)) & 0x0FFF_FFFF;
                }
            },
            .compare_select => {
                if (self.opcode == .compare) {
                    out |= @as(u64, self.rs2) << 44;
                    out |= @as(u64, @intFromEnum(self.width)) << 40;
                    out |= @as(u64, @bitCast(self.imm)) & 0x0FFF_FFFF;
                } else {
                    out |= @as(u64, @intFromEnum(self.match)) << 44;
                    out |= @as(u64, self.true_reg) << 40;
                    out |= @as(u64, self.false_reg) << 36;
                }
            },
            .field => {
                out |= @as(u64, self.field_offset) << 40;
                out |= @as(u64, self.field_width) << 32;
                out |= @as(u64, self.rs2) << 28;
            },
            .stream => {
                if (self.opcode == .stream_setp) {
                    out |= @as(u64, @bitCast(self.imm)) & 0x00FF_FFFF_FFFF;
                } else {
                    out |= @as(u64, self.rs2) << 44;
                    out |= @as(u64, self.chunk) << 24;
                    out |= @as(u64, @intFromEnum(self.width)) << 20;
                }
            },
            .capability => {
                out |= @as(u64, self.rs2) << 44;
            },
            .accelerator => {
                // §3.6: rs2[47:44], rs3[43:40], reserved[39:32], count[31:0].
                // The opcode byte comes from accel_opcode, not from the sentinel
                // tag, so a reserved byte in 0x60-0x8F round-trips unconverted.
                out &= ~(@as(u64, 0xFF) << 56);
                out |= @as(u64, self.accel_opcode) << 56;
                out |= @as(u64, self.rs2) << 44;
                out |= @as(u64, self.rs3) << 40;
                out |= @as(u64, self.accel_reserved) << 32;
                out |= @as(u64, self.count);
            },
            .thread => {
                out |= @as(u64, self.slot_mask);
            },
            .unknown => {},
        }
        return out;
    }
};

/// Result of assembling one source buffer.
pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    words: []u64,
    /// Non-fatal warnings, e.g. the register spill warning (AGENTS.md §4.3).
    warnings: []const Diagnostic,

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
    }
};

pub const Error = error{ AssemblyFailed, OutOfMemory };

/// Instructions per spill window. Chosen so ordinary straight-line code (which
/// reuses destinations) stays quiet, while a program that touches every register
/// in a tight burst is flagged.
const spill_window = 16;

/// I/O scratch used by the CLI. Nothing here allocates per instruction; the
/// word buffer grows once and the arena owns every slice.
/// §1: the fixed instruction width. Named here rather than imported from vm.zig
/// so the assembler does not depend on the VM.
pub const insn_bytes: u64 = 8;

pub const Assembler = struct {
    arena: std.heap.ArenaAllocator,
    words: std.ArrayList(u64) = .empty,
    warnings: std.ArrayList(Diagnostic) = .empty,
    /// Highest distinct R0-R11 index named anywhere, plus one.
    max_gpr_seen: u8 = 0,
    /// Registers written by the current instruction, used for the spill window.
    written_this_line: u16 = 0,
    /// Distinct GPRs written within the rolling window. This is the register
    /// pressure signal for AGENTS.md §4.3: a program that keeps naming new
    /// destination registers without reusing any is holding more values live
    /// than the file can hold.
    window_written: u16 = 0,
    /// Number of instructions in the rolling window.
    window_len: usize = 0,
    warned_spill: bool = false,
    /// Label -> instruction index (NOT byte address). Byte addresses are derived
    /// by multiplying by the fixed 8-byte instruction size, so storing indices
    /// keeps the table independent of §1's width.
    symbols: std.StringHashMapUnmanaged(usize) = .{},
    /// Label references whose target is not known yet, patched in a final pass.
    pending: std.ArrayListUnmanaged(PendingRef) = .empty,
    /// One row per emitted instruction, for src/analyzer.zig. Also the entry point
    /// for the CLI's findings: see `analyzeSource`.
    analysis: std.ArrayListUnmanaged(analyzer.Analyzed) = .empty,
    /// The most recently assembled instruction. Kept so callers (the
    /// disassembler's round-trip test and the CLI) can inspect the decoded
    /// form without re-deriving it from the word.
    last: Instruction = .{ .opcode = .nop },

    pub const PendingRef = struct {
        /// The assembled word, patched once the label resolves.
        word_index: usize = 0,
        label: []const u8 = "",
        line_no: usize = 0,
        /// Which immediate the label fills: an absolute `imm48` for jump/call, or
        /// a PC-relative 28-bit offset for `branch`.
        kind: enum { absolute48, relative28 } = .absolute48,
    };

    pub fn init(child: std.mem.Allocator) Assembler {
        return .{ .arena = std.heap.ArenaAllocator.init(child) };
    }


    pub fn deinit(self: *Assembler) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *Assembler) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Assembles `source`. On failure returns `.AssemblyFailed` and fills
    /// `out_diag` with a sentence naming the line and the offending text.
    pub fn assembleSource(
        self: *Assembler,
        name: []const u8,
        source: []const u8,
        out_diag: *Diagnostic,
    ) Error!Program {
        self.symbols.clearRetainingCapacity();
        self.pending.clearRetainingCapacity();
        self.words.clearRetainingCapacity();
        self.analysis.clearRetainingCapacity();

        // PASS 1: collect label definitions and their instruction indices.
        //
        // Labels are resolved in a separate pass because a forward reference is
        // the common case — a loop branches to a label defined BELOW it — and a
        // single pass could not know that address yet. The pass only counts
        // instructions; it does not assemble, so a label's address cannot depend
        // on how long an instruction turns out to be (every instruction is
        // exactly 8 bytes, §1, so an index times 8 is the address).
        {
            var scan = std.mem.splitScalar(u8, source, '\n');
            var scan_no: usize = 0;
            var index: usize = 0;
            while (scan.next()) |raw| {
                scan_no += 1;
                const line = std.mem.trim(u8, stripComment(stripAddressPrefix(raw)), " \t\r");
                if (line.len == 0) continue;

                const split = splitLabel(line);
                if (split.label) |label| {
                    if (self.symbols.contains(label)) {
                        out_diag.* = diag.duplicateLabel(scan_no, label, name);
                        return error.AssemblyFailed;
                    }
                    self.symbols.put(self.allocator(), label, index) catch return error.OutOfMemory;
                }
                // A line that is ONLY a label defines a position and emits nothing.
                if (split.rest.len == 0) continue;
                index += 1;
            }
        }

        // PASS 2: assemble, resolving labels as they are met.
        var lines = std.mem.splitScalar(u8, source, '\n');
        var line_no: usize = 0;
        while (lines.next()) |raw_line| {
            line_no += 1;
            const line = stripComment(stripAddressPrefix(raw_line));
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue; // blank lines are tolerated

            const split = splitLabel(trimmed);
            // A line that is only a label emits nothing, exactly as pass 1 assumed.
            if (split.rest.len == 0) continue;
            const body = split.rest;

            const insn = self.assembleLine(name, line_no, body, out_diag) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.AssemblyFailed => return error.AssemblyFailed,
            };
            self.last = insn;
            self.noteDestination(insn);
            self.advanceSpillWindow();
            const word_index = self.words.items.len;
            self.words.append(self.allocator(), insn.word()) catch return error.OutOfMemory;

            // Record any label the line referenced, so pass 3 can patch it. The
            // parser stores the label text in `label_ref` rather than an immediate
            // when it sees one.
            if (insn.label_ref) |ref| {
                self.pending.append(self.allocator(), .{
                    .word_index = word_index,
                    .label = ref,
                    .line_no = line_no,
                    .kind = if (insn.opcode == .jump or insn.opcode == .call) .absolute48 else .relative28,
                }) catch return error.OutOfMemory;
            }
            // Record the instruction for src/analyzer.zig. `text` slices the
            // caller's source buffer, which outlives the Program, so nothing is
            // copied here: this loop allocates only for the list itself.
            self.analysis.append(self.allocator(), .{
                .insn = insn,
                .line = line_no,
                .text = std.mem.trim(u8, body, " \t"),
            }) catch return error.OutOfMemory;
        }

        // Absolute targets for the analyzer. A literal transfer is known now; a
        // labelled one is overwritten by pass 3 with the label's own address.
        for (self.analysis.items, 0..) |*row, index| {
            const here = @as(u64, @intCast(index)) * insn_bytes;
            switch (row.insn.opcode) {
                .jump, .call => row.target = @as(u64, @bitCast(row.insn.imm)) & 0xFFFF_FFFF_FFFF,
                .branch => row.target = here +% @as(u64, @bitCast(row.insn.imm)),
                else => {},
            }
        }

        // PASS 3: patch every reference now that all addresses are known.
        for (self.pending.items) |ref| {
            const target_index = self.symbols.get(ref.label) orelse {
                out_diag.* = diag.unknownLabel(ref.line_no, ref.label, name);
                return error.AssemblyFailed;
            };
            // §1: every instruction is exactly 8 bytes, so a label's address is
            // its instruction index times 8.
            const target_addr = @as(u64, target_index) * insn_bytes;
            const here = @as(u64, ref.word_index) * insn_bytes;
            var word = self.words.items[ref.word_index];
            switch (ref.kind) {
                .absolute48 => {
                    word &= ~@as(u64, 0xFFFF_FFFF_FFFF);
                    word |= target_addr & 0xFFFF_FFFF_FFFF;
                },
                .relative28 => {
                    // §3.0.1: relative to the BRANCH INSTRUCTION ITSELF, not to
                    // the following one. A signed 28-bit field, so the reach is
                    // +/- 128 MiB.
                    const delta = @as(i64, @intCast(target_addr)) - @as(i64, @intCast(here));
                    if (delta < -0x800_0000 or delta > 0x7FF_FFFF) {
                        out_diag.* = diag.labelOutOfRange(ref.line_no, ref.label, delta, name);
                        return error.AssemblyFailed;
                    }
                    word &= ~@as(u64, 0x0FFF_FFFF);
                    word |= @as(u64, @bitCast(delta)) & 0x0FFF_FFFF;
                },
            }
            self.words.items[ref.word_index] = word;
            self.analysis.items[ref.word_index].target = target_addr;
        }

        return .{
            .arena = self.arena,
            .words = self.words.items,
            .warnings = self.warnings.items,
        };
    }

    /// Runs src/analyzer.zig over the last successful `assembleSource`.
    ///
    /// Kept out of `Program` on purpose: analysis allocates nothing, and a caller
    /// that only wants the image pays for a single walk of a table the assembler
    /// already built.
    pub fn analyzeSource(self: *const Assembler, file: []const u8) analyzer.Findings {
        return analyzer.analyze(self.analysis.items, file);
    }

    /// Assembles one already-trimmed line.
    fn assembleLine(
        self: *Assembler,
        name: []const u8,
        line_no: usize,
        line: []const u8,
        out_diag: *Diagnostic,
    ) Error!Instruction {
        // Mnemonic is the leading run of non-whitespace.
        const mnemonic_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        const mnemonic = line[0..mnemonic_end];
        const operand_text = std.mem.trim(u8, line[mnemonic_end..], " \t");

        const opcode = Opcode.fromMnemonic(mnemonic) orelse {
            var d = diag.badMnemonic(line_no, line);
            d.file = name;
            out_diag.* = d;
            return error.AssemblyFailed;
        };

        // Reject a mnemonic that carries trailing junk glued to it, e.g. "addx".
        if (std.ascii.isAlphanumeric(mnemonic[mnemonic.len - 1]) and operand_text.len == 0 and
            opcode.kind() == .unknown)
        {
            var d = diag.badMnemonic(line_no, line);
            d.file = name;
            out_diag.* = d;
            return error.AssemblyFailed;
        }

        var p = LineParser{ .owner = self, .src_name = name, .line_no = line_no, .text = operand_text, .mnemonic = mnemonic, .op = opcode };
        const insn = p.run(out_diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AssemblyFailed => return error.AssemblyFailed,
        };
        return insn;
    }

    /// AGENTS.md §4.3: overusing R0-R11 past capacity is a diagnostic warning.
    ///
    /// Pressure is measured as the number of DISTINCT general-purpose registers
    /// written inside a rolling window of instructions. A program that keeps
    /// producing fresh destinations is holding more values live at once than
    /// twelve registers can hold, which is what spilling means here. Counting
    /// merely how many register indices appear would never fire, because only
    /// twelve exist; counting destinations over a window observes the behaviour
    /// the mandate actually describes.
    fn checkSpill(self: *Assembler) void {
        if (self.window_written == 0) return;
        const used = @popCount(self.window_written);
        // The file is FULL once every R0-R11 is a live destination at once. Any
        // further value the software wants to keep has nowhere to go, which is
        // exactly the oversubscription AGENTS.md §4.3 asks us to flag. (A count
        // above 12 is unreachable: only twelve registers exist.)
        if (used < gpr_count) return;
        if (self.warned_spill) return;
        self.warned_spill = true;
        self.warnings.append(self.allocator(), diag.spill(used + 1)) catch {};
    }

    /// Records the destination register of the instruction just assembled.
    fn noteDestination(self: *Assembler, insn: Instruction) void {
        const dest = switch (insn.opcode.kind()) {
            // Only instructions that actually write a general-purpose register.
            .alu, .compare_select, .field, .stream, .capability, .accelerator => insn.rd,
            .control, .thread, .unknown => return,
        };
        if (dest > 11) return; // SP/LR/PC/FLAGS are not part of the GPR budget
        self.written_this_line |= @as(u16, 1) << dest;
    }

    /// Folds one instruction into the rolling spill window.
    fn advanceSpillWindow(self: *Assembler) void {
        self.window_written |= self.written_this_line;
        self.written_this_line = 0;
        self.window_len += 1;
        if (self.window_len >= spill_window) {
            // Slide by half a window's worth of instructions. The bitmap cannot
            // age individual bits, so the informative signal is the peak
            // pressure observed within any window; once peak pressure exceeds
            // the file we have already warned, and `warned_spill` latches it.
            self.window_len = 0;
        }
        self.checkSpill();
    }
};

/// Walks an operand list, one comma-separated field at a time.
const LineParser = struct {
    owner: *Assembler,
    src_name: []const u8,
    line_no: usize,
    text: []const u8,
    mnemonic: []const u8,
    op: Opcode,
    pos: usize = 0,
    index: usize = 0,

    fn fail(self: *LineParser, out: *Diagnostic, name_: []const u8, tok: []const u8, expected: []const u8) error{ AssemblyFailed, OutOfMemory } {
        // `index` is advanced by nextField; do not double-count here.
        var d = diag.badOperand(self.line_no, self.mnemonic, self.index, name_, tok, expected);
        d.file = self.src_name;
        out.* = d;
        return error.AssemblyFailed;
    }

    fn failMissing(self: *LineParser, out: *Diagnostic, name_: []const u8, expected: []const u8) error{ AssemblyFailed, OutOfMemory } {
        // One past the last operand consumed: that is the one that is missing.
        self.index += 1;
        var d = diag.missingOperand(self.line_no, self.mnemonic, self.index, name_, self.text, expected);
        d.file = self.src_name;
        out.* = d;
        return error.AssemblyFailed;
    }

    fn atEnd(self: *LineParser) bool {
        return std.mem.trim(u8, self.text[self.pos..], " \t").len == 0;
    }

    /// Next comma-separated field, or null at end of line.
    fn nextField(self: *LineParser) ?[]const u8 {
        const rest = std.mem.trimStart(u8, self.text[self.pos..], " \t");
        if (rest.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
        const field = std.mem.trim(u8, rest[0..end], " \t");
        self.pos = self.text.len - rest.len + end + @intFromBool(end < rest.len);
        // Track the operand position as it is consumed, so a failure reports the
        // operand it actually failed on. `index` used to count FAILURES instead,
        // which made the second operand report as "operand 1".
        self.index += 1;
        return field;
    }

    fn run(self: *LineParser, out: *Diagnostic) error{ AssemblyFailed, OutOfMemory }!Instruction {
        return switch (self.op.kind()) {
            .control => if (self.op == .branch) self.runBranch(out) else self.runControl(out),
            .alu => if (self.op == .load or self.op == .store) self.runMem(out) else self.runAlu(out),
            .compare_select => if (self.op == .compare) self.runAlu(out) else self.runSelect(out),
            .field => self.runField(out),
            .stream => self.runStream(out),
            .capability => self.runCapability(out),
            .thread => self.runThread(out),
            // `branch` is in the control group (0x05) and load/store in the ALU
            // group (0x1A/0x1B), so they are separated by opcode here rather than
            // by adding new Kind values — the Kind enum tracks the §3 group, and
            // these are the odd members of groups that already exist.
            .accelerator => self.runAccelerator(out),
            .unknown => self.fail(out, "mnemonic", self.mnemonic, "an instruction defined in the Celeris-64 opcode map"),
        };
    }

    // -- §3.0 control ---------------------------------------------------------

    fn runControl(self: *LineParser, out: *Diagnostic) !Instruction {
        var insn = Instruction{ .opcode = self.op };
        switch (self.op) {
            .nop, .halt, .ret => {
                if (!self.atEnd()) {
                    const tok = self.nextField() orelse "";
                    return self.fail(out, "operand", tok, "no operands at all for this instruction");
                }
            },
            .jump, .call => {
                const tok = self.nextField() orelse return self.failMissing(out, "target address", "an address to jump to, or a label name");
                // A label is patched in the final pass, once every address is
                // known; a literal is used directly.
                if (looksLikeLabel(tok)) {
                    insn.label_ref = tok;
                } else {
                    insn.imm = self.parseImm(tok, out, "target address") catch |e| return e;
                }
            },
            else => {},
        }
        return insn;
    }

    /// §3.0.1: `branch rs1, [MATCH], offset`.
    fn runBranch(self: *LineParser, out: *Diagnostic) !Instruction {
        var insn = Instruction{ .opcode = self.op };

        const reg_tok = self.nextField() orelse
            return self.failMissing(out, "status register", "the register holding a status enum from `compare`");
        insn.rs1 = try self.parseSourceReg(reg_tok, out, "status register");

        // The match value is written in brackets, `[LESS]`, matching the spec's
        // spelling for `select`.
        const match_tok = self.nextField() orelse
            return self.failMissing(out, "match value", "a status name in brackets, such as [EQUAL]");
        const name = std.mem.trim(u8, match_tok, " \t");
        const inner = if (name.len >= 2 and name[0] == '[' and name[name.len - 1] == ']')
            name[1 .. name.len - 1]
        else
            return self.fail(out, "match value", match_tok, "a status name in brackets, such as [EQUAL]");
        insn.match = Status.fromName(inner) orelse
            return self.fail(out, "match value", match_tok, "one of [EQUAL], [LESS], [GREATER], [UNSIGNED_LESS] or [UNSIGNED_GREATER] (docs/isa-encoding.md §3.2.1)");

        const off_tok = self.nextField() orelse
            return self.failMissing(out, "branch target", "a label name, or a byte offset relative to this branch");
        if (looksLikeLabel(off_tok)) {
            // Resolved in the final pass; `imm` stays 0 and is patched.
            insn.label_ref = off_tok;
            return insn;
        }
        const off = self.parseImm(off_tok, out, "branch offset") catch |e| return e;
        if (off < -0x800_0000 or off > 0x7FF_FFFF) {
            return self.fail(out, "branch offset", off_tok, "an offset that fits in the signed 28-bit field, from -134217728 to 134217727");
        }
        if (@rem(off, 8) != 0) {
            return self.fail(out, "branch offset", off_tok, "a multiple of 8, because every instruction is 8 bytes and an offset that is not a multiple of 8 cannot name an instruction boundary (docs/isa-encoding.md §1)");
        }
        insn.imm = off;
        return insn;
    }

    /// §3.1.1: `load rd, [rs1+off]` and `store rs2, [rs1+off]`.
    fn runMem(self: *LineParser, out: *Diagnostic) !Instruction {
        var insn = Instruction{ .opcode = self.op };
        const is_load = self.op == .load;

        const val_tok = self.nextField() orelse
            return self.failMissing(out, if (is_load) "destination register" else "source register", "the register to load into or store from");
        // The §5 suffix is on the value register, and it is the access size.
        const idx = try self.parseRegWithWidth(val_tok, out, if (is_load) "destination register" else "source register", &insn);
        if (is_load) {
            insn.rd = idx;
        } else {
            insn.rs2 = idx;
        }

        const addr_tok = self.nextField() orelse
            return self.failMissing(out, "address", "a bracketed base and displacement, such as [R4+16]");
        const addr = parseBracketedAddress(addr_tok) orelse
            return self.fail(out, "address", addr_tok, "a bracketed base register with an optional displacement, such as [R4], [R4+16] or [R4-8]");
        insn.rs1 = try self.parseReg(addr.reg, out, "base register");
        const off = self.parseImm(addr.disp, out, "displacement") catch |e| return e;
        if (off < -0x800_0000 or off > 0x7FF_FFFF) {
            return self.fail(out, "displacement", addr.disp, "a displacement that fits in the signed 28-bit field, from -134217728 to 134217727");
        }
        insn.imm = off;

        // §3.1.1: `load` and `store` take exactly two operands. A surplus one has
        // no field to live in, and accepting it silently is the F12/F19 defect
        // class — a lexical form the encoding cannot represent, taken without
        // complaint. `load R6, [R1+0], R7` assembled and dropped R7 entirely.
        if (self.nextField()) |extra| {
            return self.fail(out, "operand", extra, if (is_load)
                "no further operand, because load takes a destination register and an address (docs/isa-encoding.md §3.1.1)"
            else
                "no further operand, because store takes a source register and an address (docs/isa-encoding.md §3.1.1)");
        }
        return insn;
    }

    // -- §3.1 ALU -------------------------------------------------------------

    fn runAlu(self: *LineParser, out: *Diagnostic) !Instruction {
        var insn = Instruction{ .opcode = self.op };

        // Note the spec's `compare R0, R1 -> R2` arrow spelling: here rd is the
        // *last* field, not the first. `add R0, R1, R2` is dest-first.
        if (self.op == .compare and self.hasArrow()) {
            // Split the line at the arrow: the right-hand side is the
            // destination register, the left-hand side is the source list.
            const rest = self.text[self.pos..];
            const at = std.mem.indexOf(u8, rest, "->").?;
            const dest_text = std.mem.trim(u8, rest[at + 2 ..], " \t");
            const src_text = std.mem.trim(u8, rest[0..at], " \t");

            // Parse the source list, then the destination, using a nested
            // reader so the arrow never reaches the comma splitter.
            const saved_text = self.text;
            const saved_pos = self.pos;
            self.text = src_text;
            self.pos = 0;
            const lhs = self.nextField() orelse {
                self.text = saved_text;
                self.pos = saved_pos;
                return self.failMissing(out, "first source register", "a register to compare");
            };
            // F29: §3.2.1's operand layout is §3.1's, so the §5 width suffix is
            // part of the source register exactly as it is for the ALU opcodes.
            // parseSourceReg drops the suffix, which made the width nibble
            // unreachable from source and broke the round trip once the
            // disassembler started emitting it.
            {
                const idx = try self.parseRegWithWidth(lhs, out, "first source register", &insn);
                if (idx == 14) {
                    return self.fail(out, "first source register", lhs, "a register other than PC, because the program counter cannot be read as an ordinary operand (docs/isa-encoding.md §4); SP, LR and FLAGS are allowed");
                }
                insn.rs1 = idx;
            }

            const rhs = self.nextField() orelse {
                self.text = saved_text;
                self.pos = saved_pos;
                return self.failMissing(out, "second source", "a register or immediate to compare against");
            };
            try self.parseAluSecond(&insn, rhs, out);
            self.text = saved_text;
            self.pos = saved_pos;

            if (dest_text.len == 0) {
                return self.failMissing(out, "destination register", "a register after the -> arrow");
            }
            insn.rd = try self.parseDestRegWidth(dest_text, out, "destination register", &insn);
            return insn;
        }

        const dest_tok = self.nextField() orelse return self.failMissing(out, "destination register", "a register to write the result into");
        insn.rd = try self.parseDestRegWidth(dest_tok, out, "destination register", &insn);

        if (self.op == .mov) {
            // §3.1: `mov rd, src2`; rs1 is ignored.
            const src = self.nextField() orelse return self.failMissing(out, "source", "a register or immediate to move");
            try self.parseAluSecond(&insn, src, out);
            return insn;
        }

        const a = self.nextField() orelse return self.failMissing(out, "first source register", "a register to read");
        insn.rs1 = try self.parseSourceReg(a, out, "first source register");

        const b = self.nextField() orelse return self.failMissing(out, "second source", "a register or immediate to combine with");
        try self.parseAluSecond(&insn, b, out);
        return insn;
    }

    /// ALU second operand: a register, or an immediate (§3.1 imm28).
    fn parseAluSecond(self: *LineParser, insn: *Instruction, tok: []const u8, out: *Diagnostic) !void {
        if (looksLikeRegister(tok)) {
            // F29: keep the §5 suffix here too, for the same reason as rs1 above.
            const idx = try self.parseRegWithWidth(tok, out, "second source", insn);
            if (idx == 14) {
                return self.fail(out, "second source", tok, "a register other than PC, because the program counter cannot be read as an ordinary operand (docs/isa-encoding.md §4); SP, LR and FLAGS are allowed");
            }
            insn.rs2 = idx;
        } else {
            insn.imm = self.parseImm(tok, out, "second source") catch |e| return e;
            if (insn.imm < -0x800_0000 or insn.imm > 0x7FF_FFFF) {
                return self.fail(out, "second source", tok, "an immediate that fits in the signed 28-bit immediate field, from -134217728 to 134217727");
            }
        }
    }

    fn hasArrow(self: *LineParser) bool {
        const rest = std.mem.trimStart(u8, self.text[self.pos..], " \t");
        // Only a top-level arrow counts; `->` inside a field is not a thing here.
        return std.mem.indexOf(u8, rest, "->") != null;
    }

    fn afterArrow(self: *LineParser) ?[]const u8 {
        const rest = self.text[self.pos..];
        const at = std.mem.indexOf(u8, rest, "->") orelse return null;
        const tail = std.mem.trim(u8, rest[at + 2 ..], " \t");
        return if (tail.len == 0) null else tail;
    }

    // -- §3.2.2 select --------------------------------------------------------

    fn runSelect(self: *LineParser, out: *Diagnostic) !Instruction {
        var insn = Instruction{ .opcode = .select };

        const dest = self.nextField() orelse return self.failMissing(out, "destination register", "a register to receive the selected value");
        insn.rd = try self.parseReg(dest, out, "destination register");

        const status = self.nextField() orelse return self.failMissing(out, "status register", "the register holding a status enum");
        insn.rs1 = try self.parseReg(status, out, "status register");

        // `[EQUAL]` — the spec's bracketed match value.
        const match_tok = self.nextField() orelse return self.failMissing(out, "match value", "a bracketed match value such as [EQUAL]");
        const inner = if (std.mem.startsWith(u8, match_tok, "[") and std.mem.endsWith(u8, match_tok, "]"))
            std.mem.trim(u8, match_tok[1 .. match_tok.len - 1], " \t")
        else
            match_tok;
        insn.match = Status.fromToken(inner) orelse
            return self.fail(out, "match value", match_tok, "one of [EQUAL], [LESS], [GREATER], [UNSIGNED_LESS] or [UNSIGNED_GREATER]");

        const t = self.nextField() orelse return self.failMissing(out, "true value register", "the register selected when the status matches");
        insn.true_reg = try self.parseReg(t, out, "true value register");

        const f = self.nextField() orelse return self.failMissing(out, "false value register", "the register selected when the status does not match");
        insn.false_reg = try self.parseReg(f, out, "false value register");

        return insn;
    }

    // -- §3.3 field -----------------------------------------------------------

    fn runField(self: *LineParser, out: *Diagnostic) !Instruction {
        var insn = Instruction{ .opcode = self.op };

        const dest = self.nextField() orelse return self.failMissing(out, "destination register", "a register to write the result into");
        insn.rd = try self.parseReg(dest, out, "destination register");

        const src = self.nextField() orelse return self.failMissing(out, "source register", "the register to slice bits from");
        insn.rs1 = try self.parseReg(src, out, "source register");

        // `offset=12, width=3` — named, order-independent operands.
        var saw_offset = false;
        var saw_width = false;
        var saw_src2 = false;
        while (self.nextField()) |field| {
            if (splitNameValue(field)) |nv| {
                if (std.mem.eql(u8, nv.name, "offset")) {
                    insn.field_offset = try self.parseBounded(nv.value, out, "offset", 0, 64);
                    saw_offset = true;
                } else if (std.mem.eql(u8, nv.name, "width")) {
                    insn.field_width = try self.parseBounded(nv.value, out, "width", 1, 64);
                    saw_width = true;
                } else {
                    return self.fail(out, "field operand name", field, "either \"offset=<bits>\" or \"width=<bits>\"");
                }
            } else if (self.op == .field_insert and !saw_src2) {
                insn.rs2 = try self.parseReg(field, out, "inserted value register");
                saw_src2 = true;
            } else {
                return self.fail(out, "field operand", field, "a named operand such as \"offset=12\" or \"width=3\"");
            }
        }

        if (!saw_offset) return self.failMissing(out, "offset", "the bit position to start at, written as \"offset=<bits>\"");
        if (!saw_width) return self.failMissing(out, "width", "the number of bits to take, written as \"width=<bits>\"");

        // §3.3.1 constraints, enforced at assembly time rather than at run time.
        if (insn.field_width == 0) {
            return self.fail(out, "width", self.lastToken("width"), "a width from 1 to 64 bits");
        }
        if (@as(usize, insn.field_offset) + @as(usize, insn.field_width) > 64) {
            return self.fail(out, "offset", self.lastToken("offset"), "an offset and width whose sum is at most 64 bits, because a register holds exactly 64 bits");
        }
        return insn;
    }

    // -- §3.4 stream ----------------------------------------------------------

    fn runStream(self: *LineParser, out: *Diagnostic) !Instruction {
        var insn = Instruction{ .opcode = self.op };

        if (self.op == .stream_setp) {
            const ptr = self.nextField() orelse return self.failMissing(out, "pointer register", "the register holding the stream address");
            // §3.4: `stream.setp` has NO element-width field — operand[39:0] is
            // its byte stride. A width suffix here is meaningless, and silently
            // accepting it produced the same word as omitting it, which is the
            // very defect this task exists to remove.
            if (parseRegisterText(ptr) catch null) |parsed| {
                if (parsed.width != null) {
                    return self.fail(out, "pointer register", ptr, "a plain register, because stream.setp sets a byte stride and has no element width to select (docs/isa-encoding.md §3.4); write the stride as a second operand instead");
                }
            }
            insn.rd = try self.parseReg(ptr, out, "pointer register");
            const stride = self.nextField() orelse {
                // `stream.setp R0, R1` sets the pointer to base + stride.
                return self.failMissing(out, "byte stride", "the number of bytes to advance per step");
            };
            insn.imm = self.parseImm(stride, out, "byte stride") catch |e| return e;
            // §3.4: `setp` names its pointer with `rd` and nothing else — no
            // second register. A surplus operand has no field to live in and was
            // silently discarded (F19, the F12 shape).
            if (self.nextField()) |extra| {
                return self.fail(out, "operand", extra, "no further operand, because stream.setp takes exactly a pointer register and a byte stride (docs/isa-encoding.md §3.4)");
            }
            return insn;
        }

        const dest = self.nextField() orelse return self.failMissing(out, "element register", "the register holding the element to add, copy or fill");
        // §3.4 element width: the §5 suffix on the element operand selects
        // `operand[23:20]`. This was previously parsed and DISCARDED, so
        // `R0.w` and `R0` encoded identically and a sub-64-bit stream was
        // inexpressible. parseReg drops the suffix, so read it here.
        insn.rd = try self.parseReg(dest, out, "element register");
        if (parseRegisterText(dest) catch null) |parsed| {
            if (parsed.width) |wd| insn.width = wd;
        }

        // `[R1]+CHUNK_SIZE` — bracketed pointer with an optional chunk name.
        const ptr_tok = self.nextField() orelse return self.failMissing(out, "stream pointer", "a bracketed pointer such as [R1]+CHUNK_SIZE");
        const bracket = parseBracketedChunk(ptr_tok) orelse
            return self.fail(out, "stream pointer", ptr_tok, "a bracketed pointer such as [R1]+CHUNK_SIZE");
        insn.rs1 = try self.parseReg(bracket.reg, out, "stream pointer");

        if (bracket.chunk.len != 0) {
            insn.chunk = self.parseChunk(bracket.chunk, out) catch |e| return e;
        } else {
            insn.chunk = 1;
        }

        // The third operand is the offset register (§3.4: operand[47:44]).
        //
        // F26: this previously read `if (self.op == .stream_fill) return insn;`,
        // returning before the offset was read. §3.4's encoding paragraph covers
        // `stream.add`, `stream.copy` AND `stream.fill` — all three carry
        // operand[47:44] — so `stream.fill R10.b, [R4]+468156, PC` parsed the
        // register and threw it away, and the word round-tripped as ", R0".
        // The renderer printed a register the parser had never accepted.
        if (self.nextField()) |off| {
            insn.rs2 = try self.parseReg(off, out, "offset register");
        }
        return insn;
    }

    /// CHUNK_SIZE is a named constant in the spec's example; without a symbol
    /// table we accept a literal count and the architectural chunk name
    /// CHUNK_SIZE, which the spec uses for "one hardware chunk".
    fn parseChunk(self: *LineParser, tok: []const u8, out: *Diagnostic) !u32 {
        if (std.ascii.eqlIgnoreCase(tok, "CHUNK_SIZE")) return 64;
        return self.parseUnsigned32(tok, out, "chunk element count", 1, 0xF_FFFF);
    }

    // -- §3.5 capability ------------------------------------------------------

    /// §3.5 (Amendment 1.11, normative). The textual form carries exactly two
    /// registers. `rd` is the destination (or the LOW register of the pair for
    /// cap.load), `rs1` is the source (or the low register of the pair for
    /// cap.store). There is no third operand: the capability's address comes
    /// from the register pair itself, not from a third register, and the
    /// encoding has no field for one.
    ///
    /// Before this, a third register was parsed into `Instruction.rs2`, which the
    /// decoder's `Cap` struct (op/rd/rs1 only) cannot reach, so it was silently
    /// discarded — `cap.load R2, R3, R4` assembled and `R4` vanished.
    fn runCapability(self: *LineParser, out: *Diagnostic) !Instruction {
        var insn = Instruction{ .opcode = self.op };
        const a = self.nextField() orelse return self.failMissing(out, "register", "a register or register pair");
        insn.rd = try self.parseReg(a, out, "destination register");

        const b = self.nextField() orelse return insn;
        insn.rs1 = try self.parseReg(b, out, "source register");

        // §3.5 v1.11: rs2 is unused and must be zero. A third register is a
        // diagnostic error rather than a silent discard. Checked BEFORE the
        // even-index rule so a surplus operand is not reported as an odd register
        // (the two-register form is the legal one, so the odd register is not
        // the user's mistake here).
        if (self.nextField()) |c| {
            return self.fail(out, "third register", c, "no third operand, because the encoding carries only two registers: the capability's address comes from the register pair itself, not from a third register (docs/isa-encoding.md §3.5)");
        }

        // §3.5 v1.11 even-index rule for cap.load/cap.store: the descriptor is two
        // CONSECUTIVE registers starting at an even index, so an odd low index
        // would split a pair across (R1,R2) and overlap the neighbouring
        // descriptor (R2,R3) — one word describing two capabilities.
        //
        // §3.5 v1.12: only ONE register names the pair, so only that register is
        // constrained. For cap.load the pair is `rd` and `rs1` is a plain source;
        // for cap.store the pair is `rs1` and `rd` is a plain destination.
        // Applying it to both rejected legal instructions (F14). NOT applied to
        // cap.check: its rs1 names a descriptor to test, not a pair this
        // instruction forms, so any register holding a descriptor is legal and
        // the even-index constraint belongs to whoever built the pair.
        const pair_is_rd = switch (self.op) {
            .cap_load => true,
            .cap_store => false,
            else => return insn,
        };
        if (pair_is_rd and insn.rd % 2 != 0) {
            return self.fail(out, "destination register", a, "an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)");
        }
        if (!pair_is_rd and insn.rs1 % 2 != 0) {
            return self.fail(out, "source register", b, "an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)");
        }
        return insn;
    }

    // -- §3.7 threads ---------------------------------------------------------

    fn runThread(self: *LineParser, out: *Diagnostic) !Instruction {
        var insn = Instruction{ .opcode = self.op };
        switch (self.op) {
            .thread_spawn => {
                // §3.7's canonical form enumerates slots comma-separated
                // ("T0, T2"), so the mask may span several comma-delimited
                // fields. Gather every leading field that is slot syntax, then
                // read the address register.
                insn.slot_mask = try self.parseSlotList(out);
                const addr = self.nextField() orelse return self.failMissing(out, "entry address register", "the register holding the thread entry address");
                insn.rs1 = try self.parseReg(addr, out, "entry address register");
            },
            .thread_join => {
                insn.slot_mask = try self.parseSlotList(out);
            },
            .thread_yield => {
                if (!self.atEnd()) {
                    const tok = self.nextField() orelse "";
                    return self.fail(out, "operand", tok, "no operands at all for a thread yield");
                }
            },
            else => {},
        }
        return insn;
    }

    /// Consumes one or more comma-delimited fields that together describe the
    /// slot mask, stopping at the first field that is not slot syntax. Needed
    /// because the canonical "T0, T2" form is itself comma-separated.
    fn parseSlotList(self: *LineParser, out: *Diagnostic) !u8 {
        var mask: u8 = 0;
        var any = false;
        while (self.peekField()) |field| {
            if (!isSlotSyntax(field)) break;
            const consumed = self.nextField().?;
            mask |= try self.parseSlots(consumed, out);
            any = true;
            // "no slots" is a complete mask on its own, never a list.
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, consumed, " \t"), "no slots")) break;
        }
        if (!any) {
            return self.failMissing(out, "thread slot mask", "the slots to act on, such as T0, T2, the range T0-T7, or \"no slots\"");
        }
        return mask;
    }

    /// Looks at the next field without consuming it.
    fn peekField(self: *LineParser) ?[]const u8 {
        const saved = self.pos;
        const f = self.nextField();
        self.pos = saved;
        return f;
    }

    /// §3.7. Accepts the canonical enumerated form (`no slots`, `T0, T2`), the
    /// `|` form, and `T0-T7`/`T0–T7` as shorthand for all eight slots. The
    /// disassembler always emits the enumerated form, so exactly one canonical
    /// text exists per word.
    fn parseSlots(self: *LineParser, tok: []const u8, out: *Diagnostic) !u8 {
        const t = std.mem.trim(u8, tok, " \t");

        // §3.7: a zero mask is legal and names no slot.
        if (std.ascii.eqlIgnoreCase(t, "no slots")) return 0;

        // Range shorthand for all eight: "T0-T7" or "T0–T7" (en dash).
        if (std.mem.indexOfScalar(u8, t, '-') orelse
            std.mem.indexOf(u8, t, "\u{2013}")) |sep|
        {
            const sep_len: usize = if (t[sep] == '-') 1 else 3;
            const lo = std.mem.trim(u8, t[0..sep], " \t");
            const hi = std.mem.trim(u8, t[sep + sep_len ..], " \t");
            if (slotIndex(lo)) |a| {
                if (slotIndex(hi)) |b| {
                    if (a > b) {
                        // Reversed range (T7-T0): empty, so it is refused rather
                        // than silently interpreted as its mirror image.
                        return self.fail(out, "thread slot mask", tok, "a range whose first slot is not above its last, such as T0-T7");
                    }
                    // Set bits a..b inclusive. Widened to u32 first: the naive
                    // `1 << (b+1)` with b == 7 shifts a u5 by 8, which is an
                    // invalid shift, and looping with a u3 counter overflows at
                    // i == 7. Both were real aborts.
                    // §3.7 has eight slots, so the mask is 8 bits wide.
                    const lo_bit: u32 = @as(u32, 1) << a;
                    const hi_bit: u32 = @as(u32, 1) << (@as(u4, b) + 1);
                    const spread: u32 = hi_bit - lo_bit;
                    return @truncate(spread);
                }
            }
            return self.fail(out, "thread slot mask", tok, "a range such as T0-T7, or slots separated by commas");
        }

        // Enumerated or `|`-separated slots.
        var mask: u8 = 0;
        var it = std.mem.tokenizeAny(u8, t, "|,");
        var any = false;
        while (it.next()) |part| {
            const s2 = std.mem.trim(u8, part, " \t");
            if (s2.len == 0) continue;
            any = true;
            const idx = slotIndex(s2) orelse {
                return self.fail(out, "thread slot mask", tok, "slots T0 through T7, separated by commas, or the range T0-T7, or \"no slots\"");
            };
            mask |= @as(u8, 1) << idx;
        }
        if (!any) {
            return self.fail(out, "thread slot mask", tok, "at least one slot, the range T0-T7, or \"no slots\"");
        }
        return mask;
    }

    fn slotIndex(t: []const u8) ?u3 {
        if (t.len != 2) return null;
        if (t[0] != 'T' and t[0] != 't') return null;
        if (t[1] < '0' or t[1] > '7') return null;
        return @intCast(t[1] - '0');
    }

    // -- §3.6 accelerator -----------------------------------------------------

    /// §3.6 (amendment 1.1): `rd` then up to three source registers, then an
    /// optional `count=N`. The operand count is fixed per mnemonic, so a missing
    /// or extra operand is a diagnostic rather than a guess.
    fn runAccelerator(self: *LineParser, out: *Diagnostic) !Instruction {
        var insn = Instruction{ .opcode = .accelerator };
        const m = self.mnemonic;
        const op_name = m[(std.mem.indexOfScalar(u8, m, '.') orelse 0) + 1 ..];
        insn.accel_name = op_name;

        // `.raw opcode, operand` reconstructs a RESERVED accelerator word from
        // its exact bytes. It is what the disassembler emits for opcodes in the
        // range that §3.6 does not assign, so those words round-trip rather than
        // being reinterpreted as a neighbour.
        if (std.mem.eql(u8, m, ".raw")) {
            const op_tok = self.nextField() orelse {
                return self.failMissing(out, "accelerator opcode byte", "the opcode byte this word carries");
            };
            // F20/F21/F22/F23/F25/F26/F29: `.raw` is the lossless escape hatch.
            // It began as an accelerator-only form (0x60-0x8F), but the
            // disassembler now falls back to it for ANY opcode whose mnemonic
            // cannot name every bit the word carries. Restricting the range here
            // made those fallbacks unassemblable, which is strictly worse than
            // the silent loss it replaced. Any opcode byte is now accepted; the
            // word is data and `.raw` preserves it exactly.
            const op_val = std.fmt.parseInt(u16, op_tok, 0) catch {
                return self.fail(out, "raw opcode byte", op_tok, "a byte from 0 to 255");
            };
            if (op_val > 0xFF) {
                return self.fail(out, "raw opcode byte", op_tok, "a byte from 0 to 255");
            }
            insn.accel_opcode = @intCast(op_val);

            const operand_tok = self.nextField() orelse {
                return self.failMissing(out, "operand field", "the raw 48-bit operand field");
            };
            const operand_val = std.fmt.parseInt(u64, operand_tok, 0) catch {
                return self.fail(out, "operand field", operand_tok, "a number that fits in 48 bits");
            };
            if (operand_val > 0xFFFF_FFFF_FFFF) {
                return self.fail(out, "operand field", operand_tok, "a number that fits in 48 bits");
            }
            const raw: u48 = @intCast(operand_val);
            insn.rs2 = @truncate(raw >> 44);
            insn.rs3 = @truncate(raw >> 40);
            insn.accel_reserved = @truncate(raw >> 32);
            insn.count = @truncate(raw);
            // F20: `.raw` carried only the 48-bit operand, so bits [55:48] —
            // `rd` and `rs1` — were never reconstructed and the instruction
            // re-assembled without them. A reserved accelerator word is
            // arbitrary data; every bit must survive the round trip. The
            // disassembler emits them as a third and fourth operand (see
            // disassembler.zig `accelerator`), and they are optional here so
            // pre-F20 `.dis` files that carry only two operands still parse.
            if (self.nextField()) |rd_tok| {
                const v = std.fmt.parseInt(u16, rd_tok, 0) catch {
                    return self.fail(out, "raw destination register", rd_tok, "a register index from 0 to 15");
                };
                if (v > 15) return self.fail(out, "raw destination register", rd_tok, "a register index from 0 to 15");
                insn.rd = @intCast(v);
            }
            if (self.nextField()) |rs1_tok| {
                const v = std.fmt.parseInt(u16, rs1_tok, 0) catch {
                    return self.fail(out, "raw first-source register", rs1_tok, "a register index from 0 to 15");
                };
                if (v > 15) return self.fail(out, "raw first-source register", rs1_tok, "a register index from 0 to 15");
                insn.rs1 = @intCast(v);
            }
            return insn;
        }

        const spec = acceleratorByName(op_name) orelse {
            return self.fail(out, "mnemonic", m, "one of the accelerator operations in §3.6 of docs/isa-encoding.md");
        };
        insn.accel_opcode = spec.opcode;

        const dest = self.nextField() orelse {
            return self.failMissing(out, "destination register", "a register to write the result into");
        };
        insn.rd = try self.parseReg(dest, out, "destination register");

        // Named sources, in positional order per the §3.6 table.
        const names = [_][]const u8{ "first source register", "second source register", "third source register" };
        var i: u2 = 0;
        var source_regs: [3]u4 = .{ 0, 0, 0 };
        while (i < spec.sources) : (i += 1) {
            const tok = self.nextField() orelse {
                return self.failMissing(out, names[i], "a register to read");
            };
            source_regs[i] = try self.parseReg(tok, out, names[i]);
        }
        insn.rs1 = source_regs[0];
        insn.rs2 = source_regs[1];
        insn.rs3 = source_regs[2];

        // Optional named operand.
        if (self.nextField()) |field| {
            if (splitNameValue(field)) |nv| {
                if (std.mem.eql(u8, nv.name, "count")) {
                    if (!spec.takes_count) {
                        return self.fail(out, "count", field, "a mnemonic that does not take a count; this operation names only registers");
                    }
                    insn.count = self.parseCount(nv.value, out) catch |e| return e;
                    insn.count_explicit = true;
                } else {
                    return self.fail(out, "accelerator operand name", field, "\"count=<elements>\", since the other operands are positional registers");
                }
            } else {
                return self.fail(out, "accelerator operand", field, "a named operand such as \"count=16\"");
            }
        }
        return insn;
    }

    fn parseCount(self: *LineParser, tok: []const u8, out: *Diagnostic) !u32 {
        const v = std.fmt.parseInt(u64, tok, 0) catch {
            return self.fail(out, "count", tok, "a whole number of elements");
        };
        if (v > std.math.maxInt(u32)) {
            return self.fail(out, "count", tok, "a count that fits in 32 bits, from 0 to 4294967295");
        }
        return @intCast(v);
    }

    // -- operand helpers ------------------------------------------------------

    const Peeled = struct { reg: ?u4, text: []const u8 };

    /// True when the token is a register name, with or without a width suffix.
    fn looksLikeRegister(tok: []const u8) bool {
        return isRegisterToken(tok);
    }

    fn parseReg(self: *LineParser, tok: []const u8, out: *Diagnostic, what: []const u8) !u4 {
        const parsed = parseRegisterText(tok) catch {
            return self.fail(out, what, tok, "a register: R0 through R11, or the system registers SP, LR, PC and FLAGS");
        };
        self.noteRegister(parsed.index);
        return parsed.index;
    }

    /// §4: `PC` (index 14) may not be read in a source position. SP, LR and
    /// FLAGS are all legal here — only PC is refused, so this must not be
    /// widened to "any system register".
    fn parseSourceReg(self: *LineParser, tok: []const u8, out: *Diagnostic, what: []const u8) !u4 {
        const index = try self.parseReg(tok, out, what);
        if (index == 14) {
            return self.fail(out, what, tok, "a register other than PC, because the program counter cannot be read as an ordinary operand (docs/isa-encoding.md §4); SP, LR and FLAGS are allowed");
        }
        return index;
    }

    /// §4: writing PC in `rd` of a normal instruction is a diagnostic error
    /// outside the jump forms. Left unchecked it is silently DISCARDED at run
    /// time, because the VM re-derives PC from the instruction stride, so the
    /// user gets no signal at all. SP, LR and FLAGS are legal destinations.
    fn parseDestReg(self: *LineParser, tok: []const u8, out: *Diagnostic, what: []const u8) !u4 {
        const index = try self.parseReg(tok, out, what);
        if (index == 14) {
            return self.fail(out, what, tok, "a register other than PC, because writing the program counter outside a jump instruction is not defined (docs/isa-encoding.md §4); SP, LR and FLAGS are allowed");
        }
        return index;
    }

    /// Like `parseDestReg`, but also records the width suffix on the
    /// instruction (§5). Used for the ALU destination register.
    fn parseDestRegWidth(self: *LineParser, tok: []const u8, out: *Diagnostic, what: []const u8, insn: *Instruction) !u4 {
        const index = try self.parseDestReg(tok, out, what);
        if (parseRegisterText(tok) catch null) |parsed| {
            if (parsed.width) |wd| insn.width = wd;
        }
        return index;
    }

    fn parseRegWithWidth(self: *LineParser, tok: []const u8, out: *Diagnostic, what: []const u8, insn: *Instruction) !u4 {
        const parsed = parseRegisterText(tok) catch {
            return self.fail(out, what, tok, "a register: R0 through R11, or the system registers SP, LR, PC and FLAGS");
        };
        if (parsed.width) |wd| insn.width = wd;
        self.noteRegister(parsed.index);
        return parsed.index;
    }

    fn noteRegister(self: *LineParser, index: u4) void {
        if (index <= 11 and index + 1 > self.owner.max_gpr_seen) self.owner.max_gpr_seen = index + 1;
    }

    fn parseImm(self: *LineParser, tok: []const u8, out: *Diagnostic, what: []const u8) !i64 {
        return std.fmt.parseInt(i64, tok, 0) catch {
            return self.fail(out, what, tok, "a decimal number, or a hexadecimal number written as 0x...");
        };
    }

    fn parseBounded(self: *LineParser, tok: []const u8, out: *Diagnostic, what: []const u8, lo: u64, hi: u64) !u8 {
        const v = std.fmt.parseInt(u64, tok, 0) catch {
            return self.fail(out, what, tok, "a whole number of bits");
        };
        if (v < lo or v > hi) {
            return self.fail(out, what, tok, if (lo == 1 and hi == 64) "a width from 1 to 64 bits" else "an offset from 0 to 63 bits");
        }
        return @intCast(v);
    }

    fn parseUnsigned32(self: *LineParser, tok: []const u8, out: *Diagnostic, what: []const u8, lo: u64, hi: u64) !u32 {
        const v = std.fmt.parseInt(u64, tok, 0) catch {
            return self.fail(out, what, tok, "a whole number of elements");
        };
        if (v < lo or v > hi) {
            return self.fail(out, what, tok, "a chunk length of at least 1 element");
        }
        return @intCast(v);
    }

    /// Used only to quote the original text in the constraint diagnostics.
    fn lastToken(self: *LineParser, name_: []const u8) []const u8 {
        var it = std.mem.splitScalar(u8, self.text, ',');
        var found: []const u8 = self.text;
        while (it.next()) |f| {
            const t = std.mem.trim(u8, f, " \t");
            if (std.mem.startsWith(u8, t, name_)) found = t;
        }
        return found;
    }
};

/// Strips a `#` comment. Comments are tolerated per P1.7.
/// True when the text looks like §3.7 slot syntax (a T0-T7 reference, a range,
/// or "no slots"), used to decide how far a slot list extends.
pub fn isSlotSyntax(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(t, "no slots")) return true;
    // Any component (split on | or ,) must be a slot or a range.
    var it = std.mem.tokenizeAny(u8, t, "|,");
    var any = false;
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \t");
        any = true;
        if (p.len == 2 and (p[0] == 'T' or p[0] == 't') and p[1] >= '0' and p[1] <= '7') continue;
        // Range form: "T0-T7".
        if (std.mem.indexOfScalar(u8, p, '-')) |dash| {
            const lo = std.mem.trim(u8, p[0..dash], " \t");
            const hi = std.mem.trim(u8, p[dash + 1 ..], " \t");
            if (lo.len == 2 and hi.len == 2 and (lo[0] == 'T' or lo[0] == 't') and
                (hi[0] == 'T' or hi[0] == 't') and lo[1] >= '0' and lo[1] <= '7' and
                hi[1] >= '0' and hi[1] <= '7') continue;
        }
        return false;
    }
    return any;
}

/// Strips the `000000:  ` address prefix that `celeris64 dis` prints.
///
/// The disassembler and the assembler are a pair, so the assembler accepts the
/// disassembler's own output verbatim: `celeris64 dis a.bin > a.asm` followed by
/// `celeris64 asm a.asm b.bin` reproduces the original bytes without the user
/// having to strip anything first. That is the round trip people actually type.
pub fn stripAddressPrefix(line: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return line;
    // The prefix must be all hex digits and nothing else, so a stray colon in an
    // operand is never eaten.
    const head = std.mem.trim(u8, line[0..colon], " \t");
    if (head.len == 0) return line;
    for (head) |c| {
        if (!std.ascii.isHex(c)) return line;
    }
    return std.mem.trimStart(u8, line[colon + 1 ..], " \t");
}

pub fn stripComment(line: []const u8) []const u8 {
    const at = std.mem.indexOfScalar(u8, line, '#') orelse return line;
    return line[0..at];
}

pub const ParsedRegister = struct { index: u4, width: ?Width };

/// Parses `R0`, `R11`, `SP`, `LR`, `PC`, `FLAGS`, each optionally with a
/// `.l`/`.w`/`.b` width suffix (§5).
pub fn parseRegisterText(tok: []const u8) !ParsedRegister {
    var head = tok;
    var width: ?Width = null;
    if (std.mem.lastIndexOfScalar(u8, tok, '.')) |dot| {
        const suffix = tok[dot..];
        if (std.mem.eql(u8, suffix, ".l")) {
            width = .l;
            head = tok[0..dot];
        } else if (std.mem.eql(u8, suffix, ".w")) {
            width = .w;
            head = tok[0..dot];
        } else if (std.mem.eql(u8, suffix, ".b")) {
            width = .b;
            head = tok[0..dot];
        }
    }

    if (std.ascii.eqlIgnoreCase(head, "SP")) return .{ .index = 12, .width = width };
    if (std.ascii.eqlIgnoreCase(head, "LR")) return .{ .index = 13, .width = width };
    if (std.ascii.eqlIgnoreCase(head, "PC")) return .{ .index = 14, .width = width };
    if (std.ascii.eqlIgnoreCase(head, "FLAGS")) return .{ .index = 15, .width = width };

    if (head.len >= 2 and (head[0] == 'R' or head[0] == 'r')) {
        const n = std.fmt.parseInt(u8, head[1..], 10) catch return error.NoSuchRegister;
        if (n <= 11) return .{ .index = @intCast(n), .width = width };
        return error.NoSuchRegister;
    }
    return error.NoSuchRegister;
}

pub fn isRegisterToken(tok: []const u8) bool {
    _ = parseRegisterText(tok) catch return false;
    return true;
}

/// `[R1]+CHUNK_SIZE` -> { reg = "R1", chunk = "CHUNK_SIZE" }.
pub fn parseBracketedChunk(tok: []const u8) ?struct { reg: []const u8, chunk: []const u8 } {
    const open = std.mem.indexOfScalar(u8, tok, '[') orelse return null;
    const close = std.mem.indexOfScalar(u8, tok, ']') orelse return null;
    if (close < open) return null;
    const reg = std.mem.trim(u8, tok[open + 1 .. close], " \t");
    if (reg.len == 0) return null;
    var rest = std.mem.trim(u8, tok[close + 1 ..], " \t");
    if (rest.len != 0) {
        if (rest[0] != '+') return null;
        rest = std.mem.trim(u8, rest[1..], " \t");
    }
    return .{ .reg = reg, .chunk = rest };
}

/// `[R4+16]` -> { reg = "R4", disp = "+16" }. Accepts `[R4]` with no
/// displacement, and both signs. The displacement is returned as TEXT so the
/// caller reports an unparseable number with the user's own token.
/// Splits `"loop: add R1, R2"` into label `"loop"` and rest `"add R1, R2"`.
/// Also handles a line that is only a label (`"loop:"`), whose rest is empty.
///
/// Written to be usable by BOTH assembly passes, so the address pass and the
/// emit pass cannot disagree about which lines produce an instruction — the
/// classic way a two-pass assembler drifts out of sync and produces a branch to
/// the wrong place.
/// True when an operand names a label rather than a number. A label starts with
/// a letter, `_` or `.`; a number starts with a digit, `-`, `+` or `0x`.
pub fn looksLikeLabel(tok: []const u8) bool {
    if (tok.len == 0) return false;
    const first = tok[0];
    return std.ascii.isAlphabetic(first) or first == '_' or first == '.';
}

pub fn splitLabel(line: []const u8) struct { label: ?[]const u8, rest: []const u8 } {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse
        return .{ .label = null, .rest = line };
    const name = std.mem.trim(u8, line[0..colon], " \t");
    // A colon inside an operand (`[R1+0]`) is not a label. Label names are
    // identifiers, so anything containing a space or a bracket is not one.
    if (name.len == 0) return .{ .label = null, .rest = line };
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '.') {
            return .{ .label = null, .rest = line };
        }
    }
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_' and name[0] != '.') {
        return .{ .label = null, .rest = line };
    }
    return .{ .label = name, .rest = std.mem.trim(u8, line[colon + 1 ..], " \t") };
}

pub fn parseBracketedAddress(tok: []const u8) ?struct { reg: []const u8, disp: []const u8 } {
    const open = std.mem.indexOfScalar(u8, tok, '[') orelse return null;
    const close = std.mem.indexOfScalar(u8, tok, ']') orelse return null;
    if (close < open) return null;
    const inner = std.mem.trim(u8, tok[open + 1 .. close], " \t");
    if (inner.len == 0) return null;

    // Find the first + or - AFTER the first character, so a leading sign is not
    // mistaken for the separator and register names stay intact.
    var split: ?usize = null;
    var i: usize = 1;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '+' or inner[i] == '-') {
            split = i;
            break;
        }
    }
    if (split) |at| {
        const reg = std.mem.trim(u8, inner[0..at], " \t");
        const disp = std.mem.trim(u8, inner[at..], " \t");
        if (reg.len == 0 or disp.len == 0) return null;
        return .{ .reg = reg, .disp = disp };
    }
    return .{ .reg = inner, .disp = "0" };
}

/// `offset=12` -> { name = "offset", value = "12" }.
pub fn splitNameValue(field: []const u8) ?struct { name: []const u8, value: []const u8 } {
    const eq = std.mem.indexOfScalar(u8, field, '=') orelse return null;
    return .{
        .name = std.mem.trim(u8, field[0..eq], " \t"),
        .value = std.mem.trim(u8, field[eq + 1 ..], " \t"),
    };
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

fn assembleOk(source: []const u8) !u64 {
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    var d: Diagnostic = .{};
    const prog = assembler.assembleSource("test.asm", source, &d) catch {
        std.debug.print("unexpected diagnostic: {}\n", .{d});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(@as(usize, 1), prog.words.len);
    return prog.words[0];
}

/// Assembles a whole program and returns its Program. Unlike `assembleOk` this
/// makes no claim about instruction count — use it for multi-instruction tests
/// (labels, layout), where the single-word guarantee does not apply.
///
/// The caller owns the result and must free it with `prog.deinit()`. The
/// assembler is deliberately NOT deinited: `assembleSource` returns a
/// *value copy* of its arena, and that copy shares the same node list, so
/// freeing both would free the same nodes twice and abort.
fn assembleProgram(source: []const u8) !Program {
    var assembler = Assembler.init(testing.allocator);
    var d: Diagnostic = .{};
    return assembler.assembleSource("test.asm", source, &d) catch {
        // Nothing was handed over on failure, so the arena is still ours.
        assembler.deinit();
        std.debug.print("unexpected diagnostic: {}\n", .{d});
        return error.TestUnexpectedResult;
    };
}

fn assembleOne(source: []const u8) !Instruction {
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    var d: Diagnostic = .{};
    _ = assembler.assembleSource("test.asm", source, &d) catch {
        std.debug.print("unexpected diagnostic: {}\n", .{d});
        return error.TestUnexpectedResult;
    };
    return assembler.last;
}

/// Test-only reverse reader for one encoded word. It mirrors the §2 field
/// layout so the assembler's encoder can be checked without importing the
/// decoder module, which another agent owns.
fn parseWordForTest(word: u64) Instruction {
    const op: Opcode = @enumFromInt(@as(u8, @truncate(word >> 56)));
    var insn = Instruction{
        .opcode = op,
        .rd = @truncate(word >> 52),
        .rs1 = @truncate(word >> 48),
    };
    switch (op.kind()) {
        .field => {
            insn.field_offset = @truncate(word >> 40);
            insn.field_width = @truncate(word >> 32);
            insn.rs2 = @truncate(word >> 28);
        },
        .stream => {
            insn.rs2 = @truncate(word >> 44);
            insn.chunk = @truncate(word >> 24);
        },
        .alu, .compare_select => {
            insn.rs2 = @truncate(word >> 44);
            insn.width = @enumFromInt(@as(u4, @truncate(word >> 40)));
        },
        else => {},
    }
    return insn;
}

test "spec example: stream.add parses" {
    const insn = try assembleOne("stream.add R0, [R1]+CHUNK_SIZE, R2");
    try testing.expectEqual(Opcode.stream_add, insn.opcode);
    try testing.expectEqual(@as(u4, 0), insn.rd);
    try testing.expectEqual(@as(u4, 1), insn.rs1);
}

test "spec example: compare with arrow parses" {
    const insn = try assembleOne("compare R0, R1 -> R2");
    try testing.expectEqual(Opcode.compare, insn.opcode);
    try testing.expectEqual(@as(u4, 0), insn.rs1);
    try testing.expectEqual(@as(u4, 2), insn.rd);
}

test "spec example: select parses" {
    const insn = try assembleOne("select R3, R2, [EQUAL], R4, R5");
    try testing.expectEqual(Opcode.select, insn.opcode);
    try testing.expectEqual(@as(u4, 3), insn.rd);
    try testing.expectEqual(@as(u4, 2), insn.rs1);
}

test "spec example: field.extract with named operands parses" {
    const insn = try assembleOne("field.extract R0, R1, offset=12, width=3");
    try testing.expectEqual(Opcode.field_extract, insn.opcode);
    try testing.expectEqual(@as(u4, 0), insn.rd);
    try testing.expectEqual(@as(u4, 1), insn.rs1);
    try testing.expectEqual(@as(u8, 12), insn.field_offset);
    try testing.expectEqual(@as(u8, 3), insn.field_width);
}

test "all four spec examples encode to distinct words" {
    const a = try assembleOk("stream.add R0, [R1]+CHUNK_SIZE, R2");
    const b = try assembleOk("compare R0, R1 -> R2");
    const c = try assembleOk("select R3, R2, [EQUAL], R4, R5");
    const d = try assembleOk("field.extract R0, R1, offset=12, width=3");
    try testing.expect(a != b and b != c and c != d and a != d);
    try testing.expectEqual(@as(u8, 0x40), @as(u8, @truncate(a >> 56)));
    try testing.expectEqual(@as(u8, 0x20), @as(u8, @truncate(b >> 56)));
    try testing.expectEqual(@as(u8, 0x21), @as(u8, @truncate(c >> 56)));
    try testing.expectEqual(@as(u8, 0x30), @as(u8, @truncate(d >> 56)));
}

test "sub-register width suffixes encode into the §5 width field" {
    const cases = [_]struct { src: []const u8, want: Width, encoded: u64 }{
        .{ .src = "add R0, R1, R2", .want = .full, .encoded = 0 },
        .{ .src = "add R0.l, R1, R2", .want = .l, .encoded = 1 },
        .{ .src = "add R0.w, R1, R2", .want = .w, .encoded = 2 },
        .{ .src = "add R0.b, R1, R2", .want = .b, .encoded = 3 },
    };
    for (cases) |c| {
        const word = try assembleOk(c.src);
        const width_field = (word >> 40) & 0xF;
        try testing.expectEqual(c.encoded, width_field);
    }
}

test "comments, blank lines and arbitrary whitespace are tolerated" {
    const source = "# leading comment\n\n   add    R0,   R1,    R2     # trailing comment\n\n# another comment\n\tsub R3,R4,R5\n";
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    var d: Diagnostic = .{};
    const prog = try assembler.assembleSource("ws.asm", source, &d);
    try testing.expectEqual(@as(usize, 2), prog.words.len);
}

test "malformed operand yields a diagnostic with line number and offending text" {
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    var d: Diagnostic = .{};
    const result = assembler.assembleSource("bad.asm", "add R0, R99, R2\n", &d);
    try testing.expectError(error.AssemblyFailed, result);

    try testing.expectEqual(@as(?usize, 1), d.line);
    try testing.expect(d.operand != null);
    try testing.expectEqualStrings("R99", d.operand.?.text);
    try testing.expect(d.word == null); // not a hex-code error

    var buf: [512]u8 = undefined;
    const text = diag.renderToBuffer(d, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "R99") != null);
    try testing.expect(std.mem.indexOf(u8, text, "line 1") != null);
    try testing.expect(!diag.hasBareHexCode(text));
}

test "unknown mnemonic is reported with the line number and text, not skipped" {
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    var d: Diagnostic = .{};
    const result = assembler.assembleSource("bad.asm", "nop\nfrobnicate R0\nhalt\n", &d);
    try testing.expectError(error.AssemblyFailed, result);
    try testing.expectEqual(@as(?usize, 2), d.line);
    try testing.expect(std.mem.indexOf(u8, d.offending.?, "frobnicate") != null);
    // The program stopped; it did not quietly continue to `halt`.
    try testing.expectEqual(@as(usize, 1), assembler.words.items.len);
}

test "field constraints are diagnosed at assembly time" {
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();

    var d: Diagnostic = .{};
    try testing.expectError(
        error.AssemblyFailed,
        assembler.assembleSource("f.asm", "field.extract R0, R1, offset=12, width=0\n", &d),
    );
    try testing.expectEqual(@as(?usize, 1), d.line);

    var asm_b = Assembler.init(testing.allocator);
    defer asm_b.deinit();
    var d2: Diagnostic = .{};
    try testing.expectError(
        error.AssemblyFailed,
        asm_b.assembleSource("f.asm", "field.extract R0, R1, offset=60, width=8\n", &d2),
    );

    var asm_c = Assembler.init(testing.allocator);
    defer asm_c.deinit();
    var d3: Diagnostic = .{};
    try testing.expectError(
        error.AssemblyFailed,
        asm_c.assembleSource("f.asm", "field.extract R0, R1, offset=12\n", &d3),
    );
}

test "no spill warning for ordinary code that reuses registers" {
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    var d: Diagnostic = .{};
    _ = try assembler.assembleSource("ok.asm", "add R0, R1, R2\nadd R0, R3, R4\nsub R0, R5, R6\n", &d);
    try testing.expectEqual(@as(usize, 0), assembler.warnings.items.len);
}

test "spill warning fires when software exceeds the 12 GPRs (AGENTS.md §4.3)" {
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    var d: Diagnostic = .{};
    // All twelve GPRs become live destinations inside one window, so the file is
    // full and the next value the software wants to keep has nowhere to go.
    const source =
        "add R0, R1, R1\nadd R1, R2, R2\nadd R2, R3, R3\nadd R3, R4, R4\n" ++
        "add R4, R5, R5\nadd R5, R6, R6\nadd R6, R7, R7\nadd R7, R8, R8\n" ++
        "add R8, R9, R9\nadd R9, R10, R10\nadd R10, R11, R11\nadd R11, R0, R0\n";
    _ = try assembler.assembleSource("spill.asm", source, &d);

    try testing.expect(assembler.warnings.items.len >= 1);
    var buf: [512]u8 = undefined;
    const text = diag.renderToBuffer(assembler.warnings.items[0], &buf);
    try testing.expect(std.mem.startsWith(u8, text, "warning:"));
    try testing.expect(std.mem.indexOf(u8, text, "12 general-purpose registers") != null);
    try testing.expect(!diag.hasBareHexCode(text));
}

test "spill warning fires at most once per program" {
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    var d: Diagnostic = .{};
    const burst = "add R0, R1, R1\nadd R1, R2, R2\nadd R2, R3, R3\nadd R3, R4, R4\nadd R4, R5, R5\nadd R5, R6, R6\nadd R6, R7, R7\nadd R7, R8, R8\nadd R8, R9, R9\nadd R9, R10, R10\nadd R10, R11, R11\nadd R11, R0, R0\n";
    // Repeated bursts must not produce a wall of warnings. Built on the arena
    // the assembler already owns, so there is nothing extra to free.
    const source = try std.mem.concat(assembler.allocator(), u8, &.{ burst, burst, burst, burst });
    _ = try assembler.assembleSource("spill.asm", source, &d);
    try testing.expectEqual(@as(usize, 1), assembler.warnings.items.len);
}

test "select rejects an unknown status enum name" {
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    var d: Diagnostic = .{};
    try testing.expectError(
        error.AssemblyFailed,
        assembler.assembleSource("s.asm", "select R3, R2, [MAYBE], R4, R5\n", &d),
    );
    try testing.expect(std.mem.indexOf(u8, d.operand.?.text, "MAYBE") != null);
}

test "stream.add rejects a pointer without brackets" {
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    var d: Diagnostic = .{};
    try testing.expectError(
        error.AssemblyFailed,
        assembler.assembleSource("st.asm", "stream.add R0, R1, R2\n", &d),
    );
    try testing.expectEqualStrings("R1", d.operand.?.text);
}

test "status enum names round-trip through the token parser" {
    try testing.expectEqual(Status.EQUAL, Status.fromToken("EQUAL").?);
    try testing.expectEqual(Status.UNSIGNED_LESS, Status.fromToken("UNSIGNED_LESS").?);
    try testing.expectEqual(Status.UNSIGNED_LESS, Status.fromToken("unsigned_less").?);
    try testing.expect(Status.fromToken("NOPE") == null);
}

test "every opcode in the map has a mnemonic that parses back to it" {
    inline for (@typeInfo(Opcode).@"enum".field_values) |fv| {
        const op: Opcode = @enumFromInt(fv);
        // `.accelerator` is a sentinel carrying no mnemonic of its own; the §3.6
        // names are covered by the round-trip test below.
        if (op == .accelerator) continue;
        const parsed = Opcode.fromMnemonic(op.mnemonic());
        try testing.expect(parsed != null);
        try testing.expectEqual(op, parsed.?);
    }
}

test "DELIBERATE CONTRACT UPDATE 1.1: accelerator mnemonics now ASSEMBLE" {
    // This test previously asserted the opposite, under docs/isa-encoding.md v1.0,
    // where §3.6 deferred the operand layout to the model modules and this build
    // therefore refused the mnemonics. Amendment 1.1 makes the layout normative,
    // so they assemble for real. The assertion is inverted ON PURPOSE - it is a
    // contract-driven behaviour change, not a regression fix.
    //
    // What the test still guards: the original defect was `fromAccelerator`
    // fabricating a tag by arithmetic (`@enumFromInt(base + op_name.len)`), which
    // aborted the process with "invalid enum value". The loop below proves every
    // §3.6 mnemonic assembles AND that a name that only LOOKS like one still
    // produces a sentence rather than a panic.
    for (accelerators) |a| {
        var assembler = Assembler.init(testing.allocator);
        defer assembler.deinit();
        var d: Diagnostic = .{};

        // Build a well-formed line: rd, then one register per declared source.
        var line_buf: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&line_buf);
        try w.print("{s} R0", .{a.name});
        var i: u2 = 0;
        while (i < a.sources) : (i += 1) {
            try w.print(", R{d}", .{i + 1});
        }
        if (a.takes_count) try w.writeAll(", count=8");
        try w.writeAll("\n");

        const prog = try assembler.assembleSource("accel.asm", w.buffered(), &d);
        try testing.expectEqual(@as(usize, 1), prog.words.len);

        // The opcode byte really is the §3.6 one.
        try testing.expectEqual(a.opcode, @as(u8, @truncate(prog.words[0] >> 56)));
    }

    // A near-miss name is still REPORTED, not fabricated into a panic.
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    var d: Diagnostic = .{};
    try testing.expectError(
        error.AssemblyFailed,
        assembler.assembleSource("accel.asm", "matrix.frobnicate R0, R1\n", &d),
    );
    var buf: [512]u8 = undefined;
    const rendered = diag.renderToBuffer(d, &buf);
    try testing.expect(std.mem.endsWith(u8, rendered, "."));
    try testing.expect(!diag.hasBareHexCode(rendered));
}

test "the assembler accepts the disassembler's own address-prefixed output" {
    // `celeris64 dis a.bin > a.asm` then `celeris64 asm a.asm b.bin` must work
    // without the user stripping the "000000:  " prefix by hand. Requiring that
    // strip was a real trap: it silently produced an empty file when the prefix
    // was left in.
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    var d: Diagnostic = .{};
    const source = "000000:  add R0, R1, R2\n000008:  halt\n";
    const prog = try assembler.assembleSource("dis.asm", source, &d);
    try testing.expectEqual(@as(usize, 2), prog.words.len);
    try testing.expectEqual(@as(u8, 0x10), @as(u8, @truncate(prog.words[0] >> 56)));
    try testing.expectEqual(@as(u8, 0x01), @as(u8, @truncate(prog.words[1] >> 56)));
}

test "an address prefix is only stripped when it is really a hex prefix" {
    // A colon elsewhere in the line must not be treated as a prefix separator.
    try testing.expectEqualStrings("add R0, R1, R2", stripAddressPrefix("000000:  add R0, R1, R2"));
    try testing.expectEqualStrings("add R0, R1, R2", stripAddressPrefix("add R0, R1, R2"));
    // Non-hex prefix text is left alone so the diagnostic can quote it.
    try testing.expectEqualStrings("nope: thing", stripAddressPrefix("nope: thing"));
}

test "F7 REGRESSION: T0-T7 yields mask 0xFF and never aborts" {
    // The contract's own §3.7 example aborted with SIGABRT. Two bugs on one line:
    // `var i: u3` overflowed at 7 -> 8, and `@as(u5,1) << i` is an illegal shift
    // for i == 8. A panic is not a diagnostic (AGENTS.md §4.2, contract §7).
    const cases = [_]struct { text: []const u8, want: u8 }{
        .{ .text = "thread.spawn T0-T7, R0\n", .want = 0xFF },
        .{ .text = "thread.join T0-T7\n", .want = 0xFF },
        .{ .text = "thread.spawn T7, R0\n", .want = 0x80 },
        .{ .text = "thread.spawn T5, R0\n", .want = 0x20 },
        // §3.7's canonical enumerated form must agree with the range shorthand.
        .{ .text = "thread.spawn T0, T1, T2, T3, T4, T5, T6, T7, R0\n", .want = 0xFF },
    };
    for (cases) |c| {
        var assembler = Assembler.init(testing.allocator);
        defer assembler.deinit();
        var d: Diagnostic = .{};
        const prog = try assembler.assembleSource("t.asm", c.text, &d);
        try testing.expectEqual(@as(usize, 1), prog.words.len);
        try testing.expectEqual(@as(u64, c.want), prog.words[0] & 0xFF);
    }
}

test "F7 REGRESSION: a reversed range is a sentence, not a silence or a mirror" {
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    var d: Diagnostic = .{};
    try testing.expectError(
        error.AssemblyFailed,
        assembler.assembleSource("t.asm", "thread.join T7-T0\n", &d),
    );
    try testing.expect(d.line != null);
    var buf: [512]u8 = undefined;
    const text = diag.renderToBuffer(d, &buf);
    try testing.expect(std.mem.endsWith(u8, text, "."));
    try testing.expect(!diag.hasBareHexCode(text));
}

test "the slot mask is 8 bits wide, so T5/T6/T7 are representable" {
    // §3.7 defines eight slots. The mask field was a u5, which silently made the
    // top three slots unrepresentable even before the range bug.
    const cases = [_]struct { text: []const u8, want: u8 }{
        .{ .text = "thread.join T5\n", .want = 0x20 },
        .{ .text = "thread.join T6\n", .want = 0x40 },
        .{ .text = "thread.join T7\n", .want = 0x80 },
    };
    for (cases) |c| {
        var assembler = Assembler.init(testing.allocator);
        defer assembler.deinit();
        var d: Diagnostic = .{};
        const prog = try assembler.assembleSource("t.asm", c.text, &d);
        try testing.expectEqual(@as(u64, c.want), prog.words[0] & 0xFF);
    }
}

test "F8 REGRESSION: PC is rejected in rd and in both source positions" {
    // §4 makes writing PC in rd a diagnostic error outside jump forms, and
    // reading PC in rs1/rs2 always an error. Unchecked, the write was silently
    // DISCARDED at run time (the VM re-derives PC from the instruction stride),
    // so the user got no signal whatsoever.
    const bad = [_][]const u8{
        "add PC, R1, R2\n",
        "add R0, PC, R1\n",
        "add R0, R1, PC\n",
        "sub PC, R1, R2\n",
        "compare PC, R1 -> R2\n",
        "compare R0, PC -> R2\n",
    };
    for (bad) |text| {
        var assembler = Assembler.init(testing.allocator);
        defer assembler.deinit();
        var d: Diagnostic = .{};
        try testing.expectError(
            error.AssemblyFailed,
            assembler.assembleSource("pc.asm", text, &d),
        );
        try testing.expect(d.line != null);
        var buf: [512]u8 = undefined;
        const rendered = diag.renderToBuffer(d, &buf);
        try testing.expect(std.mem.endsWith(u8, rendered, "."));
        try testing.expect(!diag.hasBareHexCode(rendered));
    }
}

test "F8 POSITIVE: SP, LR and FLAGS remain legal in rd and in sources" {
    // §4 permits SP/LR/FLAGS as destinations AND as sources. This positive case
    // is what proves the PC check did not over-reach into "reject system
    // registers", which would break legal programs.
    const legal = [_][]const u8{
        "add FLAGS, R1, R2\n",
        "add SP, R1, R2\n",
        "add LR, R1, R2\n",
        "mov SP, 5\n",
        "mov LR, 7\n",
        "add R0, SP, LR\n",
        "add R0, R1, FLAGS\n",
    };
    for (legal) |text| {
        var assembler = Assembler.init(testing.allocator);
        defer assembler.deinit();
        var d: Diagnostic = .{};
        const prog = try assembler.assembleSource("ok.asm", text, &d);
        try testing.expectEqual(@as(usize, 1), prog.words.len);
    }
}

test "SLOT MASK BIT POSITION: operand[7:0] is the mask, operand[47:8] is reserved" {
    // No test pinned the mask's BIT POSITION, which is why a five-bit field
    // (`operand[4:0]`) survived seven contract revisions, a decoder, a
    // disassembler and an adversarial verifier. `T0-T7` writes 0xFF, so under the
    // old width it also set the "reserved" bits above the mask — the section
    // forbade the very word its own slot range required.
    //
    // T7 IS THE IMPORTANT VECTOR: a 5-bit mask holds T0-T4 and silently loses
    // T5-T7. A test asserting only T0 would pass under BOTH widths.
    const cases = [_]struct { text: []const u8, mask: u8 }{
        .{ .text = "thread.spawn T0, R0\n", .mask = 0x01 },
        .{ .text = "thread.spawn T7, R0\n", .mask = 0x80 },
        .{ .text = "thread.spawn T0-T7, R0\n", .mask = 0xFF },
        .{ .text = "thread.join T7\n", .mask = 0x80 },
        .{ .text = "thread.join T0-T7\n", .mask = 0xFF },
        .{ .text = "thread.join T0, T7\n", .mask = 0x81 },
    };
    for (cases) |c| {
        var assembler = Assembler.init(testing.allocator);
        defer assembler.deinit();
        var d: Diagnostic = .{};
        const prog = try assembler.assembleSource("t.asm", c.text, &d);
        const word = prog.words[0];
        const operand: u48 = @truncate(word);

        // The mask lives in the low byte.
        try testing.expectEqual(@as(u8, c.mask), @as(u8, @truncate(operand)));
        // And NOTHING spills into the reserved region above it.
        try testing.expectEqual(@as(u40, 0), @as(u40, @truncate(operand >> 8)));
    }
}

test "SLOT MASK ROUND TRIP: T7 and T0-T7 survive asm -> dis -> asm" {
    const words = [_][]const u8{
        "thread.spawn T7, R0\n",
        "thread.spawn T0-T7, R0\n",
        "thread.join T7\n",
        "thread.join T0-T7\n",
    };
    for (words) |text| {
        var assembler = Assembler.init(testing.allocator);
        defer assembler.deinit();
        var d: Diagnostic = .{};
        const prog = try assembler.assembleSource("t.asm", text, &d);

        // The canonical form enumerates every slot individually.
        var buf: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try writeThreadCanonical(prog.words[0], &w);

        var again = Assembler.init(testing.allocator);
        defer again.deinit();
        var d2: Diagnostic = .{};
        const prog2 = try again.assembleSource("t2.asm", w.buffered(), &d2);
        try testing.expectEqual(prog.words[0], prog2.words[0]);
    }
}

/// Renders a thread word's mask in §3.7 canonical form, for the round-trip test
/// above. Kept local so this test does not depend on the disassembler's writer.
fn writeThreadCanonical(word: u64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const operand: u48 = @truncate(word);
    const mask: u8 = @truncate(operand);
    const rs1: u4 = @truncate(word >> 48);
    const op: u8 = @truncate(word >> 56);
    try w.print("{s} ", .{if (op == 0x90) "thread.spawn" else "thread.join"});
    if (mask == 0) {
        try w.writeAll("no slots");
    } else {
        var first = true;
        for (0..8) |slot| {
            if (mask & (@as(u8, 1) << @intCast(slot)) == 0) continue;
            if (!first) try w.writeAll(", ");
            try w.print("T{d}", .{slot});
            first = false;
        }
    }
    if (op == 0x90) {
        const names = [_][]const u8{ "R0", "R1", "R2", "R3", "R4", "R5", "R6", "R7", "R8", "R9", "R10", "R11", "SP", "LR", "PC", "FLAGS" };
        try w.print(", {s}", .{names[rs1]});
    }
    try w.writeAll("\n");
}

test "F1 REGRESSION: the four stream.* width suffixes produce four DISTINCT words" {
    // The defect was invisible precisely because no test COMPARED the four. All
    // four encoded to 0x4001200004000000 with width[23:20] == 0, so `.w`/`.l`/`.b`
    // were accepted and thrown away with no warning — the same silent-input class
    // as F8 (`add PC, ...`).
    const cases = [_]struct { text: []const u8, width: u4 }{
        .{ .text = "stream.add R0, [R1]+4, R2\n", .width = 0 },
        .{ .text = "stream.add R0.l, [R1]+4, R2\n", .width = 1 },
        .{ .text = "stream.add R0.w, [R1]+4, R2\n", .width = 2 },
        .{ .text = "stream.add R0.b, [R1]+4, R2\n", .width = 3 },
    };
    var seen: [4]u64 = undefined;
    for (cases, 0..) |c, i| {
        var assembler = Assembler.init(testing.allocator);
        defer assembler.deinit();
        var d: Diagnostic = .{};
        const prog = try assembler.assembleSource("sw.asm", c.text, &d);
        const word = prog.words[0];
        // §3.4 operand[23:20] carries the §5 width value directly.
        try testing.expectEqual(@as(u64, c.width), (word >> 20) & 0xF);
        seen[i] = word;
    }
    // Four distinct words: this is the assertion the old code would have failed.
    for (seen, 0..) |a, i| {
        for (seen[i + 1 ..]) |b| try testing.expect(a != b);
    }
}

test "F1 REGRESSION: every stream.* width round-trips and none is silently dropped" {
    const lines = [_][]const u8{
        "stream.add R0, [R1]+4, R2\n",
        "stream.add R0.l, [R1]+4, R2\n",
        "stream.add R0.w, [R1]+4, R2\n",
        "stream.add R0.b, [R1]+4, R2\n",
        "stream.copy R0.b, [R1]+8\n",
        "stream.fill R0.w, [R1]+2\n",
    };
    for (lines) |text| {
        var assembler = Assembler.init(testing.allocator);
        defer assembler.deinit();
        var d: Diagnostic = .{};
        const prog = try assembler.assembleSource("sw.asm", text, &d);
        try testing.expectEqual(@as(usize, 1), prog.words.len);
    }
}

test "F1: stream.setp has no element width, so a suffix is REFUSED" {
    // `stream.setp R0.w, 128` produced the SAME word as `stream.setp R0, 128`,
    // i.e. the suffix was silently discarded — the identical silent-input defect.
    // §3.4 gives setp a byte stride in operand[39:0] and no width field.
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    var d: Diagnostic = .{};
    try testing.expectError(
        error.AssemblyFailed,
        assembler.assembleSource("sp.asm", "stream.setp R0.w, 128\n", &d),
    );
    try testing.expect(d.line != null);
    var buf: [512]u8 = undefined;
    const rendered = diag.renderToBuffer(d, &buf);
    try testing.expect(std.mem.endsWith(u8, rendered, "."));
    try testing.expect(!diag.hasBareHexCode(rendered));

    // The legal form is unchanged.
    var ok = Assembler.init(testing.allocator);
    defer ok.deinit();
    var d2: Diagnostic = .{};
    const prog = try ok.assembleSource("sp.asm", "stream.setp R0, 549755813887\n", &d2);
    try testing.expectEqual(@as(u64, 0x4300000000000000) | 549755813887, prog.words[0]);
}

test "F12 REGRESSION: a third cap.* register is a diagnostic, not a silent discard" {
    // §3.5 Amendment 1.11: rs2 is unused and must be zero. Before this,
    // `cap.load R2, R3, R4` encoded rs2 = 4 into operand[47:44] (word
    // 0x5023400000000000) and the decoder's `Cap` struct — which has only
    // op/rd/rs1 — could not reach it, so R4 vanished: the word disassembled as
    // `cap.load R2, R3`. Same silent-input class as F1 and F8.
    //
    // NOTE the operand index is asserted too: `index` previously counted
    // FAILURES rather than positions, so the second operand reported as
    // "operand 1". Positional numbering is part of naming the offending operand.
    const bad = [_]struct { text: []const u8, index: usize, tok: []const u8 }{
        .{ .text = "cap.load R2, R4, R8\n", .index = 3, .tok = "R8" },
        .{ .text = "cap.store R2, R4, R6\n", .index = 3, .tok = "R6" },
        .{ .text = "cap.check R1, R2, R4\n", .index = 3, .tok = "R4" },
    };
    for (bad) |c| {
        var assembler = Assembler.init(testing.allocator);
        defer assembler.deinit();
        var d: Diagnostic = .{};
        try testing.expectError(
            error.AssemblyFailed,
            assembler.assembleSource("c.asm", c.text, &d),
        );
        try testing.expect(d.line != null);
        try testing.expectEqual(c.index, d.operand.?.index);
        try testing.expectEqualStrings(c.tok, d.operand.?.text);

        var buf: [512]u8 = undefined;
        const rendered = diag.renderToBuffer(d, &buf);
        try testing.expect(std.mem.endsWith(u8, rendered, "."));
        try testing.expect(!diag.hasBareHexCode(rendered));
    }
}

test "F12 POSITIVE CONTROL: the legal two-register cap.* forms still assemble" {
    // Without this, the rejection test above could pass for the wrong reason —
    // e.g. if cap.* were rejected wholesale.
    const good = [_]struct { text: []const u8, op: u8, rd: u4, rs1: u4 }{
        .{ .text = "cap.load R2, R4\n", .op = 0x50, .rd = 2, .rs1 = 4 },
        .{ .text = "cap.store R2, R4\n", .op = 0x51, .rd = 2, .rs1 = 4 },
        .{ .text = "cap.check R1, R2\n", .op = 0x52, .rd = 1, .rs1 = 2 },
        .{ .text = "cap.load R0, R2\n", .op = 0x50, .rd = 0, .rs1 = 2 },
    };
    for (good) |c| {
        var assembler = Assembler.init(testing.allocator);
        defer assembler.deinit();
        var d: Diagnostic = .{};
        const prog = try assembler.assembleSource("c.asm", c.text, &d);
        const word = prog.words[0];

        // Assert the real bit pattern, not an assumption about it.
        try testing.expectEqual(@as(u64, c.op), word >> 56);
        try testing.expectEqual(@as(u64, c.rd), (word >> 52) & 0xF);
        try testing.expectEqual(@as(u64, c.rs1), (word >> 48) & 0xF);
        // §3.5 v1.11: operand[47:0] is reserved and must be zero.
        try testing.expectEqual(@as(u64, 0), word & ((@as(u64, 1) << 48) - 1));
    }
}

test "F12: the cap.* even-index rule for pairs, and its cap.check exemption" {
    // §3.5 v1.11: for cap.load/cap.store the low register index must be EVEN,
    // because a descriptor occupies two consecutive registers and an odd index
    // would overlap its neighbour.
    // Only ONE register names the pair (§3.5 v1.12): `rd` for cap.load, `rs1`
    // for cap.store. The other register is an ordinary operand and any index is
    // legal for it.
    const odd_pair = [_][]const u8{
        "cap.load R3, R2\n", // odd destination IS the pair -> rejected
        "cap.store R2, R3\n", // odd source IS the pair -> rejected
    };
    for (odd_pair) |text| {
        var assembler = Assembler.init(testing.allocator);
        defer assembler.deinit();
        var d: Diagnostic = .{};
        try testing.expectError(
            error.AssemblyFailed,
            assembler.assembleSource("c.asm", text, &d),
        );
        // Names the offending register, and the text is in the sentence.
        try testing.expect(d.operand != null);
        var buf: [512]u8 = undefined;
        const rendered = diag.renderToBuffer(d, &buf);
        try testing.expect(!diag.hasBareHexCode(rendered));
    }

    // POSITIVE CONTROL (F14). The old control used only even registers for the
    // NON-pair operand, so "both must be even" was invisible: every input passed
    // under the over-reaching rule too. These inputs contain the failing case —
    // an ODD register in the non-pair position must assemble.
    // Words asserted below are the actual assembled output, printed first.
    const odd_non_pair = [_]struct { text: []const u8, word: u64 }{
        // cap.load R2, R3: opcode 0x50, rd=R2, rs1=R3, reserved operand field == 0
        .{ .text = "cap.load R2, R3\n", .word = 0x5023000000000000 },
        // cap.store R3, R2: opcode 0x51, rd=R3, rs1=R2, reserved operand field == 0
        .{ .text = "cap.store R3, R2\n", .word = 0x5132000000000000 },
    };
    for (odd_non_pair) |case| {
        var assembler = Assembler.init(testing.allocator);
        defer assembler.deinit();
        var d: Diagnostic = .{};
        const prog = try assembler.assembleSource("c.asm", case.text, &d);
        try testing.expectEqual(@as(usize, 1), prog.words.len);
        try testing.expectEqual(case.word, prog.words[0]);
    }

    // POSITIVE CONTROL: even indices are accepted, including the upper registers.
    const even = [_][]const u8{ "cap.load R0, R2\n", "cap.load R4, R6\n", "cap.store R8, R10\n" };
    for (even) |text| {
        var assembler = Assembler.init(testing.allocator);
        defer assembler.deinit();
        var d: Diagnostic = .{};
        const prog = try assembler.assembleSource("c.asm", text, &d);
        try testing.expectEqual(@as(usize, 1), prog.words.len);
    }

    // A surplus operand is blamed as the surplus operand, never as an odd pair
    // register beside it. `cap.load R3, R2, R4` is the discriminating case: rd=R3
    // is odd AND there is a surplus R4, so the two rejections compete. The surplus
    // wins because adding a third register is the mistake the user actually made,
    // and the third-operand message is the one that explains it.
    {
        var assembler = Assembler.init(testing.allocator);
        defer assembler.deinit();
        var d: Diagnostic = .{};
        try testing.expectError(
            error.AssemblyFailed,
            assembler.assembleSource("c.asm", "cap.load R3, R2, R4\n", &d),
        );
        try testing.expect(d.operand != null);
        try testing.expectEqual(@as(usize, 3), d.operand.?.index);
        var buf: [512]u8 = undefined;
        const rendered = diag.renderToBuffer(d, &buf);
        try testing.expect(std.mem.indexOf(u8, rendered, "R4") != null);
    }

    // cap.check is EXEMPT: its rs1 names a descriptor to test, not a pair this
    // instruction forms, so an odd register holding one is legal. Verified by
    // asserting it assembles rather than by asserting the rule's absence.
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    var d: Diagnostic = .{};
    const prog = try assembler.assembleSource("c.asm", "cap.check R1, R3\n", &d);
    try testing.expectEqual(@as(u64, 0x52), prog.words[0] >> 56);
    try testing.expectEqual(@as(u64, 1), (prog.words[0] >> 52) & 0xF);
    try testing.expectEqual(@as(u64, 3), (prog.words[0] >> 48) & 0xF);
}

test "labels: a forward reference resolves to the right address" {
    // A forward reference is the common case — a loop branches to a label
    // defined BELOW it — and it is why labels need a second pass at all.
    var prog = try assembleProgram(
        \\jump done
        \\nop
        \\nop
        \\done:
        \\halt
    );
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 4), prog.words.len);
    // `done` is the fourth instruction, so its address is 3 * 8 = 24.
    try testing.expectEqual(@as(u64, 24), prog.words[0] & 0xFFFF_FFFF_FFFF);
}

test "labels: a backward branch encodes a negative PC-relative offset" {
    // The offset is relative to the BRANCH ITSELF (§3.0.1), not to the
    // instruction before it and not to the one after it. The branch sits at
    // address 8; `top` is at address 0; so the offset is 0 - 8 = -8.
    var prog = try assembleProgram(
        \\top:
        \\nop
        \\branch R0, [EQUAL], top
    );
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 2), prog.words.len);
    const offset: i28 = @bitCast(@as(u28, @truncate(prog.words[1] & 0x0FFF_FFFF)));
    try testing.expectEqual(@as(i28, -8), offset);
}

test "labels: a label on the same line as an instruction still works" {
    var prog = try assembleProgram(
        \\jump there
        \\there: halt
    );
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 2), prog.words.len);
    // `halt` is the second instruction: address 8.
    try testing.expectEqual(@as(u64, 8), prog.words[0] & 0xFFFF_FFFF_FFFF);
}

test "labels: a duplicate definition is rejected, not silently resolved" {
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    var d: Diagnostic = .{};
    const result = assembler.assembleSource("dup.asm",
        \\x: nop
        \\x: halt
    , &d);
    try testing.expectError(error.AssemblyFailed, result);
    try testing.expectEqual(@as(usize, 2), d.line);
}

test "labels: an undefined reference is rejected, never patched to 0" {
    var assembler = Assembler.init(testing.allocator);
    defer assembler.deinit();
    var d: Diagnostic = .{};
    const result = assembler.assembleSource("undef.asm",
        \\jump nowhere
        \\halt
    , &d);
    try testing.expectError(error.AssemblyFailed, result);
    try testing.expectEqual(@as(usize, 1), d.line);
}

test "labels: a line that is only a label emits no instruction" {
    var assembler = Assembler.init(testing.allocator);
    // NOTE: no `defer assembler.deinit()` here. `assembleSource` MOVES the arena
    // into the returned Program on success, so freeing both is a double free.
    // The failure path is the only one that must free the assembler.
    var d: Diagnostic = .{};
    var prog = try assembler.assembleSource("label.asm",
        \\a:
        \\b:
        \\c:
        \\halt
    , &d);
    defer prog.deinit();
    try testing.expectEqual(@as(usize, 1), prog.words.len);
}

test "labels: a colon inside an operand is not mistaken for a label" {
    // `[R1+0]` contains no colon, but a future addressing mode might; the splitter
    // must only treat a leading identifier followed by ':' as a definition.
    const split = splitLabel("load R6, [R1+0]");
    try testing.expectEqual(@as(?[]const u8, null), split.label);
    try testing.expectEqualStrings("load R6, [R1+0]", split.rest);

    const yes = splitLabel("loop: add R1, R1, 1");
    try testing.expectEqualStrings("loop", yes.label.?);
    try testing.expectEqualStrings("add R1, R1, 1", yes.rest);
}
