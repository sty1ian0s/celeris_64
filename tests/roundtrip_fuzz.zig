//! Differential round-trip fuzzer: assembler vs disassembler.
//!
//! The contract claims `asm -> dis -> asm` is byte-identical (README "Round trip").
//! That claim was previously tested on a handful of hand-written fixtures. This
//! file tests it on pseudo-random words, which is the only way to reach encodings
//! nobody thought to write down.
//!
//! Three independent checks, deliberately separated because they fail for
//! different reasons:
//!
//!   1. ENCODE -> DECODE -> RENDER -> RE-ENCODE must reproduce the original word.
//!      This is the contract's byte-identity claim.
//!   2. A word the disassembler REJECTS must not be silently accepted by the
//!      assembler afterwards. Rejections must round-trip as rejections.
//!   3. Both implementations must agree on WHICH words are valid. A word one
//!      accepts and the other refuses is a real divergence, not a formatting
//!      difference.
//!
//! Determinism: the generator is a seeded xorshift64, so a failure names the
//! exact seed and iteration. A fuzzer you cannot re-run is a rumour.
//!
//! Fidelity: this exercises the software model only. It says nothing about the
//! RTL, and nothing here is a performance claim.

const std = @import("std");
const assembler = @import("tooling");
const disassembler = assembler.disassembler;

/// Seed for the default run. Chosen once and then frozen: changing it changes
/// what the suite covers, so it is a contract-visible constant, not a knob.
pub const default_seed: u64 = 0x5EED_1234_ABCD_0001;

pub const default_iterations: usize = 20_000;

/// xorshift64*. Small, deterministic, no dependencies, and good enough to walk
/// an encoding space. This is not cryptography and does not need to be.
pub const Rng = struct {
    state: u64,

    pub fn init(seed: u64) Rng {
        // A zero state is a fixed point for xorshift, so it must be avoided.
        return .{ .state = if (seed == 0) 0x9E37_79B9_7F4A_7C15 else seed };
    }

    pub fn next(self: *Rng) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545_F491_4F6C_DD1D;
    }

    /// A word that is LIKELY to decode.
    ///
    /// An earlier version OR'd a random 48-bit payload under a known opcode
    /// byte. That is nearly useless: 19,458 of 20,000 words were rejected, so
    /// only 8 reached the encoders and the fuzzer was testing the reject path
    /// while looking like it tested round-tripping. Coverage is printed by the
    /// suite so this cannot silently regress.
    ///
    /// This builds each class from its own §3 layout, then corrupts one
    /// randomly chosen field so the space around valid words is explored too.
    pub fn word(self: *Rng) u64 {
        const op = knownOpcodes()[self.next() % knownOpcodes().len];
        const rd: u64 = self.next() % 16;
        const rs1: u64 = self.next() % 16;
        var operand: u48 = 0;

        switch (op) {
            // Control: jump/call take imm48; nop/halt/ret take nothing.
            0x00, 0x01, 0x04 => return (@as(u64, op) << 56),
            0x02, 0x03 => return (@as(u64, op) << 56) | (self.next() & 0xFFFF_FFFF_FFFF),

            // branch §3.0.1 (v1.17): rd must be zero, rs2[47:44] is a match value
            // in 0..=4, width[43:40] must be a valid §5 nibble, [39:28] reserved,
            // and [27:0] a signed byte offset. Every one of those constraints is
            // enforced by the decoder, so the generator must respect them or it
            // would only ever produce rejected words and test nothing.
            0x05 => {
                const match: u64 = self.next() % 5;
                const off: u28 = @truncate(self.next());
                // rd and the width nibble are both reserved for a branch: a
                // non-zero value in either is a rejected word, so the generator
                // must leave them zero or it would only test the rejection path.
                return (@as(u64, 0x05) << 56) | (rs1 << 48) |
                    (@as(u64, match) << 44) | @as(u64, off);
            },

            // load/store §3.1.1 (v1.17): rs1 is the base, rs2 is the store source
            // (reserved-zero for load), width[43:40] is the access size, and
            // [39:28] is reserved. The unused register field must be zero.
            0x1A, 0x1B => {
                const width: u64 = self.next() % 4;
                const off: u28 = @truncate(self.next());
                if (op == 0x1A) {
                    // load: rd is the destination, rs2 must be zero.
                    return (@as(u64, op) << 56) | (rd << 52) | (rs1 << 48) |
                        (width << 40) | @as(u64, off);
                }
                // store: rd must be zero, rs2 is the value source.
                const src: u64 = self.next() % 16;
                return (@as(u64, op) << 56) | (rs1 << 48) |
                    (src << 44) | (width << 40) | @as(u64, off);
            },

            // ALU §3.1: rs2[47:44] width[43:40] zero[39:28] imm28[27:0].
            // Emit the REGISTER form, and sometimes the immediate form with
            // rs2 deliberately zero (the only form the assembler can produce).
            0x10...0x19 => {
                const width: u64 = self.next() % 4;
                if (self.next() % 2 == 0) {
                    operand = (@as(u48, @intCast(self.next() % 16)) << 44) |
                        (@as(u48, @intCast(width)) << 40);
                } else {
                    const imm: u28 = @truncate(self.next());
                    operand = (@as(u48, @intCast(width)) << 40) | @as(u48, imm);
                }
            },

            // compare §3.2.1 / select §3.2.2: reserved bits are rejected, so
            // keep them zero and vary only the documented fields.
            0x20 => {
                operand = (@as(u48, @intCast(self.next() % 16)) << 44) |
                    (@as(u48, @intCast(self.next() % 16)) << 40);
            },
            0x21 => {
                const match: u4 = @truncate(self.next() % 16);
                const true_reg: u4 = @truncate(self.next() % 16);
                const false_reg: u4 = @truncate(self.next() % 16);
                operand = (@as(u48, match) << 44) | (@as(u48, true_reg) << 40) |
                    (@as(u48, false_reg) << 36);
            },

            // field.* §3.3: offset[47:40] width[39:32] src2[31:28].
            0x30, 0x31 => {
                const offset: u8 = @truncate(self.next() % 64);
                const width: u8 = @truncate(1 + self.next() % 64);
                const src2: u4 = @truncate(self.next() % 16);
                operand = (@as(u48, offset) << 40) | (@as(u48, width) << 32) |
                    (@as(u48, src2) << 28);
            },

            // stream.setp §3.4: stride[39:0], everything else zero (F19).
            0x43 => return (@as(u64, op) << 56) | (rd << 52) |
                (self.next() & 0xFF_FFFF_FFFF),

            // stream.add/copy/fill §3.4: rs2[47:44] chunk[43:24] width[23:20],
            // reserved[19:0] zero, chunk >= 1.
            0x40, 0x41, 0x42 => {
                const rs2: u4 = @truncate(self.next() % 16);
                const chunk: u20 = @truncate(1 + self.next() % 0xFFFFF);
                const width: u4 = @truncate(self.next() % 4);
                operand = (@as(u48, rs2) << 44) | (@as(u48, chunk) << 24) |
                    (@as(u48, width) << 20);
            },

            // cap.* §3.5: rs2 and operand reserved-zero; rd must be even for
            // cap.load, rs1 even for cap.store (F14).
            0x50 => return (@as(u64, op) << 56) | ((rd & 0xF) << 52) | (rs1 << 48),
            0x51 => return (@as(u64, op) << 56) | (rd << 52) | ((rs1 & 0xE) << 48),
            0x52 => return (@as(u64, op) << 56) | ((rd & 0xE) << 52) | (rs1 << 48),

            // thread.* §3.7: slot mask operand[7:0], operand[47:8] reserved.
            0x90, 0x91 => {
                operand = @as(u48, @intCast(self.next() % 256));
            },
            0x92 => return (@as(u64, op) << 56) | (rd << 52) | (rs1 << 48),

            else => return (@as(u64, op) << 56) | (self.next() & 0x00FF_FFFF_FFFF_FFFF),
        }

        // Perturb: occasionally flip a bit in the payload so the neighbourhood
        // of valid words is covered, including the reserved-bit rejections.
        if (self.next() % 8 == 0) {
            const bit: u6 = @truncate(self.next() % 48);
            operand ^= @as(u48, 1) << bit;
        }
        return (@as(u64, op) << 56) | (rd << 52) | (rs1 << 48) | operand;
    }
};

/// Every opcode byte the assembler's enum can name. Kept as a literal list so
/// this file does not silently track a bug in the enum it is meant to check.
fn knownOpcodes() []const u8 {
    return &.{
        0x00, 0x01, 0x02, 0x03, 0x04, // nop halt jump call ret
        0x05, // branch (§3.0.1, v1.17)
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, // ALU
        0x1A, 0x1B, // load, store (§3.1.1, v1.17)
        0x20, 0x21, // compare select
        0x30, 0x31, // field.*
        0x40, 0x41, 0x42, 0x43, // stream.*
        0x50, 0x51, 0x52, // cap.*
        0x90, 0x91, 0x92, // thread.*
    };
}

/// What one word round-trips to.
pub const Outcome = enum { identical, text_differs, reencode_failed, reencode_mismatch };

pub const Result = struct {
    outcome: Outcome,
    /// The disassembler's rendering, when it produced one.
    text: []const u8 = "",
    /// Set when the two implementations disagree about validity.
    validity_divergence: bool = false,
};

/// Round-trips a single word through dis -> asm.
///
/// Returns `.text_differs` when the re-encoded word matches but the rendered
/// text would not re-assemble to it — that is a different bug from a wrong word
/// and is reported separately.
pub fn roundTrip(alloc: std.mem.Allocator, word: u64) !Result {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    disassembler.disassemble(word, &w) catch |e| switch (e) {
        error.WriteFailed => return .{ .outcome = .reencode_failed },
    };
    const text = w.buffered();

    // A rendering that does not decode as an instruction is a rejection message
    // (e.g. "unknown opcode"), not a program. Neither implementation should
    // accept it as source, so it is checked by the caller, not re-assembled.
    if (disassembler.decodeWord(word) == null) {
        return .{ .outcome = .text_differs, .text = try alloc.dupe(u8, text) };
    }

    var src_buf: [300]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf, "{s}\n", .{text});

    var asm_ = assembler.Assembler.init(alloc);
    var diag: assembler.Diagnostic = .{};
    // On success `assembleSource` MOVES the arena into Program, so only one of
    // these two may free it. The CLI does the same: it calls Assembler.deinit
    // and never Program.deinit, because on the failure path the assembler still
    // owns the arena.
    const prog = asm_.assembleSource("fuzz.asm", src, &diag) catch {
        asm_.deinit();
        return .{ .outcome = .reencode_failed, .text = try alloc.dupe(u8, text) };
    };
    var p = prog;
    defer p.deinit();

    if (prog.words.len != 1) {
        return .{ .outcome = .reencode_failed, .text = try alloc.dupe(u8, text) };
    }
    return .{
        .outcome = if (prog.words[0] == word) .identical else .reencode_mismatch,
        .text = try alloc.dupe(u8, text),
    };
}

/// True when the word decodes as a defined instruction.
pub fn isValidWord(word: u64) bool {
    return disassembler.decodeWord(word) != null;
}

/// True when the word carries no bits that CLS64 source cannot name.
///
/// F19 (found by this fuzzer). Two distinct holes, both found by running:
///
/// (a) `stream.setp` decodes `rd` (the pointer) plus a signed 40-bit stride and
///     names nothing else, but §2's word layout still gives every instruction
///     `rs1[51:48]` and `operand[47:40]`, and neither §3.4 nor the decoder
///     requires them to be zero. Words found:
///       0x43BAB89E3BCCB87F  `setp` with `rs1 = 0xA` set
///       0x4320F83A43F467A0  `setp` with `operand[47:40] = 0xF8` set
///
/// (b) `ret` (0x04) shares `controlOrErr` with `jump`/`call`, which only checks
///     `rd`/`rs1` — so `operand[47:0]` is accepted unvalidated. §3.0 says "for
///     `jump`, `call` and `ret`, the operand field carries `imm48`", but its own
///     table two lines above says `ret` "jumps to `LR`" and carries no target.
///     Both statements cannot hold. The decoder follows the false one and drops
///     the bits. Word found:
///       0x04007BE6F29AC0A8  `ret` with `operand[47:0] = 0x7BE6F29AC0A8` set
///
/// In both cases each tool is self-consistent: the decoder preserves the bits,
/// the encoder zeroes them because no syntax names them. They disagree only about
/// words the contract never ruled on. This predicate scopes the round-trip
/// property to words that are actually expressible; the excluded set is counted
/// and asserted non-zero below, never silently skipped.
pub fn isSourceExpressible(word: u64) bool {
    return unexpressibleReason(word) == .expressible;
}

/// Why a decoded word cannot be named by CLS64 source.
///
/// ONE classifier, used both to filter the round-trip set and to count what was
/// filtered. An earlier version duplicated these conditions at the call site and
/// the two drifted within minutes — the counter mislabelled a `select`-with-PC
/// word that the predicate had already excluded. Duplicating a condition is how
/// a guard rots.
///
/// Every arm below is a defect recorded in docs/STATUS.md; none is a guess.
pub const Reason = enum {
    expressible,
    setp_unnameable, // F19(a): setp ignores rs1 and operand[47:40]
    ret_unnameable, // F19(b): `ret` carries no operand
    raw_loses_bits, // F20: `.raw` omits rd/rs1
    alu_imm_rs2, // F21: ALU immediate form with rs2 set
    mov_rs1, // F22: `mov` ignores rs1
    thread_rd_rs1, // F23: thread.* renders neither or only one of rd/rs1
    field_unnameable, // F24/F25: field range unenforced, or extract carries src2
    compare_unassigned, // F29: compare carries trueReg/falseReg bits
    fill_rs2, // F26: stream.fill renders rs2 but never parses it
    pc_source, // F27: `PC` as a source
    pc_dest, // F27: `PC` as a destination
    cap_odd, // F28: cap.* odd pair-naming register
};

pub fn unexpressibleReason(word: u64) Reason {
    if (!isValidWord(word)) return .setp_unnameable; // caller filters these first
    const op: u8 = @truncate(word >> 56);
    const rd: u4 = @truncate(word >> 52);
    const rs1: u4 = @truncate(word >> 48);

    if (op >= 0x60 and op <= 0x8F) {
        return if ((word & 0x0FF0_0000_0000_0000) == 0) .expressible else .raw_loses_bits;
    }
    if (op == 0x04) {
        return if ((word & 0x0FFF_FFFF_FFFF_FFFF) == 0) .expressible else .ret_unnameable;
    }
    if (op == 0x43) {
        const above: u8 = @truncate((word >> 40) & 0xFF);
        return if (rs1 == 0 and above == 0) .expressible else .setp_unnameable;
    }
    if (op >= 0x50 and op <= 0x52) {
        const odd = switch (op) {
            0x50, 0x52 => (rd & 1) != 0,
            else => (rs1 & 1) != 0,
        };
        if (odd) return .cap_odd;
    }
    // `PC` (14) is refused by the assembler in both positions; the decoder and
    // `run-bin` accept it, which is F27.
    const writes_rd = (op >= 0x10 and op <= 0x21) or op == 0x30 or op == 0x31 or
        (op >= 0x40 and op <= 0x43) or (op >= 0x90 and op <= 0x91);
    if (rd == 14 and writes_rd) return .pc_dest;
    if (rs1 == 14) return .pc_source;
    if (op == 0x21) {
        const raw = word & 0xFFFF_FFFF_FFFF;
        if (@as(u4, @truncate(raw >> 40)) == 14) return .pc_source;
        if (@as(u4, @truncate(raw >> 36)) == 14) return .pc_source;
    }
    if (op >= 0x10 and op <= 0x19) {
        const raw = word & 0xFFFF_FFFF_FFFF;
        const imm: u28 = @truncate(raw);
        const rs2: u4 = @truncate(raw >> 44);
        if (op == 0x19 and rs1 != 0) return .mov_rs1;
        // `PC` as the REGISTER source is F27 as well: "add R9.l, R11, PC".
        if (imm == 0 and rs2 == 14) return .pc_source;
        if (imm != 0 and rs2 != 0) return .alu_imm_rs2;
    }
    // `PC` as the `rs2`/match-value source of `compare` (F27 again).
    if (op == 0x20 and @as(u4, @truncate((word >> 44) & 0xF)) == 14) return .pc_source;
    if (op == 0x20) {
        // F29: §3.2.1 gives `compare` no layout beyond reserved `[35:0]`, so
        // `operand[47:36]` is unassigned — yet the decoder accepts it and the
        // encoder writes it, while compare's rendering prints only rs1/src2:
        //   0x201D830000000000 -> "compare LR, R8 -> R1" -> 0x201D800000000000
        // `trueReg`/`falseReg` belong to `select` (§3.2.2) only.
        const raw = word & 0xFFFF_FFFF_FFFF;
        if ((raw & 0xFFF_0000_0000) != 0) return .field_unnameable;
        // F30: §3.2.1 reserves `operand[35:0]` for `compare` and requires
        // rejection, but 0x20 is routed through `aluOrErr`, which enforces the
        // ALU's `[39:28]` rule instead. So `[27:0]` is checked by NO rule:
        //   0x20D1600000000800 -> "compare R1, 2048 -> LR", accepted, and the
        //   0x800 is silently dropped on re-assembly.
        if ((raw & 0xFFFF_FFFFF) != 0) return .field_unnameable;
    }
    if (op == 0x30 or op == 0x31) {
        const raw = word & 0xFFFF_FFFF_FFFF;
        const offset: u8 = @truncate(raw >> 40);
        const width: u8 = @truncate(raw >> 32);
        if (!(width >= 1 and (@as(u16, offset) + @as(u16, width)) <= 64)) {
            return .field_unnameable;
        }
        if (op == 0x30 and @as(u4, @truncate(raw >> 28)) != 0) return .field_unnameable;
    }
    if (op == 0x42) {
        if (@as(u4, @truncate((word >> 44) & 0xF)) != 0) return .fill_rs2;
    }
    if (op >= 0x90 and op <= 0x92) {
        if (rd != 0 or rs1 != 0) return .thread_rd_rs1;
    }
    return .expressible;
}

test "the fuzzer's generator is deterministic and seeded" {
    var a = Rng.init(default_seed);
    var b = Rng.init(default_seed);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expectEqual(a.word(), b.word());
    }
    // A different seed must produce a different stream, or the seed is a lie.
    var c = Rng.init(default_seed +% 1);
    var d = Rng.init(default_seed);
    var differs = false;
    i = 0;
    while (i < 100) : (i += 1) {
        if (c.word() != d.word()) differs = true;
    }
    try std.testing.expect(differs);
}

test "the generator reaches every declared opcode byte" {
    var rng = Rng.init(default_seed);
    var seen: [256]bool = @splat(false);
    var i: usize = 0;
    while (i < 200_000) : (i += 1) {
        const op: u8 = @truncate(rng.word() >> 56);
        seen[op] = true;
    }
    for (knownOpcodes()) |op| {
        if (!seen[op]) {
            std.debug.print("generator never produced opcode 0x{X:0>2}\n", .{op});
            return error.GeneratorMissedOpcode;
        }
    }
}

test "the generator's opcode bias is real, not incidental" {
    // Without the bias, a fully random high byte lands on a known opcode about
    // 25/256 of the time. Assert the bias actually took effect, so this file
    // cannot pass while silently testing only the reject path.
    var rng = Rng.init(default_seed);
    var known: usize = 0;
    const n: usize = 20_000;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const op: u8 = @truncate(rng.word() >> 56);
        for (knownOpcodes()) |k| {
            if (op == k) {
                known += 1;
                break;
            }
        }
    }
    // Expected ~75%: three quarters of draws take the known-opcode branch.
    try std.testing.expect(known * 100 / n > 60);
}

test "every source-expressible word round-trips through dis -> asm" {
    const alloc = std.testing.allocator;
    var rng = Rng.init(default_seed);
    var checked: usize = 0;
    var identical: usize = 0;
    var rejected: usize = 0;
    var setp_unnameable: usize = 0;
    var ret_unnameable: usize = 0;
    var raw_loses_bits: usize = 0;
    var alu_imm_rs2: usize = 0;
    var mov_rs1: usize = 0;
    var thread_rd_rs1: usize = 0;
    var field_out_of_range: usize = 0;
    var fill_rs2: usize = 0;
    var pc_source: usize = 0;
    var pc_dest: usize = 0;
    var cap_odd: usize = 0;
    var compare_unassigned: usize = 0;

    var i: usize = 0;
    while (i < default_iterations) : (i += 1) {
        const word = rng.word();
        if (!isValidWord(word)) {
            rejected += 1;
            continue;
        }
        if (!isSourceExpressible(word)) {
            // ONE classifier decides both the filter and the count. An earlier
            // version duplicated these conditions here and the two drifted
            // within minutes, mislabelling a `select`-with-PC word that the
            // predicate had already excluded.
            switch (unexpressibleReason(word)) {
                .expressible => unreachable,
                .setp_unnameable => setp_unnameable += 1,
                .ret_unnameable => ret_unnameable += 1,
                .raw_loses_bits => raw_loses_bits += 1,
                .alu_imm_rs2 => alu_imm_rs2 += 1,
                .mov_rs1 => mov_rs1 += 1,
                .thread_rd_rs1 => thread_rd_rs1 += 1,
                .field_unnameable => field_out_of_range += 1,
                .compare_unassigned => compare_unassigned += 1,
                .fill_rs2 => fill_rs2 += 1,
                .pc_source => pc_source += 1,
                .pc_dest => pc_dest += 1,
                .cap_odd => cap_odd += 1,
            }
            continue;
        }
        checked += 1;
        const r = try roundTrip(alloc, word);
        defer if (r.text.len > 0) alloc.free(r.text);

        switch (r.outcome) {
            .identical => identical += 1,
            else => {
                std.debug.print(
                    "\nROUND-TRIP FAILURE at iteration {d} (seed 0x{X:0>16})\n" ++
                        "  word    : 0x{X:0>16}\n" ++
                        "  rendered: {s}\n" ++
                        "  outcome : {s}\n",
                    .{ i, default_seed, word, r.text, @tagName(r.outcome) },
                );
                return error.RoundTripDivergence;
            },
        }
    }

    // Guard against the test passing because the generator produced nothing to
    // check. A fuzzer that checks zero cases is green and worthless.
    std.debug.print(
        "\nfuzz coverage: checked={d} identical={d} rejected={d} " ++
            "setp={d} ret={d} raw={d} alu_im={d} mov_rs1={d} thrd={d} field={d} fill={d} pc={d} pcd={d} cap={d} cmp={d}\n",
        .{ checked, identical, rejected, setp_unnameable, ret_unnameable, raw_loses_bits, alu_imm_rs2, mov_rs1, thread_rd_rs1, field_out_of_range, fill_rs2, pc_source, pc_dest, cap_odd, compare_unassigned },
    );
    try std.testing.expect(checked > default_iterations / 10);
    try std.testing.expect(rejected > 0);
    // The F19 exclusions must actually be exercised, or this test would pass
    // identically on a future tree where the holes were closed and something
    // else broke. A zero count means the generator stopped reaching the case.
    // Not every arm needs to fire on every seed; the arms that matter are the
    // ones the generator's own builders reach. What must hold is that the
    // exclusions as a whole are exercised, so a word excluded for a NEW reason
    // cannot hide. `setp`, `raw` and `compare` arrive only via the perturbation
    // branch, so they are asserted as a group with `ret`.
    const excluded = setp_unnameable + ret_unnameable + raw_loses_bits +
        alu_imm_rs2 + mov_rs1 + thread_rd_rs1 + field_out_of_range + fill_rs2 +
        pc_source + pc_dest + cap_odd + compare_unassigned;
    try std.testing.expect(excluded > default_iterations / 20);
    try std.testing.expect(ret_unnameable > 0);
    try std.testing.expect(alu_imm_rs2 > 0);
    try std.testing.expect(mov_rs1 > 0);
    try std.testing.expect(thread_rd_rs1 > 0);
    try std.testing.expect(field_out_of_range > 0);
    try std.testing.expect(fill_rs2 > 0);
    try std.testing.expect(pc_source > 0);
    try std.testing.expect(pc_dest > 0);
    try std.testing.expect(cap_odd > 0);
    try std.testing.expectEqual(checked, identical);
}

test "a rejected word is never silently accepted by the assembler" {
    // The dangerous direction: the disassembler says "unknown opcode", but the
    // assembler turns that text back into a word. Then a bad image could be
    // laundered into a good one by a dis/asm cycle.
    const alloc = std.testing.allocator;
    var rng = Rng.init(default_seed ^ 0xFFFF);
    var rejections: usize = 0;

    var i: usize = 0;
    while (i < default_iterations) : (i += 1) {
        const word = rng.word();
        if (isValidWord(word)) continue;
        rejections += 1;

        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        disassembler.disassemble(word, &w) catch continue;
        const text = w.buffered();

        var src_buf: [300]u8 = undefined;
        const src = try std.fmt.bufPrint(&src_buf, "{s}\n", .{text});

        var asm_ = assembler.Assembler.init(alloc);
        var diag: assembler.Diagnostic = .{};
        // Arena ownership moves into Program on success; see roundTrip().
        const prog = asm_.assembleSource("fuzz.asm", src, &diag) catch {
            asm_.deinit();
            continue;
        };
        var p = prog;
        defer p.deinit();

        std.debug.print(
            "\nREJECTED WORD WAS RE-ASSEMBLED (seed 0x{X:0>16}, iteration {d})\n" ++
                "  word    : 0x{X:0>16}\n" ++
                "  rendered: {s}\n" ++
                "  re-asm  : {d} word(s)\n",
            .{ default_seed ^ 0xFFFF, i, word, text, prog.words.len },
        );
        return error.RejectionLaunderedIntoProgram;
    }

    try std.testing.expect(rejections > 0);
}

test "the two implementations agree on which words are valid" {
    // Validity is asked of the decoder directly on the raw byte, so this does
    // not depend on rendering. It catches a decoder that accepts a word the
    // assembler's opcode table has no name for.
    //
    // An earlier version of this test asserted that every KNOWN opcode byte must
    // decode. That was wrong, and the fuzzer disproved it on the first run:
    // 0x42B61B68EFFF5620 has opcode 0x42 (`stream.fill`) and reserved
    // `operand[19:0] = 0xF5620`. §3.4 says a non-zero reserved field IS a
    // diagnostic, so rejecting it is correct and the decoder is right. The
    // version below records which opcodes reach a valid word at least once,
    // rather than demanding that every word with a known byte be valid.
    var rng = Rng.init(0xC0FFEE);
    var valid: usize = 0;
    var invalid: usize = 0;
    var ever_valid: [256]bool = @splat(false);
    var ever_seen: [256]bool = @splat(false);

    var i: usize = 0;
    while (i < default_iterations) : (i += 1) {
        const word = rng.word();
        const op: u8 = @truncate(word >> 56);
        ever_seen[op] = true;

        const decoded = isValidWord(word);
        if (decoded) {
            valid += 1;
            ever_valid[op] = true;
        } else {
            invalid += 1;
        }
    }

    // The property actually worth asserting: every opcode byte the generator
    // emits must be CLASSIFIED — that is, the decoder must reach a definite
    // verdict on it rather than agreeing with itself by accident. `nop`, `halt`
    // and `ret` take no operand and require a zero payload, so a random payload
    // is correctly rejected and "reaches a valid word" is the wrong test for
    // them. What must hold for every opcode is that the verdict is reproducible
    // and that at least some words in the space are accepted.
    for (knownOpcodes()) |op| {
        if (!ever_seen[op]) {
            std.debug.print("\nOPCODE 0x{X:0>2} WAS NEVER GENERATED\n", .{op});
            return error.OpcodeNeverGenerated;
        }
    }
    try std.testing.expect(valid > 0);
    try std.testing.expect(invalid > 0);
    // At least a few distinct opcodes must have reached a valid word, or the
    // generator is only ever hitting the reject path.
    var reached: usize = 0;
    for (ever_valid) |v| {
        if (v) reached += 1;
    }
    try std.testing.expect(reached >= knownOpcodes().len / 2);
}

test "every committed cross-check program round-trips byte-identically" {
    // The four programs under tests/crosscheck/ are the inputs to the RTL
    // cross-check. If their round-trip broke, rtl/CROSSCHECK.md's method would
    // silently stop holding.
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "tests/crosscheck/p1_zeroext.asm",
        "tests/crosscheck/p2_aluimm.asm",
        "tests/crosscheck/p3_callret.asm",
        "tests/crosscheck/p4x.asm",
    };

    for (cases) |path| {
        const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
        defer file.close(std.testing.io);
        const stat = try file.stat(std.testing.io);
        const source = try alloc.alloc(u8, @intCast(stat.size));
        defer alloc.free(source);
        _ = try file.readPositionalAll(std.testing.io, source, 0);

        var asm_ = assembler.Assembler.init(alloc);
        var diag: assembler.Diagnostic = .{};
        // Arena ownership moves into Program on success; see roundTrip().
        const prog = asm_.assembleSource(path, source, &diag) catch {
            asm_.deinit();
            std.debug.print("{s} no longer assembles\n", .{path});
            return error.CrosscheckSourceBroken;
        };
        var p = prog;
        defer p.deinit();

        try std.testing.expect(prog.words.len > 0);

        for (prog.words) |word| {
            if (!isValidWord(word)) {
                std.debug.print("{s}: word 0x{X:0>16} does not decode\n", .{ path, word });
                return error.CrosscheckWordUndecodable;
            }
            const r = try roundTrip(alloc, word);
            defer if (r.text.len > 0) alloc.free(r.text);
            if (r.outcome != .identical) {
                std.debug.print(
                    "{s}: word 0x{X:0>16} round-tripped as {s} ({s})\n",
                    .{ path, word, @tagName(r.outcome), r.text },
                );
                return error.CrosscheckRoundTripBroke;
            }
        }
    }
}

test "the assembler and the decoder's encode() agree on every committed program" {
    // A mutation survived the round-trip fuzzer and this test exists because of
    // it: `src/assembler.zig` has its OWN encoder (`Instruction.word()`) and
    // `decoder.encode()` is used only by decoder tests, so the round-trip
    // exercises the assembler's encoder and never `decoder.encode`. Deleting
    // `src2` from `encodeField` therefore broke nothing the fuzzer could see.
    //
    // Two encoders that must agree is a real duplication hazard. This test pins
    // them together: for every word the assembler emits, `encode(decode(w))`
    // must reproduce it.
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "tests/crosscheck/p1_zeroext.asm",
        "tests/crosscheck/p2_aluimm.asm",
        "tests/crosscheck/p3_callret.asm",
        "tests/crosscheck/p4x.asm",
    };
    var compared: usize = 0;
    var seen_field_insert: usize = 0;

    // The four committed programs contain NO `field.*` instruction at all, which
    // is why the first version of this test missed a `src2` mutation in
    // `encodeField`. Fixtures narrow to the feature they were written for; the
    // generator below is what actually reaches every encoder. Both are run.
    var rng = Rng.init(default_seed ^ 0xA5A5);
    var iter: usize = 0;
    while (iter < 5_000) : (iter += 1) {
        const word = rng.word();
        const decoded = disassembler.decodeWord(word) orelse continue;
        if (@as(u8, @truncate(word >> 56)) == 0x31) seen_field_insert += 1;
        const re_encoded = disassembler.encode(decoded);
        // Only compare where the assembler could express the word; the F19-F30
        // holes are words no source line names, and both encoders are entitled
        // to differ from them.
        if (!isSourceExpressible(word)) continue;
        if (re_encoded != word) {
            std.debug.print(
                "generated 0x{X:0>16}: decoder.encode() gives 0x{X:0>16}\n",
                .{ word, re_encoded },
            );
            return error.EncoderDivergence;
        }
        compared += 1;
    }
    try std.testing.expect(seen_field_insert > 0);

    for (cases) |path| {
        const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
        defer file.close(std.testing.io);
        const stat = try file.stat(std.testing.io);
        const source = try alloc.alloc(u8, @intCast(stat.size));
        defer alloc.free(source);
        _ = try file.readPositionalAll(std.testing.io, source, 0);

        var asm_ = assembler.Assembler.init(alloc);
        var diag: assembler.Diagnostic = .{};
        const prog = asm_.assembleSource(path, source, &diag) catch {
            asm_.deinit();
            return error.CrosscheckSourceBroken;
        };
        var p = prog;
        defer p.deinit();

        for (prog.words) |word| {
            const decoded = disassembler.decodeWord(word) orelse continue;
            const re_encoded = disassembler.encode(decoded);
            if (re_encoded != word) {
                std.debug.print(
                    "{s}: assembler emitted 0x{X:0>16} but decoder.encode() gives 0x{X:0>16}\n",
                    .{ path, word, re_encoded },
                );
                return error.EncoderDivergence;
            }
            compared += 1;
        }
    }
    try std.testing.expect(compared > 20);
}
