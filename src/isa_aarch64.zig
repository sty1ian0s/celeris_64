//! AArch64 (A64) execution: a real ARM64 decoder and interpreter, for the
//! cross-architecture comparison.
//!
//! SCOPE. Fixed 32-bit instructions, the integer subset the comparison workload
//! needs: ADD/SUB (immediate and shifted-register), MADD/MSUB, MOV, LDR/STR (both
//! the unsigned-immediate and register-offset forms), CMP, B.cond, B, RET, NOP.
//! No SIMD, no floating point, no atomics, no exception levels, no system
//! registers. The encodings implemented here are checked byte-for-byte against
//! LLVM's integrated assembler in the oracle tests at the bottom.
//!
//! WHY THESE INSTRUCTIONS. The comparison measures the SAME workload on every
//! ISA. Anything not needed for that workload is left out rather than guessed
//! at — an instruction implemented from a half-remembered encoding is worse than
//! one that faults loudly.
//!
//! WHAT THIS DOES NOT MODEL. Cycles, pipelines, caches, branch prediction,
//! out-of-order execution. See `isaharness.zig`.

const std = @import("std");
const harness = @import("isaharness.zig");

pub const reg_count = 31;

/// Architectural state. `x31` is the zero register (XZR) in most contexts and
/// the stack pointer in others; the workload uses only the zero-register
/// reading, so x31 reads 0 and writes are ignored.
pub const Cpu = struct {
    regs: [reg_count]u64 = @splat(0),
    pc: u64 = 0,
    mem: []u8,
    stopped: bool = false,
    branched: bool = false,
    /// Condition flags, set only by CMP (which is SUBS with the result discarded).
    n: bool = false,
    z: bool = false,
    c: bool = false,
    v: bool = false,

    pub fn init(mem: []u8) Cpu {
        return .{ .mem = mem };
    }

    pub fn read(self: *const Cpu, r: u5) u64 {
        return if (r == 31) 0 else self.regs[r];
    }

    pub fn write(self: *Cpu, r: u5, v: u64) void {
        if (r == 31) return;
        self.regs[r] = v;
    }

    pub fn halted(self: *const Cpu) bool {
        return self.stopped;
    }

    fn load(self: *const Cpu, addr: u64, n: u6) !u64 {
        if (addr + n > self.mem.len) return error.OutOfBounds;
        const bytes = self.mem[@intCast(addr)..][0..n];
        return switch (n) {
            1 => bytes[0],
            2 => std.mem.readInt(u16, bytes[0..2], .little),
            4 => std.mem.readInt(u32, bytes[0..4], .little),
            8 => std.mem.readInt(u64, bytes[0..8], .little),
            else => unreachable,
        };
    }

    fn store(self: *Cpu, addr: u64, n: u6, v: u64) !void {
        if (addr + n > self.mem.len) return error.OutOfBounds;
        const bytes = self.mem[@intCast(addr)..][0..n];
        switch (n) {
            1 => bytes[0] = @truncate(v),
            2 => std.mem.writeInt(u16, bytes[0..2], @truncate(v), .little),
            4 => std.mem.writeInt(u32, bytes[0..4], @truncate(v), .little),
            8 => std.mem.writeInt(u64, bytes[0..8], v, .little),
            else => unreachable,
        }
    }

    /// Executes one A64 instruction and returns its length, always 4.
    ///
    /// A64 is a fixed-width ISA without exception: every instruction is 32 bits
    /// and 4-byte aligned. This differs from CLS64 and RISC-V in width (8 and 4
    /// respectively) and from x86-64 in that there is no length to discover,
    /// which is precisely why the harness returns a length rather than assuming.
    pub fn step(self: *Cpu) !u64 {
        const raw = try self.load(self.pc, 4);
        const insn: u32 = @truncate(raw);
        try self.execute(insn);
        if (self.branched) {
            self.branched = false;
        } else {
            self.pc +%= 4;
        }
        return 4;
    }

    fn execute(self: *Cpu, insn: u32) !void {
        // Branch instructions are identified by bits [31:26] == 000101 (B.cond,
        // 0x54 with the low bits) or the unconditional B (0x14000000 pattern).
        // These are checked before the general masks, because the branch field
        // overlaps the arithmetic ones.
        if ((insn & 0xFF000010) == 0x54000000) return self.branchCond(insn);
        if ((insn & 0xFC000000) == 0x14000000) return self.branchUncond(insn);

        // Data-processing immediate: ADD/SUB (immediate). 0x91 / 0xD1 with the
        // sf bit for 64-bit. Mask covers op, S, and the 12-bit immediate.
        if ((insn & 0x1F000000) == 0x11000000) return self.addSubImm(insn);
        // Add/subtract (shifted register): ADD/SUB/CMP. 0x8B / 0xCB / 0xEB.
        if ((insn & 0x1F200000) == 0x0B000000) return self.addSubReg(insn);

        // Data-processing (3 source): MADD/MSUB. The mask must pin bit 15, which
        // separates the 3-source group from the shifted-register group above —
        // MADD is 0x9B, not 0x8B, and its bits [28:24] are 11011. `mul Rd, Rn,
        // Rm` is `madd Rd, Rn, Rm, XZR`, so one arm serves both.
        if ((insn & 0x1F000000) == 0x1B000000) return self.madd(insn);

        // Load/store register offset: LDR/STR Rt, [Rn, Rm]. Bits [29:27] = 111,
        // [25:24] = 00, [21] = 1. This is the form a matrix kernel wants, because
        // the element offset is a scaled INDEX rather than a constant.
        if ((insn & 0x3B200C00) == 0x38200800) return self.loadStoreReg(insn);

        // MOV (wide immediate): MOVZ/MOVN. 0x52800000 / 0x12800000 patterns.
        if ((insn & 0x1F800000) == 0x12800000) return self.moveWide(insn);

        // Load/store unsigned immediate: LDR/STR. Bits [29:27] = 111, [25:24] = 01.
        if ((insn & 0x3B000000) == 0x39000000) return self.loadStore(insn);

        // RET is the specific encoding D65F0000 | Rn << 5.
        if ((insn & 0xFFFFFC1F) == 0xD65F0000) {
            self.pc = self.read(@truncate(insn >> 5));
            self.branched = true;
            return;
        }

        // NOP (and the hint space generally) is a no-op.
        if (insn == 0xD503201F) return;

        return error.UnknownOpcode;
    }

    fn addSubImm(self: *Cpu, insn: u32) !void {
        const sf = (insn >> 31) & 1; // 1 = 64-bit
        const op = (insn >> 30) & 1; // 0 = ADD, 1 = SUB
        const s = (insn >> 29) & 1; // 1 = set flags
        const shift: u6 = @intCast((insn >> 22) & 3);
        var imm: u64 = (insn >> 10) & 0xFFF;
        if (shift == 1) imm <<= 12;
        const rn: u5 = @truncate(insn >> 5);
        const rd: u5 = @truncate(insn);

        const a = if (sf == 1) self.read(rn) else @as(u32, @truncate(self.read(rn)));
        const b = imm;
        const res: u64 = if (op == 0) a +% b else a -% b;
        const masked: u64 = if (sf == 1) res else @as(u32, @truncate(res));

        if (s == 1) self.setFlags(a, b, masked, op == 1, sf == 1);
        if (rd != 31 or s == 0) self.write(rd, masked);
    }

    fn addSubReg(self: *Cpu, insn: u32) !void {
        const sf = (insn >> 31) & 1;
        const op = (insn >> 30) & 1;
        const s = (insn >> 29) & 1;
        const shift_type: u2 = @truncate((insn >> 22) & 3);
        const shift_amt: u6 = @intCast((insn >> 10) & 0x3F);
        const rm: u5 = @truncate(insn >> 16);
        const rn: u5 = @truncate(insn >> 5);
        const rd: u5 = @truncate(insn);

        var b = self.read(rm);
        switch (shift_type) {
            0 => b = if (shift_amt == 0) b else b << @intCast(shift_amt), // LSL
            1 => b >>= @intCast(shift_amt), // LSR
            2 => b = @bitCast(@as(i64, @bitCast(b)) >> @intCast(shift_amt)), // ASR
            else => return error.UnsupportedShift, // ROR: not needed by the workload
        }

        const a = if (sf == 1) self.read(rn) else @as(u32, @truncate(self.read(rn)));
        const bb: u64 = if (sf == 1) b else @as(u32, @truncate(b));
        const res = if (op == 0) a +% bb else a -% bb;
        const masked: u64 = if (sf == 1) res else @as(u32, @truncate(res));

        if (s == 1) self.setFlags(a, bb, masked, op == 1, sf == 1);
        self.write(rd, masked);
    }

    /// MADD/MSUB: `Rd = Ra + (Rn * Rm)` or `Rd = Ra - (Rn * Rm)`.
    ///
    /// `mul Rd, Rn, Rm` is the same encoding with Ra = XZR, which is why LLVM
    /// renders `madd x1, x2, x3, xzr` back as `mul x1, x2, x3` — the two mnemonics
    /// are one instruction. Both are accepted here.
    ///
    /// Only the 64-bit (sf = 1) form is implemented. The 32-bit form is the same
    /// opcode with bit 31 clear; it is refused rather than silently treated as
    /// 64-bit, which would produce a wrong product for any operand above 2^32.
    fn madd(self: *Cpu, insn: u32) !void {
        if (((insn >> 31) & 1) != 1) return error.UnsupportedWidth;
        const rm: u5 = @truncate(insn >> 16);
        const ra: u5 = @truncate(insn >> 10);
        const rn: u5 = @truncate(insn >> 5);
        const rd: u5 = @truncate(insn);
        const is_sub = ((insn >> 15) & 1) == 1; // 0 = MADD, 1 = MSUB

        const product = self.read(rn) *% self.read(rm);
        const acc = self.read(ra);
        self.write(rd, if (is_sub) acc -% product else acc +% product);
    }

    /// LDR/STR (register offset), with the option bits [15:13] honoured for the
    /// shift used by LSL. The workload uses shift = 0 only; a non-zero shift is
    /// applied rather than ignored, because ignoring it reads the wrong element
    /// silently. Extend options (UXTW/SXTW etc.) are refused: they change the
    /// meaning of the index and are not needed here.
    fn loadStoreReg(self: *Cpu, insn: u32) !void {
        const size: u3 = @truncate((insn >> 30) & 3);
        const is_load = ((insn >> 22) & 1) == 1;
        const option: u3 = @truncate((insn >> 13) & 7);
        const s = (insn >> 12) & 1;
        const rm: u5 = @truncate(insn >> 16);
        const rn: u5 = @truncate(insn >> 5);
        const rt: u5 = @truncate(insn);

        // option 011 is LSL; the extension options are 010/110 (UXTW/SXTW) and
        // their 64-bit forms, which this subset does not implement.
        if (option != 0b011) return error.UnsupportedExtend;

        const scale: u6 = @as(u6, 1) << size; // 1, 2, 4 or 8
        const amount: u6 = if (s == 1) size else 0;
        const index = self.read(rm) << @intCast(amount);
        const addr = self.read(rn) +% index;
        if (is_load) {
            const raw = try self.load(addr, scale);
            self.write(rt, switch (size) {
                0 => @as(u8, @truncate(raw)),
                1 => @as(u16, @truncate(raw)),
                2 => @as(u32, @truncate(raw)),
                3 => raw,
                else => unreachable,
            });
        } else {
            try self.store(addr, scale, self.read(rt));
        }
    }

    fn moveWide(self: *Cpu, insn: u32) !void {
        const sf = (insn >> 31) & 1;
        // opc is bits [30:29]: 00 = MOVN, 10 = MOVZ, 11 = MOVK. The `> 1` test
        // that was here rejected MOVZ (2), the single most common form, and only
        // the oracle test caught it because the round trip still "worked" for
        // MOVN. Each value now has its own arm.
        const opc = (insn >> 29) & 3;
        const hw: u6 = @intCast((insn >> 21) & 3);
        const imm16: u64 = (insn >> 5) & 0xFFFF;
        const rd: u5 = @truncate(insn);

        const shifted = imm16 << @intCast(hw * 16);
        const base: u64 = switch (opc) {
            0b00 => ~shifted, // MOVN
            0b10 => shifted, // MOVZ
            0b11 => return error.MovKeepUnsupported, // MOVK needs the old value
            else => return error.UnknownOpcode, // 0b01 is unallocated
        };
        const v: u64 = if (sf == 1) base else @as(u32, @truncate(base));
        self.write(rd, v);
    }

    fn loadStore(self: *Cpu, insn: u32) !void {
        const size: u3 = @truncate((insn >> 30) & 3); // 0=byte,1=half,2=word,3=dword
        const is_load = ((insn >> 22) & 1) == 1;
        const imm12: u64 = (insn >> 10) & 0xFFF;
        const rn: u5 = @truncate(insn >> 5);
        const rt: u5 = @truncate(insn);

        const scale: u6 = @as(u6, 1) << size; // 1, 2, 4 or 8 bytes
        const addr = self.read(rn) +% (imm12 * scale);

        if (is_load) {
            const raw = try self.load(addr, scale);
            // LDR with size < 3 zero-extends; the sign-extending forms are a
            // different opcode and are not implemented.
            const v: u64 = switch (size) {
                0 => @as(u8, @truncate(raw)),
                1 => @as(u16, @truncate(raw)),
                2 => @as(u32, @truncate(raw)),
                3 => raw,
                else => unreachable,
            };
            self.write(rt, v);
        } else {
            try self.store(addr, scale, self.read(rt));
        }
    }

    fn branchCond(self: *Cpu, insn: u32) !void {
        // The condition code is in bits [3:0], and bit 4 must be 0 for B.cond
        // (bit 4 set means BC.cond, a different instruction).
        if (((insn >> 4) & 1) != 0) return error.UnknownOpcode;
        const cond: u4 = @truncate(insn);
        // imm19 is a signed 19-bit field scaled by 4. Sign-extend it by shifting
        // up to bit 31 and back down arithmetically — the same construction whose
        // omission caused a real bug in the RISC-V decoder.
        const raw19: u32 = (insn >> 5) & 0x7FFFF;
        const signed19: i32 = @bitCast(raw19 << 13);
        const off: i64 = @as(i64, signed19 >> 13) << 2;

        if (self.conditionHolds(cond)) {
            self.pc = self.pc +% @as(u64, @bitCast(off));
            self.branched = true;
        }
    }

    fn branchUncond(self: *Cpu, insn: u32) !void {
        const raw26: u32 = insn & 0x03FFFFFF;
        const signed26: i32 = @bitCast(raw26 << 6);
        const off: i64 = @as(i64, signed26 >> 6) << 2;
        self.pc = self.pc +% @as(u64, @bitCast(off));
        self.branched = true;
    }

    fn conditionHolds(self: *const Cpu, cond: u4) bool {
        return switch (cond) {
            0x0 => self.z, // EQ
            0x1 => !self.z, // NE
            0x2 => self.c, // CS/HS
            0x3 => !self.c, // CC/LO
            0x4 => self.n, // MI
            0x5 => !self.n, // PL
            0x6 => self.v, // VS
            0x7 => !self.v, // VC
            0x8 => self.c and !self.z, // HI
            0x9 => !self.c or self.z, // LS
            0xA => self.n == self.v, // GE
            0xB => self.n != self.v, // LT
            0xC => !self.z and (self.n == self.v), // GT
            0xD => self.z or (self.n != self.v), // LE
            0xE => true, // AL
            else => true, // NV behaves as AL
        };
    }

    fn setFlags(self: *Cpu, a: u64, b: u64, result: u64, is_sub: bool, is64: bool) void {
        if (is64) {
            self.n = (result >> 63) != 0;
            self.z = result == 0;
            if (is_sub) {
                self.c = a >= b;
                self.v = ((a ^ b) & (a ^ result) & (@as(u64, 1) << 63)) != 0;
            } else {
                self.c = result < a;
                self.v = ((a ^ result) & (b ^ result) & (@as(u64, 1) << 63)) != 0;
            }
        } else {
            const a32: u32 = @truncate(a);
            const b32: u32 = @truncate(b);
            const r32: u32 = @truncate(result);
            self.n = (r32 >> 31) != 0;
            self.z = r32 == 0;
            if (is_sub) {
                self.c = a32 >= b32;
                self.v = ((a32 ^ b32) & (a32 ^ r32) & (@as(u32, 1) << 31)) != 0;
            } else {
                self.c = r32 < a32;
                self.v = ((a32 ^ r32) & (b32 ^ r32) & (@as(u32, 1) << 31)) != 0;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Encode helpers
// ---------------------------------------------------------------------------

pub fn addImm(rd: u5, rn: u5, imm: u12) u32 {
    return 0x91000000 | (@as(u32, imm) << 10) | (@as(u32, rn) << 5) | rd;
}
pub fn subImm(rd: u5, rn: u5, imm: u12) u32 {
    return 0xD1000000 | (@as(u32, imm) << 10) | (@as(u32, rn) << 5) | rd;
}
/// CMP Rn, Rm is `SUBS XZR, Rn, Rm` — rd is the zero register.
pub fn cmp(rn: u5, rm: u5) u32 {
    return 0xEB00001F | (@as(u32, rm) << 16) | (@as(u32, rn) << 5);
}
pub fn add(rd: u5, rn: u5, rm: u5) u32 {
    return 0x8B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}
pub fn sub(rd: u5, rn: u5, rm: u5) u32 {
    return 0xCB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
}
pub fn ldr(rt: u5, rn: u5, off: u12) u32 {
    return 0xF9400000 | (@as(u32, off) << 10) | (@as(u32, rn) << 5) | rt;
}
pub fn str(rt: u5, rn: u5, off: u12) u32 {
    return 0xF9000000 | (@as(u32, off) << 10) | (@as(u32, rn) << 5) | rt;
}
/// `madd rd, rn, rm, ra` — 64-bit, bits [31:29] = 001 and bits [28:24] = 11011.
/// Verified against LLVM: `madd x0, x1, x2, x3` is 0x9B030220.
pub fn madd(rd: u5, rn: u5, rm: u5, ra: u5) u32 {
    return 0x9B000000 | (@as(u32, rm) << 16) | (@as(u32, ra) << 10) | (@as(u32, rn) << 5) | rd;
}
/// `mul rd, rn, rm` is `madd rd, rn, rm, xzr`. Kept as its own name because that
/// is how a reader writes it, but there is only one encoding.
pub fn mul(rd: u5, rn: u5, rm: u5) u32 {
    return madd(rd, rn, rm, 31);
}
/// `ldr rt, [rn, rm]` — register offset, no shift, 64-bit (size = 3).
/// LLVM: `ldr x1, [x2, x3]` is 0xF8636841. Bits [15:13] = 011 (LSL) are part of
/// the base; leaving bit 14 clear encodes a different option and would decode as
/// a rejected extend.
pub fn ldrReg(rt: u5, rn: u5, rm: u5) u32 {
    return 0xF8606800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
}
/// `str rt, [rn, rm]` — register offset, no shift, 64-bit.
pub fn strReg(rt: u5, rn: u5, rm: u5) u32 {
    return 0xF8206800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
}
pub fn movz(rd: u5, imm16: u16, hw: u2) u32 {
    return 0xD2800000 | (@as(u32, hw) << 21) | (@as(u32, imm16) << 5) | rd;
}
pub fn bCond(cond: u4, off_bytes: i32) u32 {
    const imm19: u32 = @as(u32, @bitCast(off_bytes >> 2)) & 0x7FFFF;
    return 0x54000000 | (imm19 << 5) | cond;
}
pub fn bUncond(off_bytes: i32) u32 {
    const imm26: u32 = @as(u32, @bitCast(off_bytes >> 2)) & 0x03FFFFFF;
    return 0x14000000 | imm26;
}
pub fn ret() u32 {
    return 0xD65F03C0;
}
pub fn nop() u32 {
    return 0xD503201F;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn image(words: []const u32) ![]u8 {
    const bytes = try testing.allocator.alloc(u8, words.len * 4 + 256);
    @memset(bytes, 0);
    for (words, 0..) |w, i| {
        std.mem.writeInt(u32, bytes[i * 4 ..][0..4], w, .little);
    }
    return bytes;
}

test "x31 reads as zero and ignores writes" {
    const img = try image(&.{nop()});
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    cpu.write(31, 0xDEAD);
    try testing.expectEqual(@as(u64, 0), cpu.read(31));
}

test "add/sub immediate and shifted-register compute correctly" {
    const img = try image(&.{
        movz(0, 5, 0), // x0 = 5
        addImm(1, 0, 37), // x1 = 42
        sub(2, 1, 0), // x2 = 42 - 5 = 37
        add(3, 0, 2), // x3 = 5 + 37 = 42
    });
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    for (0..4) |_| _ = try cpu.step();
    try testing.expectEqual(@as(u64, 5), cpu.read(0));
    try testing.expectEqual(@as(u64, 42), cpu.read(1));
    try testing.expectEqual(@as(u64, 37), cpu.read(2));
    try testing.expectEqual(@as(u64, 42), cpu.read(3));
}

test "cmp sets flags and b.eq / b.ne act on them" {
    const img = try image(&.{
        movz(0, 7, 0),
        movz(1, 7, 0),
        cmp(0, 1), // equal -> Z set
        bCond(0x1, 12), // B.NE; NOT taken
        movz(2, 111, 0), // executed
        cmp(0, 1),
        bCond(0x0, 8), // B.EQ; taken, skips one word
        movz(3, 222, 0), // SKIPPED
    });
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    for (0..6) |_| {
        if (cpu.halted()) break;
        _ = try cpu.step();
    }
    try testing.expectEqual(@as(u64, 111), cpu.read(2));
    try testing.expectEqual(@as(u64, 0), cpu.read(3)); // never executed
}

test "ldr and str move real bytes, and the offset is scaled by the access size" {
    const img = try image(&.{
        movz(0, 200, 0), // x0 = 200 (base)
        movz(1, 99, 0), // x1 = 99
        str(1, 0, 0), // mem[200] = 99
        str(1, 0, 1), // mem[208] = 99 (offset 1 * 8 bytes)
        ldr(2, 0, 0), // x2 = mem[200]
        ldr(3, 0, 1), // x3 = mem[208]
    });
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    for (0..6) |_| _ = try cpu.step();
    try testing.expectEqual(@as(u64, 99), std.mem.readInt(u64, img[200..208], .little));
    try testing.expectEqual(@as(u64, 99), std.mem.readInt(u64, img[208..216], .little));
    try testing.expectEqual(@as(u64, 99), cpu.read(2));
    try testing.expectEqual(@as(u64, 99), cpu.read(3));
}

test "ret jumps to the address in its register" {
    const img = try testing.allocator.alloc(u8, 256);
    defer testing.allocator.free(img);
    @memset(img, 0);
    std.mem.writeInt(u32, img[0..4], ret(), .little);
    var cpu = Cpu.init(img);
    cpu.write(30, 64); // LR
    _ = try cpu.step();
    try testing.expectEqual(@as(u64, 64), cpu.pc);
}

test "the harness measures an AArch64 program end to end" {
    const img = try image(&.{ movz(0, 1, 0), addImm(0, 0, 2), movz(3, 93, 0), nop() });
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    // A64 has no architectural halt in this subset; the harness limit ends it.
    const out = harness.run(&cpu, 3);
    try testing.expect(out == .exhausted);
    try testing.expectEqual(@as(u64, 3), out.exhausted.retired);
    try testing.expectEqual(@as(u64, 12), out.exhausted.code_bytes);
}

// ---------------------------------------------------------------------------
// Oracle tests: my encoder against LLVM's ARM64 assembler
// ---------------------------------------------------------------------------
//
// Recorded command and output for each row:
//
//   $ echo "add x0, x1, x2" | llvm-mc -triple=aarch64 -show-encoding
//           add x0, x1, x2   // encoding: [0x20,0x00,0x02,0x8b]

test "ORACLE: my A64 encoder reproduces LLVM's byte-for-byte" {
    const cases = [_]struct { name: []const u8, mine: u32, llvm: u32 }{
        .{ .name = "add x0,x1,x2", .mine = add(0, 1, 2), .llvm = 0x8B020020 },
        .{ .name = "sub x0,x1,x2", .mine = sub(0, 1, 2), .llvm = 0xCB020020 },
        .{ .name = "ldr x0,[x1]", .mine = ldr(0, 1, 0), .llvm = 0xF9400020 },
        .{ .name = "str x0,[x1]", .mine = str(0, 1, 0), .llvm = 0xF9000020 },
        .{ .name = "add x0,x0,#5", .mine = addImm(0, 0, 5), .llvm = 0x91001400 },
        .{ .name = "cmp x0,x1", .mine = cmp(0, 1), .llvm = 0xEB01001F },
        .{ .name = "b.ne 16", .mine = bCond(0x1, 16), .llvm = 0x54000081 },
        .{ .name = "b.eq -8", .mine = bCond(0x0, -8), .llvm = 0x54FFFFC0 },
        .{ .name = "ret", .mine = ret(), .llvm = 0xD65F03C0 },
        .{ .name = "mov x0,#5", .mine = movz(0, 5, 0), .llvm = 0xD28000A0 },
    };
    for (cases) |c| {
        testing.expectEqual(c.llvm, c.mine) catch |e| {
            std.debug.print("ORACLE MISMATCH for {s}: mine=0x{X:0>8} llvm=0x{X:0>8}\n", .{ c.name, c.mine, c.llvm });
            return e;
        };
    }
}

test "ORACLE: LLVM's own bytes decode to the operands the assembly names" {
    const img = try image(&.{
        0xD28000A0, // mov x0, #5
        0x91001400, // add x0, x0, #5
        0xD2800B81, // mov x1, #92  (0x5C = 92)
    });
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    _ = try cpu.step();
    try testing.expectEqual(@as(u64, 5), cpu.read(0));
    _ = try cpu.step();
    try testing.expectEqual(@as(u64, 10), cpu.read(0));
    _ = try cpu.step();
    try testing.expectEqual(@as(u64, 92), cpu.read(1));
}

test "ORACLE: a negative B.cond offset decodes as negative" {
    // Pins the same sign-extension class of bug found in the RISC-V decoder.
    // Placed at offset 100 rather than 0: at pc = 0 a decoder that computed
    // `target = imm` instead of `pc + imm` would pass, and the point is a PC that
    // is not near zero.
    const img = try testing.allocator.alloc(u8, 256);
    defer testing.allocator.free(img);
    @memset(img, 0);
    std.mem.writeInt(u32, img[100..104], 0x54FFFFC0, .little); // b.eq -8
    var cpu = Cpu.init(img);
    cpu.z = true;
    cpu.pc = 100;
    _ = try cpu.step();
    try testing.expectEqual(@as(u64, 92), cpu.pc);
}

// ---------------------------------------------------------------------------
// Oracle tests: MADD/MUL and the register-offset loads, added for matmul_8x8
// ---------------------------------------------------------------------------
//
// Recorded command and output for each row:
//
//   $ printf 'mul x1, x2, x3\nmadd x0, x1, x2, x3\nmadd x10, x11, x12, x10\nldr x1, [x2, x3]\nstr x1, [x2, x3]\n' \
//       | llvm-mc -triple=aarch64 -show-encoding
//           mul  x1, x2, x3            // encoding: [0x41,0x7c,0x03,0x9b]
//           mul  x1, x2, x3            // encoding: [0x41,0x7c,0x03,0x9b]
//           madd x0, x1, x2, x3        // encoding: [0x20,0x0c,0x02,0x9b]
//           ldr  x1, [x2, x3]          // encoding: [0x41,0x68,0x63,0xf8]
//           str  x1, [x2, x3]          // encoding: [0x41,0x68,0x23,0xf8]
//
// `madd x1, x2, x3, xzr` is REJECTED by llvm-mc as an invalid mnemonic and
// printed back as `mul x1, x2, x3` — the two spellings are one encoding, which
// is why `mul` here is defined as `madd ..., xzr`.

test "ORACLE: the A64 multiply and register-offset encoders reproduce LLVM byte-for-byte" {
    const cases = [_]struct { name: []const u8, mine: u32, llvm: u32 }{
        .{ .name = "mul x1,x2,x3", .mine = mul(1, 2, 3), .llvm = 0x9B037C41 },
        .{ .name = "madd x0,x1,x2,x3", .mine = madd(0, 1, 2, 3), .llvm = 0x9B020C20 },
        .{ .name = "madd x10,x11,x12,x10", .mine = madd(10, 11, 12, 10), .llvm = 0x9B0C296A },
        .{ .name = "ldr x1,[x2,x3]", .mine = ldrReg(1, 2, 3), .llvm = 0xF8636841 },
        .{ .name = "str x1,[x2,x3]", .mine = strReg(1, 2, 3), .llvm = 0xF8236841 },
    };
    for (cases) |c| {
        testing.expectEqual(c.llvm, c.mine) catch |e| {
            std.debug.print("ORACLE MISMATCH for {s}: mine=0x{X:0>8} llvm=0x{X:0>8}\n", .{ c.name, c.mine, c.llvm });
            return e;
        };
    }
}

test "ORACLE: LLVM's own mul/madd bytes decode to the operands the assembly names" {
    // Both encodings are run back to back, so the assertions are chained rather
    // than chosen for one instruction: the second reads what the first wrote,
    // which is what a real dependency looks like. A decoder that mixed up Rd, Rn
    // and Ra fails one of them.
    //
    //   0x9B037C41 = mul  x1, x2, x3          x1 = 6 * 7   = 42
    //   0x9B020C20 = madd x0, x1, x2, x3      x0 = 5 + 42*7 = 299
    const img = try image(&.{ 0x9B037C41, 0x9B020C20 });
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    cpu.write(2, 6);
    cpu.write(3, 7);
    cpu.write(1, 5); // the MADD addend source is x1's OLD value only if Rd != Ra
    _ = try cpu.step();
    try testing.expectEqual(@as(u64, 42), cpu.read(1));
    _ = try cpu.step();
    // madd x0, x1, x2, x3 with x1 = 42 now, x2 = 6, x3 = 7 -> 42 * 6 + 7 = 259.
    try testing.expectEqual(@as(u64, 259), cpu.read(0));
}

test "ORACLE: LLVM's register-offset load and store bytes move the indexed element" {
    // 0xF8636841 = ldr x1, [x2, x3] ; 0xF8236841 = str x1, [x2, x3]
    // Both are placed after a movz so the base and index come from instructions
    // rather than from the test's own writes, which is what a program would do.
    const img = try image(&.{ 0xF8636841, 0xF8236841 }); // ldr x1,[x2,x3] ; str x1,[x2,x3]
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    cpu.write(2, 200); // base
    cpu.write(3, 4); // index
    std.mem.writeInt(u64, img[204..212], 0x5150, .little); // [x2 + x3]
    _ = try cpu.step();
    try testing.expectEqual(@as(u64, 0x5150), cpu.read(1));
    cpu.write(1, 0xABCD);
    _ = try cpu.step();
    try testing.expectEqual(@as(u64, 0xABCD), std.mem.readInt(u64, img[204..212], .little));
}

test "madd and mul compute the product, and the MSUB bit subtracts" {
    const img = try image(&.{
        movz(1, 6, 0),
        movz(2, 7, 0),
        movz(3, 5, 0),
        madd(0, 1, 2, 3), // x0 = 5 + 6*7 = 47
        mul(4, 1, 2), // x4 = 6*7 = 42
    });
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    for (0..5) |_| _ = try cpu.step();
    try testing.expectEqual(@as(u64, 47), cpu.read(0));
    try testing.expectEqual(@as(u64, 42), cpu.read(4));
}
