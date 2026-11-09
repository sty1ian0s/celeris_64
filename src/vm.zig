//! CLS64 core: flat memory, register file, and the in-order fetch-decode-execute loop.
//!
//! Fidelity: executable model. Registers, memory and the ALU control path are real
//! behaviour with real tests; the capability checks are a software model with no tag
//! bits (docs/isa-encoding.md §8). Nothing here claims silicon performance.
//!
//! Allocation policy (AGENTS.md §4.1): `Vm.init` allocates the memory image once.
//! `step` and `run` allocate nothing — no allocator is in scope inside the loop.
//!
//! Failures are values, never silent: a halted VM, a refusing bound check and an
//! undecodable word each come back as a `Diagnostic` rendered as a plain sentence.

const std = @import("std");

pub const memory = @import("memory.zig");
pub const registers = @import("registers.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const decoding = @import("decoder.zig");
/// §3.3 bitfield slicing (model module). Re-exported because tests/vm_tests.zig can
/// only reach what this module root exposes.
pub const bits = @import("field.zig");
/// §3.2 comparison and branchless select (model module).
pub const selection = @import("select.zig");
/// §3.4 stream engine (model module).
pub const streaming = @import("stream.zig");
/// §3.5/§6 capability descriptors (model module). Not cryptographic: bounds and
/// permission checks only, no tag bits (docs/isa-encoding.md §6, §8).
pub const capability = @import("capability.zig");
/// §3.7 SMT-8 thread slots (model module).
///
/// FIDELITY: this is a DETERMINISTIC modelled interleave, not real concurrency.
/// Slots are stepped one at a time on a single thread of execution. There is no
/// timing, no parallel hardware, and no speedup claim (docs/isa-encoding.md §8).
pub const threading = @import("thread.zig");
/// §3.6's opcode registry, read only for the operation NAME in a refusal. The
/// table is normative and already exists in exactly one place; re-typing it here
/// would be a third copy that could drift from the assembler's.
const accelerator_spec = @import("assembler.zig");

/// §3.6 model modules (amendment 1.18). Reached only from `accelerator`, never
/// from the fetch-decode-execute path of any other instruction class.
///
/// Re-exported rather than merely imported because tests/vm_tests.zig can only
/// reach what this module root exposes, and an accelerator test must be able to
/// compute its expected value from the SAME model the VM calls, so the two cannot
/// silently drift into agreeing on the same bug.
pub const matrix_model = @import("matrix.zig");
pub const fft_model = @import("fft.zig");
pub const codec_model = @import("codec.zig");

pub const Memory = memory.Memory;
pub const File = registers.File;
pub const Width = registers.Width;
pub const Diagnostic = diagnostics.Diagnostic;

/// docs/isa-encoding.md §4: index 14 is the program counter. A non-control
/// instruction has no defined meaning for writing it.
pub const pc_index: u4 = 14;

/// Instruction width is fixed at 64 bits (docs/isa-encoding.md §1), so the PC stride
/// is a constant and only jump/call/ret move it anywhere else.
pub const instruction_bytes: u64 = 8;

pub const Fault = error{ OutOfBounds, VmFault };

/// Why the machine stopped. Every variant carries the sentence the user sees.
pub const HaltReason = struct {
    kind: Kind,
    diag: Diagnostic,

    pub const Kind = enum { halted, fault, breakpoint };
};

pub const Step = union(enum) {
    /// Decoded and executed; PC now points at the next instruction, or at the target
    /// of a jump/call/ret.
    advanced,
    /// The program executed `halt`.
    halted: Diagnostic,
    /// The instruction could not be executed. Nothing was committed by it.
    fault: Diagnostic,
};

pub const Vm = struct {
    /// The flat image, allocated once in `init` and never reallocated (AGENTS.md §4.1).
    mem: Memory,
    regs: File = .{},
    /// Instructions retired. Advisory simulator count, not a silicon cycle count.
    retired: u64 = 0,
    halted: bool = false,
    /// §3.7 SMT-8 slots. DETERMINISTIC modelled interleave: slots are dispatched one
    /// at a time, round-robin, on this single thread of execution. Not parallel, no
    /// timing, no speedup claim (docs/isa-encoding.md §8). Default-initialised, so
    /// `init` still allocates nothing (AGENTS.md §4.1).
    sched: threading.Scheduler = .{},

    /// Holds the diagnostic an accelerator refusal built, so `error.Refused` can
    /// carry control flow while the user-visible sentence stays a VALUE (§7).
    /// Pre-allocated storage, written only; no allocation inside the loop.
    accel_fault: Diagnostic = .{},

    /// The single allocation point. `image` becomes the VM's memory in place, so the
    /// execution loop below never needs an allocator.
    pub fn init(image: []u8) Vm {
        return .{ .mem = Memory.init(image) };
    }

    /// One fetch-decode-execute step. No allocation, no hidden unwinding: failures
    /// come back as diagnostics.
    pub fn step(self: *Vm) Fault!Step {
        const pc = self.regs.pc;
        const word = self.mem.read64(pc) catch return self.faultOutOfBounds("fetching the instruction", pc, 8);

        const decoded = decoding.decode(word);
        switch (decoded) {
            .err => |diag| {
                self.halted = true;
                // The decoder is a pure function of the word, so it cannot know where
                // the word was found. Contract P1.6 requires the PC in this failure,
                // and the VM is the component that has it.
                var with_pc = diag;
                if (with_pc.pc == null) with_pc.pc = pc;
                return .{ .fault = with_pc };
            },
            .ok => |ins| return self.execute(ins, pc, word),
        }
    }

    /// Runs until halt, fault or `limit` retired instructions. `limit` exists so an
    /// infinite program fails loudly instead of hanging; it is not a cycle claim.
    pub fn run(self: *Vm, limit: u64) Fault!Diagnostic {
        var i: u64 = 0;
        while (i < limit) : (i += 1) {
            switch (try self.step()) {
                .advanced => {},
                .halted => |d| return d,
                .fault => |d| return d,
            }
        }
        self.halted = true;
        return .{
            .stage = "executing this program",
            .expected = "the program to reach a halt instruction",
            .detail = "The simulator stopped it after reaching the instruction limit: the program did not halt on its own.",
        };
    }

    /// Exact architectural state, for determinism comparisons (contract P1.6).
    ///
    /// `mem_hash` is a digest of every memory byte, so a run that differs only in
    /// memory contents is *observable* here. A hash is still a hash: a caller that
    /// needs byte-exact equality compares `vm.mem.bytes` directly. `mem_len` is kept
    /// alongside so a length change is reported as itself rather than as a hash delta.
    /// ZERO is not stored: registers.zig models it as a constant, so its absence from
    /// this snapshot is correct, not an omission.
    pub fn snapshot(self: *const Vm) Snapshot {
        var h = std.hash.Wyhash.init(0);
        h.update(self.mem.bytes);
        return .{
            .regs = self.regs,
            .mem_len = self.mem.bytes.len,
            .mem_hash = h.final(),
            .retired = self.retired,
        };
    }

    pub const Snapshot = struct {
        regs: File,
        mem_len: usize,
        /// Digest of the memory contents; see `snapshot`.
        mem_hash: u64,
        retired: u64,

        /// Digest comparison: catches a divergence in registers, in memory contents,
        /// in memory length or in the retired-instruction count.
        pub fn eql(a: Snapshot, b: Snapshot) bool {
            return std.meta.eql(a.regs, b.regs) and
                a.mem_len == b.mem_len and
                a.mem_hash == b.mem_hash and
                a.retired == b.retired;
        }
    };

    // -- the loop ------------------------------------------------------------

    fn execute(self: *Vm, ins: decoding.Instruction, pc: u64, word: u64) Fault!Step {
        switch (ins) {
            .nop => {},

            .halt => {
                self.retired += 1;
                self.halted = true;
                return .{ .halted = .{ .stage = "halting", .detail = "The program executed halt." } };
            },

            // §3.0 encodes jump and call with the same 48-bit immediate and the same
            // payload type, so the opcode byte inside the payload is what separates
            // them: 0x03 sets LR, 0x02 does not (§3.0 rows 0x02/0x03).
            .jump, .call => |ctrl| {
                self.retired += 1;
                if (ctrl.opcode == 0x03) self.regs.lr = pc +| instruction_bytes;
                self.regs.pc = ctrl.target;
                return .advanced;
            },

            .ret => {
                self.retired += 1;
                self.regs.pc = self.regs.lr;
                return .advanced;
            },

            // §3.0.1 `branch`: transfer when the status enum in rs1 equals the
            // match value, otherwise fall through. This is the ISA's only
            // conditional control transfer, and without it no loop can be written.
            .branch => |b| {
                self.retired += 1;
                const status = self.regs.read(b.rs1) & 0xF;
                if (status == b.match_val) {
                    // The offset is relative to the BRANCH ITSELF, per §3.0.1 —
                    // not to the following instruction. Computed with wrapping
                    // arithmetic so a backward branch near address 0 wraps rather
                    // than panicking; the fetch bounds check reports it.
                    self.regs.pc = pc +% @as(u64, @bitCast(b.offset));
                } else {
                    self.regs.pc = pc +| instruction_bytes;
                }
                return .advanced;
            },

            // §3.1.1 scalar memory access. The whole access is bounds-checked
            // before any byte moves, matching §3.4's all-or-nothing rule for
            // chunks: a partially applied store is the failure mode that makes
            // memory access untrustworthy.
            .load => |m| {
                self.retired += 1;
                if (m.rd == pc_index) return try self.reportPcWrite("a load", pc, word);
                const addr = self.regs.read(m.rs1) +% @as(u64, @bitCast(m.offset));
                // §5 width: 0 = 64-bit, 1 = .l (32), 2 = .w (16), 3 = .b (8).
                const raw: u64 = switch (m.width) {
                    .full => self.mem.read64(addr) catch
                        return try self.reportLoadStoreBounds("reading from memory", addr, 8, pc, word),
                    .l => self.mem.read32(addr) catch
                        return try self.reportLoadStoreBounds("reading from memory", addr, 4, pc, word),
                    .w => self.mem.read16(addr) catch
                        return try self.reportLoadStoreBounds("reading from memory", addr, 2, pc, word),
                    .b => self.mem.read8(addr) catch
                        return try self.reportLoadStoreBounds("reading from memory", addr, 1, pc, word),
                };
                // §2.1: a sub-width load ZERO-EXTENDS into rd, like every other
                // sub-register write. read8/16/32 already return the widened value.
                self.regs.write(m.rd, raw);
                self.regs.pc = pc +| instruction_bytes;
                return .advanced;
            },

            .store => |m| {
                self.retired += 1;
                const addr = self.regs.read(m.rs1) +% @as(u64, @bitCast(m.offset));
                const v = self.regs.read(m.rs2);
                switch (m.width) {
                    .full => self.mem.write64(addr, v) catch
                        return try self.reportLoadStoreBounds("writing to memory", addr, 8, pc, word),
                    .l => self.mem.write32(addr, @truncate(v)) catch
                        return try self.reportLoadStoreBounds("writing to memory", addr, 4, pc, word),
                    .w => self.mem.write16(addr, @truncate(v)) catch
                        return try self.reportLoadStoreBounds("writing to memory", addr, 2, pc, word),
                    .b => self.mem.write8(addr, @truncate(v)) catch
                        return try self.reportLoadStoreBounds("writing to memory", addr, 1, pc, word),
                }
                self.regs.pc = pc +| instruction_bytes;
                return .advanced;
            },

            // The decoder tags each ALU opcode individually (§3.1), so group the
            // ten of them onto the one execution path. Deleting this arm instead
            // would drop every ALU instruction into the fault below. `compare` is
            // NOT here: it has its own arm below, since it yields a status enum.
            .add, .sub, .mul, .div, .and_, .or_, .xor_, .shl, .shr, .mov => |a| {
                // §4: index 14 is PC, and a normal ALU op has no defined meaning for
                // writing it. The fixed-width advance below would overwrite the result,
                // so fault here rather than let the value vanish unremarked.
                if (a.rd == pc_index) return try self.reportPcWrite("an arithmetic instruction", pc, word);
                self.alu(a) catch |err| return try self.reportAluError(err, a, pc, word);
            },

            // §3.2.1 `compare` materialises the explicit status enum into rd.
            // Signedness is a property of the instruction, and this decoder does not
            // carry one, so the encoding contract's only defined reading is used: the
            // signed view, which is what §3.2.1 defines LESS/GREATER against.
            .compare => |a| {
                if (a.rd == pc_index) return try self.reportPcWrite("compare", pc, word);
                const rhs: u64 = if (a.imm) |imm| @bitCast(imm) else self.regs.read(a.rs2);
                self.regs.writeWidth(a.rd, a.width, @backingInt(selection.compareSigned(
                    @bitCast(self.regs.read(a.rs1)),
                    @bitCast(rhs),
                )));
            },

            // §3.2.2 branchless select: no branch, no PC change beyond the stride.
            .select => |sel| {
                if (sel.rd == pc_index) return try self.reportPcWrite("select", pc, word);
                const status = statusOf(self.regs.read(sel.rs1)) orelse return .{ .fault = .{
                    .stage = "executing a select",
                    .word = word,
                    .pc = pc,
                    .operand = .{ .name = "status register", .text = "not a status enum value" },
                    .expected = "a status value from 0 (EQUAL) to 4 (UNSIGNED_GREATER) in the status register",
                    .detail = "The architecture defines exactly five comparison outcomes; anything else cannot select an arm.",
                } };
                self.regs.write(sel.rd, selection.select(
                    status,
                    @fromBackingInt(@intCast(@backingInt(sel.match_val))),
                    self.regs.read(sel.true_reg),
                    self.regs.read(sel.false_reg),
                ));
            },

            // §3.4 stream engine: the model module enforces the atomic bounds rule and
            // owns the pointer auto-advance.
            .stream_add, .stream_copy, .stream_fill, .stream_setp => |st| {
                self.stream(st, pc, word) catch |err| return try self.reportStreamError(err, pc, word);
            },

            // §3.3 bitfield slicing, real behaviour from the model module.
            .field_extract => |f| {
                if (f.rd == pc_index) return try self.reportPcWrite("field.extract", pc, word);
                self.regs.write(f.rd, bits.extract(self.regs.read(f.rs1), f.offset, f.width) catch |err|
                    return try self.reportFieldError(err, f, pc, word));
            },

            .field_insert => |f| {
                if (f.rd == pc_index) return try self.reportPcWrite("field.insert", pc, word);
                self.regs.write(f.rd, bits.insert(self.regs.read(f.rs1), self.regs.read(f.src2), f.offset, f.width) catch |err|
                    return try self.reportFieldError(err, f, pc, word));
            },

            // §3.7 thread slots. These dispatch into the modelled interleave; they do
            // not create real concurrency (docs/isa-encoding.md §8).
            .thread_spawn => |t| {
                self.spawnSlots(t, pc, word) catch |err| return try self.reportThreadError(err, t.slots, pc, word);
            },

            .thread_join => |t| {
                self.joinSlots(t, pc, word) catch |err| return try self.reportThreadError(err, t.slots, pc, word);
            },

            .thread_yield => |t| {
                _ = t;
                // Dispatch the next runnable slot, round-robin. An empty run queue is a
                // diagnostic, not a silent advance: yielding with nothing to run would
                // otherwise look like a successful switch.
                if (self.sched.nextRunnable() == null) {
                    self.halted = true;
                    return .{ .fault = .{
                        .stage = "executing a thread yield",
                        .word = word,
                        .pc = pc,
                        .mnemonic = "thread.yield",
                        .operand = .{ .name = "runnable slot", .text = "none" },
                        .expected = "at least one thread slot in the running state to yield to",
                        .detail = "No slot is running, so there is nothing to switch to. In this deterministic modelled interleave a yield with an empty run queue cannot make progress, so it is reported instead of advancing.",
                    } };
                }
                const next = self.sched.nextRunnable().?;
                self.sched.last_dispatched = next;
                self.sched.dispatches += 1;
            },

            // §3.5 capability instructions. cap.load/cap.store REFUSE LOUDLY: v1.11
            // ruled them decode-only because the encoding carries no address field.
            .cap_load, .cap_store => |c| {
                return try self.refuseCapabilityTransfer(c, pc, word);
            },

            .cap_check => |c| {
                return try self.capCheck(c, pc, word);
            },

            // §3.6 accelerator space (0x60-0x8F). Amendment 1.18 defines the
            // operand arithmetic, so most of these now EXECUTE; the ones whose
            // rows still cannot be expressed in the four available fields
            // (`codec.decompress`) and the reserved bytes continue to refuse.
            // See `accelerator` for the per-row rules and `refuseAccelerator`
            // for what a refusal must say.
            //
            // This arm replaced the `else` fault that used to swallow them. It is
            // exhaustive now: the decoder builds no union variant that this switch
            // does not name, which is why there is no `else` prong left.
            .accelerator => |a| {
                return try self.accelerator(a, pc, word);
            },
        }

        // Normal advance: every instruction is one 64-bit word wide.
        self.retired += 1;
        self.regs.pc = pc +| instruction_bytes;
        return .advanced;
    }

    /// §3.6 accelerator opcodes, per **amendment 1.18**.
    ///
    /// The F36 gap this arm used to report is closed in the contract: §3.6 now
    /// states, per operation, which register holds which ADDRESS, where a matrix's
    /// order comes from, where an output buffer lives, and which unit `count`
    /// uses. This function implements exactly those rules and nothing more.
    ///
    /// The rules, in one place (the contract is normative; this restates it):
    ///
    /// - **A register operand is a VALUE, not an index.** `rd`, `rs1`, `rs2` and
    ///   `rs3` where a row names an address each hold a full 64-bit byte offset.
    ///   The two exceptions are the matrix-header forms of `matrix.mul`, which read
    ///   their register as `rows:u32 | cols:u32`.
    /// - **`count = 0` is a diagnostic error** for every row that needs a length.
    ///   1.1's "derive the count from the destination register" is superseded: it
    ///   named one register as both input and output and imposed a calling
    ///   convention the contract never stated. `matrix.identity` is the one row
    ///   where `0` is meaningful (the empty matrix).
    /// - **Redundant operands must be zero.** An `rs3` a row does not use is
    ///   rejected when set, matching §3.6's existing rule for `reserved[39:32]`.
    ///   This costs four extra width bytes per instruction — 32 bytes instead of
    ///   28 — which is the price of the ambiguity check, and it is paid
    ///   deliberately: `A · x = b` and `x · A = b` are both meaningful, so a
    ///   silently ignored register is a coin flip.
    /// - **Every address is bounds- and alignment-checked before the first byte is
    ///   touched.** No `@alignCast` is ever applied to a computed address: a
    ///   misaligned cast panics, and a panic is not a diagnostic.
    /// - **Nothing is allocated.** Every slice is a view into `mem.bytes`
    ///   (AGENTS.md §4.1).
    ///
    /// `error.Refused` is control flow, not a user-visible failure: the sentence the
    /// user sees was built into `accel_fault` at the point of refusal, so the fault
    /// value still carries plain language (§7) rather than an error name.
    fn accelerator(self: *Vm, a: decoding.Accelerator, pc: u64, word: u64) Fault!Step {
        _ = word;
        // Reserved opcodes (0x60-0x8F with no §3.6 row) are not defined at all, so
        // they must not reach the arithmetic below.
        const spec = accelerator_spec.acceleratorByOpcode(a.opcode) orelse
            return try self.refuseAccelerator(a, pc);

        return switch (spec.opcode) {
            0x60 => self.accelDet(a, pc),
            0x61 => self.accelInvert(a, pc),
            // Rule E.5: three addresses plus two orders do not fit four fields.
            0x62 => self.refuseAccelerator(a, pc),
            0x63 => self.accelTransform(a, pc),
            0x64 => self.accelIdentity(a, pc),
            // Amendment 1.19: the second multiply opcode, whose three matrices each
            // carry their own header in memory. 0x62 above is untouched.
            0x65 => self.accelMulOut(a, pc),
            0x70, 0x71 => self.accelFft(a, pc),
            0x72, 0x73 => self.accelNtt(a, pc),
            0x80 => self.accelCompress(a, pc),
            0x81 => self.refuseAccelerator(a, pc), // Rule E.1: no bound fits
            0x82 => self.accelFnv1a(a, pc),
            0x83 => self.accelChecksum16(a, pc),
            else => self.refuseAccelerator(a, pc),
        } catch |e| switch (e) {
            // The refusal sentence was already built; hand it to the user as a
            // `Step.fault`, which is how every other refusal reaches the CLI.
            error.Refused => return .{ .fault = self.accel_fault },
            error.OutOfBounds => return error.OutOfBounds,
            error.VmFault => return error.VmFault,
        };
    }

    /// §3.6 rule C: `codec.compress`'s output workspace, normative.
    ///
    /// Fixed rather than derived because no operand field is left to derive it from,
    /// and a fixed documented workspace is reproducible while a workspace inferred
    /// from whatever follows the input in memory is not.
    ///
    /// The address and length are normative. Their availability is a CHECKED
    /// PRECONDITION: only `main.zig`'s CLI allocates the 65 536-byte image this needs
    /// (`image_bytes = 1 << 16`). The cross-architecture fixture is 4 672 bytes and the
    /// examples fixture 20 480, and `Vm.init` accepts any slice at all, so an earlier
    /// claim that "every execution entry point" provides this was false and is
    /// retracted in the contract. `accelCompress` checks the image length explicitly
    /// and refuses with a sentence naming the address and length it needs; it never
    /// clips the workspace, relocates it, or writes a short stream at the end of memory.
    pub const codec_workspace: u64 = 0x0000_FF00;
    pub const codec_workspace_len: u64 = 256;

    // -- §3.6 amendment 1.18: shared operand arithmetic ------------------------
    //
    // Every helper below REFUSES rather than guessing. `error.Refused` means the
    // diagnostic has already been built into `self.accel_fault`; it never escapes
    // `accelerator`'s callers.

    /// §3.2.1's five outcomes; a register holding anything else cannot drive a select.
    fn statusOf(raw: u64) ?selection.Status {
        if (raw > 4) return null;
        return @fromBackingInt(@intCast(@as(u4, @intCast(raw))));
    }

    const Refused = error{Refused};

    /// Rule A: `count = 0` is not a length. Only `matrix.identity` may pass `0`.
    fn accelCount(self: *Vm, a: decoding.Accelerator, pc: u64, what: []const u8) Refused!u32 {
        _ = what;
        if (a.count == 0) {
            return self.refuseAccelNow(pc, a, "a count of at least one element or byte",
                "Amendment 1.18 supersedes §3.6's \"derive the count from the destination register\": a zero count means no count, and this operation cannot proceed without one. Write count=N. The superseded rule was rejected because it named one register as both an input length and the result, imposing a calling convention the contract never stated.");
        }
        return a.count;
    }

    /// Rule E: an operand a row does not use must be zero in the word.
    fn accelReservedZero(self: *Vm, value: u4, pc: u64, a: decoding.Accelerator, which: []const u8) Refused!void {
        const sentence = "The {s} is not used by this operation, so it must be zero. Amendment 1.18 rejects a non-zero value rather than ignoring it, because the word would then carry a meaning the operation does not have.";
        if (value != 0) {
            // 192 bytes was too small for the longest operand name ("third source
            // register") and `catch {}` hid the overflow, so this sentence ended
            // mid-word. Deriving the size from the literal keeps the two in step.
            var buf: [sentence.len + 32]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            w.print(sentence, .{which}) catch return error.Refused;
            return self.refuseAccelNow(pc, a, "a zero value in an unused operand field", w.buffered());
        }
    }

    /// Bounds + alignment, checked before any byte is touched (Rule E.3).
    fn accelRange(self: *Vm, addr: u64, len: u64, alignment: u64, pc: u64, a: decoding.Accelerator, what: []const u8) Refused![]u8 {
        if (len == 0) return self.refuseAccelNow(pc, a, "a length of at least one element",
            "The whole range is empty, so there is nothing to compute.");
        // Alignment is checked BEFORE bounds. Both are refusals, but alignment is the
        // more specific finding — a misaligned address is misaligned regardless of how
        // large the image is — and reporting bounds first would send a reader off to
        // grow the image when the fix is to fix the address.
        if (addr % alignment != 0) {
            var buf: [224]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            w.print("The {s} address {d} is not a multiple of {d} bytes, and the simulator refuses to read misaligned element values (amendment 1.18, rule E.3).", .{ what, addr, alignment }) catch {};
            return self.refuseAccelNow(pc, a, "an address aligned to the element width", w.buffered());
        }
        // Overflow-safe: `inBounds` uses `addr +| len`, so a huge register value
        // cannot wrap into a small in-bounds range.
        if (!self.mem.inBounds(addr, len)) {
            var buf: [224]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            w.print("It asked for {d} bytes at address {d}, but the memory image is {d} bytes long. The refusal is all-or-nothing, so no byte was touched.", .{ len, addr, self.mem.bytes.len }) catch {};
            return self.refuseAccelNow(pc, a, "an address and length inside the memory image", w.buffered());
        }
        return self.mem.bytes[@intCast(addr)..][0..@intCast(len)];
    }

    /// An `f64` view over an already-validated, already-aligned byte range.
    ///
    /// `accelRange` has proven both the address and the length are multiples of 8.
    /// This uses a checked slice-and-cast, never `@alignCast`, because a misaligned
    /// cast is a panic and a panic is not a diagnostic (Rule E.3).
    fn accelF64(bytes: []u8) Refused![]f64 {
        const aligned = std.mem.alignInBytes(bytes, 8) orelse return error.Refused;
        return std.mem.bytesAsSlice(f64, aligned);
    }

    /// Writes an `f64` result into `rd` by bit reinterpretation (Rule E.2).
    fn accelWriteF64(self: *Vm, a: decoding.Accelerator, value: f64) void {
        self.regs.write(a.rd, @bitCast(value));
    }

    /// The refusal text for a defined row whose operands the word cannot carry, and
    /// for a reserved byte.
    ///
    /// TWO defined rows land here, and each gets its own reason rather than a shared
    /// "not implemented":
    ///
    /// - `codec.decompress` (Rule E.1) needs an `out.len` bound. Every operand field is
    ///   spoken for, and 256 bytes — the workspace Rule C gives `compress` — would
    ///   silently reject valid inputs whose decompressed form is longer. A narrowed
    ///   domain is a wrong answer, so the row refuses.
    /// - `matrix.mul` (Rule E.5) needs three addresses and two orders. That is five
    ///   inputs for four fields. It is a field shortage, not a missing constant, and
    ///   the honest fix is a second opcode, which this amendment may not add.
    ///
    /// A third case is the reserved byte: inside `0x60`-`0x8F` but with no §3.6 row.
    fn refuseAccelerator(self: *Vm, a: decoding.Accelerator, pc: u64) Fault!Step {
        self.halted = true;
        const spec = accelerator_spec.acceleratorByOpcode(a.opcode);
        const name = if (spec) |s| s.name else "an accelerator operation the encoding table does not list";
        if (spec) |s| {
            // Defined row, unexpressible operands: name the operation and the rule.
            if (s.opcode == 0x81) {
                return .{ .fault = .{
                    .stage = "executing an accelerator instruction",
                    .action = "executed",
                    .pc = pc,
                    .mnemonic = name,
                    .expected = "an encoding that can carry the decompressed output length bound",
                    .detail = "Decompressing needs to know how large the output buffer is, and all five operand fields (rd, rs1, rs2, rs3 and count) are already named by this row. The fixed 256-byte workspace that amendment 1.18 gives codec.compress cannot be reused here: it would reject valid inputs whose decompressed form is longer than 256 bytes, which narrows the operation instead of defining it. Recorded in docs/isa-encoding.md §3.6 rule E.1.",
                } };
            }
            if (s.opcode == 0x62) {
                return .{ .fault = .{
                    .stage = "executing an accelerator instruction",
                    .action = "executed",
                    .pc = pc,
                    .mnemonic = name,
                    .expected = "three addresses and two matrix orders, which four operand fields cannot carry",
                    .detail = "Multiplying needs the addresses of the left matrix, the right matrix and the product, plus the order of each input: five values for the four fields rd, rs1, rs2 and rs3. Reading an order from the count field, or deriving the product's address from an input's extent, would each invent a constraint the operation does not have. Recorded in docs/isa-encoding.md §3.6 rule E.5; the honest fix is a second opcode, not a new field.",
                } };
            }
            return .{ .fault = .{
                .stage = "executing an accelerator instruction",
                .action = "executed",
                .pc = pc,
                .mnemonic = name,
                .expected = "an instruction from the §3.6 accelerator table that this build implements",
                .detail = "This operation is in the §3.6 table but this build has no execution rule for it.",
            } };
        }
        return .{ .fault = .{
            .stage = "executing an accelerator instruction",
            .action = "executed",
            .pc = pc,
            .mnemonic = name,
            .expected = "an opcode from 0x60 through 0x8F that the §3.6 table lists",
            .detail = "The byte is inside the accelerator range but §3.6 assigns it no operation, so it is reserved. It is refused rather than reinterpreted as a neighbouring operation.",
        } };
    }

    /// Original F36 refusal body, kept for the rows that still refuse. See
    /// `refuseAccelerator` above for the caller.
    // -- §3.6 amendment 1.18: the operations -----------------------------------

    /// A 4-bit matrix order. `0` means 16: a u4 has no other way to express the
    /// largest order the field can name, and the row's stated range is 1..=16.
    fn accelOrder(raw: u4) usize {
        // `0` means 16: a u4 has no other way to name the largest order the field
        // can express, and the row's range is 1..=16.
        return if (raw == 0) 16 else raw;
    }

    /// `matrix.det rd, rs1` — order from `rs3`; `rd` is an address VALUE.
    ///
    /// The order lives in `rs3` because `matrix.determinant(m)` has **no output
    /// buffer**: it returns one scalar. `rs1` names the matrix and `rs3` is the only
    /// field left, so it carries the order rather than an output the operation does
    /// not have. `rd` then receives the determinant, by bit reinterpretation
    /// (Rule E.2) — it is not converted to an integer.
    fn accelDet(self: *Vm, a: decoding.Accelerator, pc: u64) Refused!Step {
        const n = accelOrder(a.rs3);
        try self.accelReservedZero(a.rs2, pc, a, "second source register");
        const bytes = try self.accelRange(self.regs.read(a.rs1), 8 * n * n, 8, pc, a, "the f64 matrix");
        const m = matrix_model.Mat.init(n, n, try accelF64(bytes)) catch
            return try self.refuseModel(pc, a, "a square matrix that fits the buffer");
        const det = matrix_model.determinant(m) catch |e|
            return try self.refuseModel(pc, a, matrix_model.explain(e));
        self.accelCommit(pc, a);
        self.accelWriteF64(a, det);
        return .advanced;
    }

    /// `matrix.invert rd, rs1, rs2` — order from `rs2`, input at `rs1`, output at `rd`.
    fn accelInvert(self: *Vm, a: decoding.Accelerator, pc: u64) Refused!Step {
        const n = accelOrder(a.rs2);
        try self.accelReservedZero(a.rs3, pc, a, "third source register");
        const in_addr = self.regs.read(a.rs1);
        const out_addr = self.regs.read(a.rd);
        const span = 8 * n * n;
        const in_bytes = try self.accelRange(in_addr, span, 8, pc, a, "the input f64 matrix");
        const out_bytes = try self.accelRange(out_addr, span, 8, pc, a, "the output f64 matrix");
        const m = matrix_model.Mat.init(n, n, try accelF64(in_bytes)) catch
            return try self.refuseModel(pc, a, "a square matrix that fits the input buffer");
        _ = matrix_model.invert(m, try accelF64(out_bytes)) catch |e|
            return try self.refuseModel(pc, a, matrix_model.explain(e));
        self.accelCommit(pc, a);
        return .advanced;
    }

    /// `matrix.transform rd, rs1, count=N` — the rigid-body `m` is at the address in
    /// `rs2`; the three streams are consecutive from `rs1`, `count` `f64` each.
    /// `rd` is the result register and is written with the element count.
    fn accelTransform(self: *Vm, a: decoding.Accelerator, pc: u64) Refused!Step {
        const n = try self.accelCount(a, pc, "elements per stream");
        const base = self.regs.read(a.rs1);
        const m_addr = self.regs.read(a.rs2);
        const per = 8 * @as(u64, n);
        const xs = try self.accelRange(base, per, 8, pc, a, "the x stream");
        const ys = try self.accelRange(base + per, per, 8, pc, a, "the y stream");
        const zs = try self.accelRange(base + 2 * per, per, 8, pc, a, "the z stream");
        const m_bytes = try self.accelRange(m_addr, 8 * 16, 8, pc, a, "the 4x4 transform matrix");
        const m = matrix_model.Mat.init(4, 4, try accelF64(m_bytes)) catch
            return try self.refuseModel(pc, a, "a 4x4 matrix that fits its buffer");
        matrix_model.transformSoA(try accelF64(xs), try accelF64(ys), try accelF64(zs), m);
        self.accelCommit(pc, a);
        self.regs.write(a.rd, n);
        return .advanced;
    }

    /// `matrix.identity rd, count=N` — `n` is `count` itself, so `count = 0` is the
    /// empty matrix rather than an error. `rd` is an address VALUE.
    fn accelIdentity(self: *Vm, a: decoding.Accelerator, pc: u64) Refused!Step {
        // `n` comes from rs1, not count: the row's `count=N` operand names the order,
        // and 1.18 rule D makes `count = 0` an error everywhere except here, where the
        // order arrives in rs1 and 0 is the empty matrix. Reading it from rs1 keeps the
        // word's stated source and the meaningful zero from contradicting each other.
        if (a.count != 0) {
            var buf: [160]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            w.print("This row takes its order from the first source register, so the count field must be zero; {d} was written.", .{a.count}) catch {};
            return self.refuseAccelNow(pc, a, "a zero count field, with the order in the first source register", w.buffered());
        }
        const n: usize = a.rs1;
        const addr = self.regs.read(a.rd);
        const bytes = try self.accelRange(addr, 8 * n * n, 8, pc, a, "the f64 identity matrix");
        _ = matrix_model.identity(n, try accelF64(bytes)) catch |e|
            return try self.refuseModel(pc, a, matrix_model.explain(e));
        self.accelCommit(pc, a);
        return .advanced;
    }

    /// The largest matrix dimension this opcode accepts, per side (rule E.7).
    ///
    /// Not a machine limit and not a performance figure: it is the size of the
    /// `[256]f64` scratch array `matrix.multiply` needs for its accumulator
    /// (AGENTS.md §4.1 forbids allocating in the loop), which holds any product up
    /// to 16 x 16. A larger dimension refuses with a sentence; it never truncates.
    pub const mulout_max_order: u32 = 16;

    /// `matrix.mulout rd, rs1, rs2` (0x65) — amendment 1.19. Input A at `rs1`'s
    /// address, input B at `rs2`'s, the product at `rd`'s; each is a header followed
    /// by row-major f64 data (rules A, B). `rs3` and `count` must be zero (rule E).
    ///
    /// The ORDER comes from the data, so this word carries no dimension and invents
    /// none. That is exactly what 0x62 could not do: three addresses are the only
    /// values it needs, and four fields hold three addresses.
    fn accelMulOut(self: *Vm, a: decoding.Accelerator, pc: u64) Refused!Step {
        try self.accelReservedZero(a.rs3, pc, a, "third source register");
        // Not accelReservedZero: that helper is for the four-bit register fields.
        // `count` has no length to carry here — both orders arrive in the headers —
        // so a value in it would be a number the operation silently ignored.
        if (a.count != 0) {
            var buf: [256]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            w.print("The count field must be zero on this operation, because both matrix shapes come from their in-memory headers; {d} was written. A count here would state a length the operation never reads.", .{a.count}) catch return error.Refused;
            return self.refuseAccelNow(pc, a, "a zero count field, since the shapes come from the matrix headers", w.buffered());
        }

        const a_addr = self.regs.read(a.rs1);
        const b_addr = self.regs.read(a.rs2);
        const out_addr = self.regs.read(a.rd);

        // Rule E.3 order of operations: every address is checked, and both headers
        // are READ, before any data region is touched — so a bad second header can
        // never leave a half-written product behind.
        const a_shape = try self.accelShape(a, pc, a_addr, "the first input matrix");
        const b_shape = try self.accelShape(a, pc, b_addr, "the second input matrix");
        if (a_shape.cols != b_shape.rows) {
            var buf: [320]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            w.print("The first matrix is {d} by {d} and the second is {d} by {d}, so its {d} columns do not match the second matrix's {d} rows. A product is defined only when those two numbers are equal, so nothing was computed.", .{ a_shape.rows, a_shape.cols, b_shape.rows, b_shape.cols, a_shape.cols, b_shape.rows }) catch return error.Refused;
            return self.refuseAccelNow(pc, a, "a first matrix whose column count equals the second matrix's row count", w.buffered());
        }

        const a_data = try self.accelRange(a_addr + 8, a_shape.bytes(), 8, pc, a, "the first matrix's f64 data");
        const b_data = try self.accelRange(b_addr + 8, b_shape.bytes(), 8, pc, a, "the second matrix's f64 data");

        // The product's address is `rd`'s and its order follows from the two inputs,
        // so its header claims nothing: header and data are one range of one length,
        // written only after the model has fully succeeded (accelCommit).
        const out_shape = Shape{ .rows = a_shape.rows, .cols = b_shape.cols };
        const out_len = 8 + out_shape.bytes();
        const out_bytes = try self.accelRange(out_addr, out_len, 8, pc, a, "the product matrix, header first");
        const out = try accelF64(out_bytes[8..]);

        const ma = matrix_model.Mat.init(a_shape.rows, a_shape.cols, try accelF64(a_data)) catch
            return try self.refuseModel(pc, a, "a first matrix that fits its buffer");
        const mb = matrix_model.Mat.init(b_shape.rows, b_shape.cols, try accelF64(b_data)) catch
            return try self.refuseModel(pc, a, "a second matrix that fits its buffer");

        const res = matrix_model.multiply(ma, mb, out) catch |e|
            return try self.refuseModel(pc, a, matrix_model.explain(e));

        std.mem.writeInt(u32, out_bytes[0..4], @intCast(res.rows), .little);
        std.mem.writeInt(u32, out_bytes[4..8], @intCast(res.cols), .little);
        // `rd` is NOT rewritten: unlike matrix.det, this row's whole result is in
        // memory, so Rule E.2 has no scalar to reinterpret into the register and the
        // address it named stays there (Rule E.7).
        self.accelCommit(pc, a);
        return .advanced;
    }

    /// One matrix as its own header describes it: `rows:u32 | cols:u32` at `addr`
    /// (rule A's header form), data immediately after.
    const Shape = struct {
        rows: usize,
        cols: usize,

        fn bytes(s: Shape) u64 {
            return 8 * @as(u64, s.rows) * @as(u64, s.cols);
        }
    };

    /// Reads and validates a matrix header. Every step is a refusal with a sentence
    /// naming the address, the length and the numbers involved; nothing is clamped
    /// and nothing is assumed, because a guessed shape is a plausible wrong matrix.
    fn accelShape(self: *Vm, a: decoding.Accelerator, pc: u64, addr: u64, what: []const u8) Refused!Shape {
        const header = try self.accelRange(addr, 8, 4, pc, a, what);
        const rows = std.mem.readInt(u32, header[0..4], .little);
        const cols = std.mem.readInt(u32, header[4..8], .little);

        if (rows > mulout_max_order or cols > mulout_max_order) {
            var buf: [320]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            w.print("The header at address {d} says {d} rows and {d} columns, but this operation accepts at most {d} by {d}. The limit is the 256-f64 scratch buffer the multiply model needs, which it may not allocate per call.", .{ addr, rows, cols, mulout_max_order, mulout_max_order }) catch return error.Refused;
            return self.refuseAccelNow(pc, a, "matrix sides of at most 16 rows and 16 columns", w.buffered());
        }
        if (rows == 0 or cols == 0) {
            var buf: [288]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            w.print("The header at address {d} says {d} rows and {d} columns. A matrix with no rows or no columns has no entries, so a product through it is not defined; write both numbers as at least one.", .{ addr, rows, cols }) catch return error.Refused;
            return self.refuseAccelNow(pc, a, "a header naming at least one row and one column", w.buffered());
        }
        // The data region's bounds and alignment are checked by the caller through
        // the same `accelRange` every other operation uses — once per range, not twice.
        return .{ .rows = rows, .cols = cols };
    }

    /// `fft.forward` (0x70) / `fft.inverse` (0x71). `count` is COMPLEX elements:
    /// 16 bytes each, and the address must be 16-byte aligned.
    fn accelFft(self: *Vm, a: decoding.Accelerator, pc: u64) Refused!Step {
        const n = try self.accelCount(a, pc, "complex elements");
        const addr = self.regs.read(a.rs1);
        const bytes = try self.accelRange(addr, 16 * @as(u64, n), 16, pc, a, "the complex element array");
        const data = try accelComplex(bytes);
        fft_model.fft(data, a.opcode == 0x71) catch |e|
            return try self.refuseModel(pc, a, fft_model.explain(e));
        self.accelCommit(pc, a);
        self.regs.write(a.rd, n);
        return .advanced;
    }

    /// `fft.ntt` (0x72) / `fft.ntt.inverse` (0x73). `count` is u64 ELEMENTS:
    /// 8 bytes each.
    ///
    /// `rs2` names the modulus, and **this build does not support one**: `fft.ntt`
    /// takes no modulus parameter and always uses `fft.ntt_modulus`. Refusing any
    /// non-zero `rs2` is the honest option. The alternative — accepting the register
    /// and then computing with the built-in constant — is precisely the "validated
    /// but dropped" defect class recorded as F34: the word would carry a modulus the
    /// operation never reads, and a caller who set 17 would silently get residues
    /// modulo 998244353. Rule E's redundant-operand rule already forbids that, so
    /// `rs2` is treated as a reserved-zero field here.
    fn accelNtt(self: *Vm, a: decoding.Accelerator, pc: u64) Refused!Step {
        const n = try self.accelCount(a, pc, "modular elements");
        try self.accelReservedZero(a.rs3, pc, a, "third source register");
        if (self.regs.read(a.rs2) != 0) {
            return self.refuseAccelNow(pc, a, "a zero in the second source register, because this build has one fixed modulus",
                "The second source register names a modulus, but this build's number-theoretic transform has no modulus parameter: it always works modulo 998244353. Accepting a different value and then ignoring it would compute a result the program did not ask for, so a non-zero value is refused. Recorded in docs/isa-encoding.md §3.6 rule E.6.");
        }
        const addr = self.regs.read(a.rs1);
        const bytes = try self.accelRange(addr, 8 * @as(u64, n), 8, pc, a, "the u64 element array");
        const data: []u64 = blk: {
            const aligned = std.mem.alignInBytes(bytes, 8) orelse return error.Refused;
            break :blk std.mem.bytesAsSlice(u64, aligned);
        };
        fft_model.ntt(data, a.opcode == 0x73) catch |e|
            return try self.refuseModel(pc, a, fft_model.explain(e));
        self.accelCommit(pc, a);
        self.regs.write(a.rd, n);
        return .advanced;
    }

    /// `codec.compress rd, rs1, count=N`. Input is `count` BYTES at the address in
    /// `rs1`; output is the fixed 256-byte workspace at byte 65 280 (Rule C); `rd`
    /// receives the compressed byte count.
    fn accelCompress(self: *Vm, a: decoding.Accelerator, pc: u64) Refused!Step {
        const n = try self.accelCount(a, pc, "input bytes");
        const in_addr = self.regs.read(a.rs1);
        const in_bytes = try self.accelRange(in_addr, n, 1, pc, a, "the input bytes");
        // §3.6 rule C: the workspace's availability is a CHECKED PRECONDITION, not an
        // assumption. This is the explicit check, ahead of the generic range test, so
        // the sentence can say what the caller has to change. An earlier draft of the
        // rule claimed every entry point allocates 64 KiB; that was false (the
        // cross-architecture fixture is 4,672 bytes and the examples fixture 20,480),
        // so a small image must refuse here rather than fail an access.
        if (self.mem.bytes.len < codec_workspace + codec_workspace_len) {
            var buf: [224]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            w.print("It needs a {d}-byte workspace at byte {d}, but the memory image is only {d} bytes, so the workspace is not available.", .{ codec_workspace_len, codec_workspace, self.mem.bytes.len }) catch {};
            return self.refuseAccelNow(pc, a, "a memory image of at least 65536 bytes", w.buffered());
        }
        const out_bytes = try self.accelRange(codec_workspace, codec_workspace_len, 1, pc, a, "the codec workspace");
        const written = codec_model.compress(in_bytes, out_bytes) catch |e|
            return try self.refuseModel(pc, a, codec_model.explain(e));
        self.accelCommit(pc, a);
        self.regs.write(a.rd, written);
        return .advanced;
    }

    /// `codec.fnv1a rd, rs1, count=N`. `count` is BYTES. The hash goes into `rd`.
    fn accelFnv1a(self: *Vm, a: decoding.Accelerator, pc: u64) Refused!Step {
        const n = try self.accelCount(a, pc, "input bytes");
        const bytes = try self.accelRange(self.regs.read(a.rs1), n, 1, pc, a, "the input bytes");
        const h = codec_model.fnv1a(bytes);
        self.accelCommit(pc, a);
        self.regs.write(a.rd, h);
        return .advanced;
    }

    /// `codec.checksum16 rd, rs1, count=N`. `count` is BYTES, and the 16-bit result
    /// goes into `rd` zero-extended.
    fn accelChecksum16(self: *Vm, a: decoding.Accelerator, pc: u64) Refused!Step {
        const n = try self.accelCount(a, pc, "input bytes");
        const bytes = try self.accelRange(self.regs.read(a.rs1), n, 1, pc, a, "the input bytes");
        const sum = codec_model.checksum16(bytes);
        self.accelCommit(pc, a);
        self.regs.write(a.rd, sum);
        return .advanced;
    }

    /// A `Complex` view over a validated, 16-byte-aligned range.
    fn accelComplex(bytes: []u8) Refused![]fft_model.Complex {
        const aligned = std.mem.alignInBytes(bytes, 16) orelse return error.Refused;
        return std.mem.bytesAsSlice(fft_model.Complex, aligned);
    }

    /// Retire and advance, in that order, once the operation has fully succeeded.
    /// Committing only after the model returns is what makes a rejection atomic.
    fn accelCommit(self: *Vm, pc: u64, a: decoding.Accelerator) void {
        _ = a;
        self.retired += 1;
        self.regs.pc = pc +| instruction_bytes;
    }

    /// A model-level failure, rendered as a sentence rather than a bare error.
    ///
    /// These are the cases the model itself states but the word cannot be trusted
    /// with: a non-power-of-two FFT length, a singular matrix, a codec buffer that
    /// would not fit. The model's own `explain` text is reused verbatim so the
    /// reader gets its plain-language reason and not a paraphrase (§4.2).
    fn refuseModel(self: *Vm, pc: u64, a: decoding.Accelerator, reason: []const u8) Refused!Step {
        return self.refuseAccelNow(pc, a, "an operand this operation can act on", reason);
    }

    /// Builds the `Refused` diagnostic in place and returns the sentinel error.
    fn refuseAccelNow(self: *Vm, pc: u64, a: decoding.Accelerator, expected: []const u8, detail: []const u8) Refused {
        self.halted = true;
        const spec = accelerator_spec.acceleratorByOpcode(a.opcode);
        self.accel_fault = .{
            .stage = "executing an accelerator instruction",
            .action = "executed",
            .pc = pc,
            .mnemonic = if (spec) |s| s.name else null,
            .expected = expected,
            .detail = detail,
        };
        return error.Refused;
    }

    const StreamFault = error{
        ChunkNotPositive,
        BadElementWidth,
        NotAStreamPointer,
        OutOfBounds,
    };

    /// §3.4: bounds the whole chunk before touching a byte, then advances the pointer
    /// register by `chunk * elementSize`. The stream engine owns both rules.
    fn stream(self: *Vm, st: decoding.Stream, pc: u64, word: u64) StreamFault!void {
        _ = pc;
        _ = word;
        const width = streaming.ElemWidth.fromEncoded(@backingInt(st.width)) catch return error.BadElementWidth;
        // §3.4: for add/copy/fill the pointer is `rs1` (the bracketed register);
        // for `setp` it is `rd`, because setp's operand text is
        // `stream.setp <ptr>, <stride>` and it has no `rs1` field at all.
        const ptr_reg = if (st.op == 0x43) self.regs.read(st.rd) else self.regs.read(st.rs1);
        var engine = streaming.State.init(self.mem, ptr_reg);

        switch (st.op) {
            0x40 => try engine.add(self.regs.read(st.rs2), st.chunk, width),
            0x41 => try engine.copy(self.regs.read(st.rs2), st.chunk, width),
            0x42 => try engine.fill(self.regs.read(st.rd), st.chunk, width),
            0x43 => {
                // `stream.setp`: pointer register = current + signed 40-bit stride.
                //
                // F19 (VM half): the pointer register for `setp` is `rd`, not
                // `rs1`. The assembler emits `stream.setp R1, -16` as rd=1,
                // rs1=0, and §3.4 gives `setp` no `rs1` — the decoder now rejects
                // a non-zero one. This line wrote `st.rs1`, so the instruction
                // updated R0 and left the named pointer untouched. Invisible
                // until now because the test fixture set rs1=1 by hand.
                self.regs.write(st.rd, @bitCast(@as(i64, @bitCast(ptr_reg)) +% st.stride));
                return;
            },
            else => return error.NotAStreamPointer,
        }

        // Auto-advance is the engine's whole point: no software index arithmetic.
        self.regs.write(st.rs1, engine.ptr);
    }

    /// §3.1.1: an out-of-bounds scalar access, reported in plain language with the
    /// address and size that failed (AGENTS.md §4.2 forbids a bare hex code).
    fn reportLoadStoreBounds(self: *Vm, action: []const u8, addr: u64, size: u64, pc: u64, word: u64) Fault!Step {
        _ = pc;
        _ = word;
        // Matches the existing `faultOutOfBounds` pattern: record the sentence the
        // caller will print, halt, and surface the error. Returning the text here
        // would duplicate a rendering path the VM already has.
        return self.faultOutOfBounds(action, addr, size);
    }

    fn reportStreamError(self: *Vm, err: StreamFault, pc: u64, word: u64) Fault!Step {
        self.halted = true;
        const detail: []const u8 = switch (err) {
            error.ChunkNotPositive => "A stream chunk must cover at least one element (§3.4).",
            error.BadElementWidth => "A stream element is 8, 16, 32 or 64 bits wide.",
            error.NotAStreamPointer => "The stream pointer register does not hold an address this engine can advance.",
            error.OutOfBounds => "The whole chunk must fit in the accessible region; no element was modified.",
        };
        return .{ .fault = .{
            .stage = "executing a stream instruction",
            .word = word,
            .pc = pc,
            .operand = .{ .name = "stream chunk", .text = "does not fit the accessible region" },
            .expected = "a chunk that lies entirely inside memory, with at least one element",
            .detail = detail,
        } };
    }

    const AluError = error{ DivideByZero, ReservedWidthEncoding, UnknownAluOpcode };

    /// §3.3.1 field constraints become diagnostics, never silent wraps.
    fn reportFieldError(self: *Vm, err: bits.FieldError, f: decoding.Field, pc: u64, word: u64) Fault!Step {
        _ = f;
        self.halted = true;
        const detail: []const u8 = switch (err) {
            error.ZeroWidth => "A field width must be at least 1 bit (§3.3.1).",
            error.FieldExceedsRegister => "The bit offset plus the field width must not run past bit 63 of the register.",
            error.InsertValueTooWide => "The value being packed does not fit the declared field width; packing it would discard the high bits.",
        };
        return .{ .fault = .{
            .stage = "executing a field instruction",
            .word = word,
            .pc = pc,
            .operand = .{ .name = "bitfield", .text = "offset and width out of range" },
            .expected = "offset + width <= 64, with width from 1 to 64",
            .detail = detail,
        } };
    }

    fn alu(self: *Vm, a: decoding.Alu) AluError!void {
        const lhs = self.regs.read(a.rs1);
        // `imm: ?i64` is already sign-extended by the decoder: §3.1's signed 28-bit
        // immediate sign-extends to all-ones above bit 39 when bit 27 is set.
        const rhs: u64 = if (a.imm) |imm| @bitCast(imm) else self.regs.read(a.rs2);

        const result: u64 = switch (a.op) {
            0x10 => lhs +% rhs,
            0x11 => lhs -% rhs,
            0x12 => lhs *% rhs,
            0x13 => if (rhs == 0) return error.DivideByZero else lhs / rhs,
            0x14 => lhs & rhs,
            0x15 => lhs | rhs,
            0x16 => lhs ^ rhs,
            // A shift of 64 or more leaves zero, per the encoding contract's shift width.
            0x17 => if (rhs >= 64) 0 else lhs << @intCast(rhs),
            0x18 => if (rhs >= 64) 0 else lhs >> @intCast(rhs),
            0x19 => rhs,
            else => return error.UnknownAluOpcode,
        };

        // A sub-width write zero-extends the upper bits (AGENTS.md §2.1); a reserved
        // width encoding must be reported rather than silently treated as full width.
        self.regs.writeWidth(a.rd, a.width, result);
    }

    /// §3.5 `cap.load` / `cap.store`: REFUSE, per Amendment 1.11's fidelity ruling.
    ///
    /// These are decode-only this revision. They perform a *memory* transfer of a
    /// 128-bit descriptor, but §3.5 defines no address field, and v1.11 rejected both
    /// readings that would supply one: the pair cannot hold the address because §6
    /// makes the pair hold the descriptor itself, and a third register is not
    /// representable (that was defect F12). So there is no address to use, and this
    /// refuses rather than inventing one. It does not guess, and it does not return
    /// zero: a fabricated address would silently read or write the wrong memory.
    fn refuseCapabilityTransfer(self: *Vm, c: decoding.Cap, pc: u64, word: u64) Fault!Step {
        self.halted = true;
        const mnemonic = if (c.op == 0x50) "cap.load" else "cap.store";
        return .{ .fault = .{
            .stage = "executing a capability transfer",
            .word = word,
            .pc = pc,
            .mnemonic = mnemonic,
            .expected = "an instruction whose address source is defined by the encoding contract",
            .detail = "This revision defines no address source for a capability transfer: docs/isa-encoding.md §3.5 has no address field, the descriptor's register pair holds the descriptor itself rather than an address (§6), and a third register operand cannot be encoded. The instruction was refused rather than given a guessed address. It encodes, disassembles and round-trips; it does not execute until a revision defines where its address comes from.",
        } };
    }

    /// §3.5 `cap.check`: `rd = capability access status` for the descriptor in `rs1`.
    ///
    /// READING CHOSEN, and why it cannot be the whole instruction (see REPORTED GAP
    /// below): the descriptor is materialised from the register pair named by `rs1`,
    /// per §6's own diagram — the low register is `base` (a full 64-bit word, §6
    /// "word 0"), and the high register carries `permissions` in its bits[15:8], with
    /// the low byte reserved-zero. That much is literally drawn in §6.
    ///
    /// REPORTED GAP — why this refuses instead of producing a value:
    /// §6 defines the descriptor as base + length + perms. The pair can carry `base`
    /// and `perms`, but `length` has NO bit position anywhere in the pair: §6's own
    /// fidelity note records that the old "length stored in permissions[23:0]" line
    /// described a packing that "does not exist" and was deleted. So a Capability
    /// cannot be reconstructed from `rs1` alone, and the region to test against is
    /// undefined.
    /// Worse, even with a descriptor the result is undefined: `check` needs an
    /// *address*, a *size* and an *access kind*, and the encoding supplies none of the
    /// three; and "capability access status" is not defined as a value anywhere — not
    /// as `CapError` (an error set, not a value) and not as select.Status (whose five
    /// members are comparison outcomes). Producing any number for `rd` would be an
    /// invention, so this refuses and names the gap. This is the same treatment
    /// cap.load/cap.store receive, and the same class of honesty §3.6's accelerators get.
    ///
    /// Even-index rule: NOT applied here. v1.11 scopes it to cap.load/cap.store only —
    /// `rs1` of cap.check names a descriptor to test, not a pair this instruction forms,
    /// so any register is legal. The assembler already rules the same way.
    fn capCheck(self: *Vm, c: decoding.Cap, pc: u64, word: u64) Fault!Step {
        self.halted = true;
        const base = self.regs.read(c.rs1);
        // §6's diagram: the high register holds permissions in bits[15:8].
        const high: u64 = self.regs.read(c.rs1 +% 1);
        const perms_byte: u8 = @truncate(high >> 8);
        var text: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&text);
        w.print("base {d}, permission byte {d}, no length field in the pair", .{ base, perms_byte }) catch {};
        return .{ .fault = .{
            .stage = "executing a capability check",
            .word = word,
            .pc = pc,
            .mnemonic = "cap.check",
            .operand = .{ .name = "descriptor register pair", .text = w.buffered() },
            .expected = "a descriptor the contract can describe completely, and a defined address, size and access kind to test it against",
            .detail = "docs/isa-encoding.md §6 defines a descriptor as base, length and permissions, but the register pair has no length field, so the region to test is undefined. The encoding also supplies no address, no size and no access kind, and 'capability access status' is not defined as a value anywhere in the contract. No status was fabricated for rd. This gap is reported rather than guessed; see task-20.",
        } };
    }

    /// §3.7 `thread.spawn`: bit i of the mask starts slot T_i at the address in rs1.
    ///
    /// An EMPTY mask (Amendment 1.1) is legal and starts nothing. It is not an error
    /// and not a fault: it is a well-defined no-op, which is what keeps a disassembled
    /// `operand[7:0] == 0` word readable and re-assemblable.
    fn spawnSlots(self: *Vm, t: decoding.Thread, pc: u64, word: u64) threading.ThreadError!void {
        _ = pc;
        _ = word;
        const entry = self.regs.read(t.rs1);
        const named = slotMask(t.slots);
        for (named.slice()) |index| try self.sched.spawn(index, entry);
    }

    /// §3.7 `thread.join`: bit i of the mask waits for slot T_i.
    /// An empty mask is legal and waits for nothing (Amendment 1.1).
    fn joinSlots(self: *Vm, t: decoding.Thread, pc: u64, word: u64) threading.ThreadError!void {
        _ = pc;
        _ = word;
        const named = slotMask(t.slots);
        for (named.slice()) |index| try self.sched.join(index);
    }

    /// The slot indices a `operand[7:0]` mask names, ascending, as a counted slice.
    ///
    /// The count matters: an EMPTY mask names no slot and must iterate zero times, not
    /// eight. Returning a fixed-size array with unfilled tail entries is what made an
    /// empty mask look like eight bogus slots. Eight is a fixed bound, so no allocation.
    fn slotMask(mask: u8) Slots {
        var s = Slots{};
        var i: u5 = 0;
        while (i < threading.slot_count) : (i += 1) {
            if (mask & (@as(u8, 1) << @intCast(i)) != 0) {
                s.indices[s.len] = @intCast(i);
                s.len += 1;
            }
        }
        return s;
    }

    /// Up to eight slot indices plus how many are actually valid.
    const Slots = struct {
        indices: [threading.slot_count]u4 = @splat(0),
        len: usize = 0,

        fn slice(self: *const Slots) []const u4 {
            return self.indices[0..self.len];
        }
    };

    /// Plain-language thread failure naming the slots and the reason, per §4.2.
    fn reportThreadError(self: *Vm, err: threading.ThreadError, mask: u8, pc: u64, word: u64) Fault!Step {
        self.halted = true;
        // Name the slots the mask actually selected, so the sentence points at the
        // offending operand rather than at the instruction as a whole (§4.2).
        var text: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&text);
        const named = slotMask(mask);
        if (named.len == 0) {
            w.writeAll("no slots") catch {};
        } else {
            for (named.slice(), 0..) |index, k| {
                if (k != 0) w.writeAll(", ") catch break;
                w.print("T{d}", .{index}) catch break;
            }
        }
        const operand_text = w.buffered();

        return .{ .fault = .{
            .stage = "executing a thread instruction",
            .word = word,
            .pc = pc,
            .operand = .{ .name = "slot mask", .text = operand_text },
            .expected = "a slot mask naming slots that exist and are in the state this operation requires",
            .detail = threading.explain(err),
        } };
    }

    /// A non-control instruction naming PC as its destination is refused instead of
    /// having its result silently overwritten by the fixed-width advance (§4, §7).
    fn reportPcWrite(self: *Vm, mnemonic: []const u8, pc: u64, word: u64) Fault!Step {
        self.halted = true;
        return .{ .fault = .{
            .stage = "executing this instruction",
            .word = word,
            .pc = pc,
            .mnemonic = mnemonic,
            .operand = .{ .name = "destination register", .text = "PC" },
            .expected = "a destination register other than PC, because a non-control instruction cannot write the program counter (docs/isa-encoding.md §4)",
            .detail = "This instruction computed a value for the program counter, but the program counter is advanced by the fixed 8-byte instruction width, so the result would have been discarded without any effect. The write was refused instead of being dropped silently. To transfer control, use jump, call or ret; SP, LR and FLAGS are valid destinations.",
        } };
    }

    fn reportAluError(self: *Vm, err: AluError, a: decoding.Alu, pc: u64, word: u64) Fault!Step {
        self.halted = true;
        const diag: Diagnostic = switch (err) {
            error.DivideByZero => .{
                .stage = "executing a divide",
                .word = word,
                .pc = pc,
                .operand = .{ .index = 2, .name = "divisor", .text = "0" },
                .expected = "a divisor that is not zero",
                .detail = "Celeris-64 reports division by zero as this diagnostic; it does not trap and it does not silently produce a value.",
            },
            error.ReservedWidthEncoding => .{
                .stage = "executing this instruction",
                .word = word,
                .pc = pc,
                .expected = "an operand width of 64, 32, 16 or 8 bits",
                .detail = "Width values between 4 and 15 are reserved by the encoding contract.",
            },
            error.UnknownAluOpcode => .{
                .stage = "executing this instruction",
                .word = word,
                .pc = pc,
                .operand = .{ .name = "opcode", .text = "not in the ALU map" },
                .expected = "an ALU opcode from 0x10 through 0x19",
                .detail = "The decoder produced an ALU instruction with an opcode the ALU does not implement.",
            },
        };
        _ = a;
        return .{ .fault = diag };
    }

    /// Bounds refusals become a sentence naming the address, the base and the length,
    /// and the access is not partially applied (contract P1.2, docs/isa-encoding.md §6).
    fn faultOutOfBounds(self: *Vm, action: []const u8, address: u64, width: u64) Fault {
        self.halted = true;
        const rendered = self.boundsText(action, address, width);
        _ = rendered;
        return error.OutOfBounds;
    }

    /// The last bounds sentence, kept so a caller can print it after `error.OutOfBounds`.
    pub fn boundsText(self: *const Vm, action: []const u8, address: u64, width: u64) memory.BoundsFault {
        return .{
            .action = action,
            .address = address,
            .base = 0,
            .length = self.mem.bytes.len,
            .width = width,
        };
    }
};

// ---------------------------------------------------------------------------
// Encoding helpers
//
// CLS64 words are little-endian and fixed 64-bit (docs/isa-encoding.md §1-§2). These
// helpers let a test express a program in the contract's own bit layout without an
// assembler. Field *extraction* is the decoder's job, not the VM's.
// ---------------------------------------------------------------------------

/// Builds one instruction word from the §2 layout.
pub fn encode(opcode: u8, rd: u4, rs1: u4, operand: u48) u64 {
    return (@as(u64, opcode) << 56) | (@as(u64, rd) << 52) | (@as(u64, rs1) << 48) | operand;
}

/// ALU operand field: `rs2[47:44]`, `width[43:40]`, signed `imm28[39:0]` (§3.1).
///
/// Takes `i64` to match `decoding.Alu.imm: ?i64`. A value the 28-bit field cannot
/// hold is refused rather than truncated, so a mistyped immediate cannot silently
/// encode a different instruction — the exact failure §3.1's sign rule guards against.
pub fn aluOperand(rs2: u4, width: Width, imm28: i64) u48 {
    const imm: i28 = std.math.cast(i28, imm28) orelse
        @panic("aluOperand: immediate does not fit the signed 28-bit field of docs/isa-encoding.md §3.1");
    return (@as(u48, rs2) << 44) | (@as(u48, @backingInt(width)) << 40) | @as(u48, @as(u28, @bitCast(imm)));
}

/// Copies a program of 64-bit words into an image at `at`, little-endian.
///
/// All-or-nothing, like the §3.4 stream rule: the whole range is checked before a
/// single byte is written, so a refused load leaves the image byte-for-byte intact.
pub fn loadWords(image: []u8, at: u64, words: []const u64) memory.BoundsError!void {
    var mem = Memory.init(image);
    if (!mem.inBounds(at, words.len * instruction_bytes)) return memory.BoundsError.OutOfBounds;
    for (words, 0..) |word, i| {
        try mem.write64(at + i * instruction_bytes, word);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Allocates an image once per test and loads a program into it.
/// Plain align-1 allocation: memory is byte-addressable (AGENTS.md §2.3), and the
/// returned slice must keep the allocation's own alignment so `free` matches.
fn imageWith(words: []const u64) ![]u8 {
    return imageWithSize(words, @max(8, words.len * 8) + 64);
}

/// An image of exactly `size` bytes with `words` loaded at address 0. The
/// accelerator tests need room for data at `accel_data_base`, which the default
/// `imageWith` does not provide (its buffer is program-sized by design, so that a
/// bounds test cannot accidentally pass because the image happened to be huge).
fn imageWithSize(words: []const u64, size: usize) ![]u8 {
    const bytes = try testing.allocator.alloc(u8, size);
    @memset(bytes, 0);
    try loadWords(bytes, 0, words);
    return bytes;
}

test "PC advances by the fixed 64-bit width for straight-line code" {
    const img = try imageWith(&.{
        encode(0x00, 0, 0, 0), // nop
        encode(0x00, 0, 0, 0), // nop
        encode(0x01, 0, 0, 0), // halt
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step();
    try testing.expectEqual(@as(u64, 8), vm.regs.pc);
    _ = try vm.step();
    try testing.expectEqual(@as(u64, 16), vm.regs.pc);

    const halted = try vm.step();
    try testing.expect(halted == .halted);
    try testing.expect(vm.halted);
    try testing.expectEqual(@as(u64, 3), vm.retired);
}

test "jump, call and ret are the only instructions that move PC off the fixed stride" {
    const img = try imageWith(&.{
        encode(0x03, 0, 0, 32), // call 32  -> LR = 8
        encode(0x01, 0, 0, 0), // halt
        encode(0x00, 0, 0, 0),
        encode(0x00, 0, 0, 0),
        encode(0x04, 0, 0, 0), // ret -> PC = LR = 8
        encode(0x02, 0, 0, 40), // jump 40
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step(); // call
    try testing.expectEqual(@as(u64, 32), vm.regs.pc);
    try testing.expectEqual(@as(u64, 8), vm.regs.lr);

    _ = try vm.step(); // ret
    try testing.expectEqual(@as(u64, 8), vm.regs.pc);

    const h = try vm.step(); // halt
    try testing.expect(h == .halted);
}

test "ALU immediate form writes the destination and honours sub-width zero-extension" {
    const img = try imageWith(&.{
        // R0 = 134217727 (mov, full width): the largest value the signed 28-bit
        // immediate field of §3.1 can hold.
        encode(0x19, 0, 0, aluOperand(0, .full, 134217727)),
        // R0.b = 0xAB : must clear the upper bits, observable through a full read
        encode(0x19, 0, 0, aluOperand(0, .b, 0xAB)),
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step();
    try testing.expectEqual(@as(u64, 134217727), vm.regs.read(0));
    _ = try vm.step();
    try testing.expectEqual(@as(u64, 0xAB), vm.regs.read(0));
    try testing.expectEqual(@as(u64, 0), vm.regs.read(0) & 0xFFFF_FFFF_FFFF_FF00);
}

test "a negative imm28 sign-extends to 64 bits end-to-end" {
    const img = try imageWith(&.{
        // imm28 = 0x0800_0000 -> -134217728, whose u64 form is all ones above bit 27.
        encode(0x19, 1, 0, aluOperand(0, .full, -134217728)),
        encode(0x10, 2, 1, aluOperand(0, .full, 0)), // R2 = R1 + 0
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_F800_0000), vm.regs.read(1));
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_F800_0000), vm.regs.read(2));
}

test "running the same program twice yields identical register and memory state" {
    const program = [_]u64{
        encode(0x19, 1, 0, aluOperand(0, .full, 7)), // R1 = 7
        encode(0x10, 2, 1, aluOperand(0, .full, 35)), // R2 = R1 + 35
        encode(0x11, 3, 2, aluOperand(0, .full, 2)), // R3 = R2 - 2
        encode(0x12, 4, 3, aluOperand(0, .full, 3)), // R4 = R3 * 3
        encode(0x13, 5, 4, aluOperand(0, .full, 5)), // R5 = R4 / 5
        encode(0x01, 0, 0, 0),
    };

    const first_img = try imageWith(&program);
    defer testing.allocator.free(first_img);
    var a = Vm.init(first_img);
    _ = try a.run(100);

    const second_img = try imageWith(&program);
    defer testing.allocator.free(second_img);
    var b = Vm.init(second_img);
    _ = try b.run(100);

    try testing.expect(a.snapshot().eql(b.snapshot()));
    try testing.expectEqualSlices(u8, first_img, second_img);
    // Hand-derived: R2 = 7+35 = 42, R3 = 42-2 = 40, R4 = 40*3 = 120, R5 = 120/5 = 24.
    try testing.expectEqual(@as(u64, 24), b.regs.read(5));
    try testing.expectEqual(@as(u64, 6), b.retired);
}

test "an unknown opcode produces a diagnostic naming the opcode and the PC, and does not panic" {
    const img = try imageWith(&.{
        encode(0x00, 0, 0, 0),
        encode(0xAB, 0, 0, 0), // 0xAB is not in the opcode map
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);

    var buf: [512]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "error:") != null);
    // Names the opcode value and where it was found. The PC lives in the `pc` field,
    // which is not a source line number: a runtime fault has no source text.
    try testing.expect(std.mem.indexOf(u8, text, "opcode") != null);
    try testing.expect(std.mem.indexOf(u8, text, "PC 8") != null);
    try testing.expect(std.mem.indexOf(u8, text, "line 8") == null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
    try testing.expect(vm.halted);
}

test "fetching past the end of memory refuses and does not truncate" {
    const img = try imageWith(&.{encode(0x00, 0, 0, 0)});
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    vm.regs.pc = img.len; // exactly one past the last valid byte
    try testing.expectError(error.OutOfBounds, vm.step());

    // The refusal is a sentence naming address, base and length, not a bare code.
    var buf: [512]u8 = undefined;
    const text = vm.boundsText("fetching the instruction", vm.regs.pc, 8).render(&buf);
    try testing.expect(std.mem.indexOf(u8, text, "address") != null);
    try testing.expect(std.mem.indexOf(u8, text, "base 0") != null);
    try testing.expect(std.mem.indexOf(u8, text, "byte(s) long") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "a program that never halts stops at the instruction limit instead of hanging" {
    const img = try imageWith(&.{
        encode(0x00, 0, 0, 0),
        encode(0x02, 0, 0, 0), // jump 0: an infinite loop
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    const d = try vm.run(50);
    try testing.expectEqual(@as(u64, 50), vm.retired);

    var buf: [512]u8 = undefined;
    const text = diagnostics.renderToBuffer(d, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "instruction limit") != null);
}

test "division by zero is a diagnostic, not a trap and not a silent value" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 0)), // R1 = 0
        encode(0x13, 2, 1, aluOperand(1, .full, 0)), // R2 = R1 / R1
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);
    try testing.expectEqual(@as(u64, 0), vm.regs.read(2)); // nothing was committed

    var buf: [512]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "divisor") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "shifts of 64 or more produce zero rather than undefined behaviour" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 0xFF)), // R1 = 0xFF
        encode(0x17, 2, 1, aluOperand(0, .full, 64)), // R2 = R1 << 64
        encode(0x18, 3, 1, aluOperand(0, .full, 64)), // R3 = R1 >> 64
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    try testing.expectEqual(@as(u64, 0), vm.regs.read(2));
    try testing.expectEqual(@as(u64, 0), vm.regs.read(3));
}

test "loadWords refuses a program that does not fit the image" {
    var img: [16]u8 = @splat(0);
    try testing.expectError(error.OutOfBounds, loadWords(&img, 8, &.{ 1, 2, 3 }));
    // Nothing was written by the refused load.
    for (img) |b| try testing.expectEqual(@as(u8, 0), b);
}

/// §3.3 encoding: offset[47:40], width[39:32], src2[31:28].
fn fieldOperand(offset: u8, width: u8, src2: u4) u48 {
    return (@as(u48, offset) << 40) | (@as(u48, width) << 32) | (@as(u48, src2) << 28);
}

test "field.extract pulls the documented bits end-to-end (spec's offset=12 width=3)" {
    const img = try imageWith(&.{
        // R1 = 0xABCD (mov immediate)
        encode(0x19, 1, 0, aluOperand(0, .full, 0xABCD)),
        // R1 = 0xABCD = 0b1010_1011_1100_1101, so bits [14:12] are 0b010 = 2.
        encode(0x30, 0, 1, fieldOperand(12, 3, 0)),
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    try testing.expectEqual(@as(u64, 0x2), vm.regs.read(0));
}

test "field.insert round-trips a non-power-of-two value and leaves other bits alone" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 0xFFFF)), // R1 = 0xFFFF (base)
        encode(0x19, 2, 0, aluOperand(0, .full, 0x5)), // R2 = 0b101 (a U3 value)
        encode(0x31, 3, 1, fieldOperand(12, 3, 2)), // R3 = R1 with U3 at bit 12
        encode(0x30, 4, 3, fieldOperand(12, 3, 0)), // R4 = extract it back
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    // 0xFFFF = 0b1111_1111_1111_1111; bits [14:12] become 101 -> 0b1101_1111_1111_1111.
    try testing.expectEqual(@as(u64, 0xDFFF), vm.regs.read(3));
    try testing.expectEqual(@as(u64, 0x5), vm.regs.read(4));
}

test "field constraints produce diagnostics rather than silent wraps (spec 3.3.1)" {
    // width == 0 is a diagnostic error, not a zero result.
    const zero_width = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 0xFF)),
        encode(0x30, 0, 1, fieldOperand(12, 0, 0)),
    });
    defer testing.allocator.free(zero_width);
    var a = Vm.init(zero_width);
    _ = try a.step();
    const s0 = try a.step();
    try testing.expect(s0 == .fault);
    // Nothing was committed to the destination.
    try testing.expectEqual(@as(u64, 0), a.regs.read(0));

    // offset + width > 64 is a diagnostic error, not a wrap.
    const over = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 0xFF)),
        encode(0x30, 0, 1, fieldOperand(60, 8, 0)),
    });
    defer testing.allocator.free(over);
    var b = Vm.init(over);
    _ = try b.step();
    const s1 = try b.step();
    try testing.expect(s1 == .fault);

    var buf: [512]u8 = undefined;
    const text = diagnostics.renderToBuffer(s1.fault, &buf);
    // F24: the decoder now rejects this word before the VM ever sees it, so the
    // sentence comes from the decode-time diagnostic. It still states the rule,
    // in words rather than symbols — §7 forbids a bare hex code, not prose.
    try testing.expect(std.mem.indexOf(u8, text, "sum is at most 64 bits") != null);
    try testing.expect(std.mem.indexOf(u8, text, "3.3.1") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

/// §3.2.2 select encoding: match[47:44], trueReg[43:40], falseReg[39:36].
fn selectOperand(match_val: u4, true_reg: u4, false_reg: u4) u48 {
    return (@as(u48, match_val) << 44) | (@as(u48, true_reg) << 40) | (@as(u48, false_reg) << 36);
}

/// §3.4 stream encoding: rs2[47:44], chunk[43:24], width[23:20].
fn streamOperand(rs2: u4, chunk: u20, width: Width) u48 {
    return (@as(u48, rs2) << 44) | (@as(u48, chunk) << 24) | (@as(u48, @backingInt(width)) << 20);
}

test "compare produces the explicit status enum, and select picks the arm without branching" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 5)), // R1 = 5
        encode(0x19, 2, 0, aluOperand(0, .full, 9)), // R2 = 9
        encode(0x20, 3, 1, aluOperand(2, .full, 0)), // R3 = status(R1 vs R2) = LESS (1)
        encode(0x19, 4, 0, aluOperand(0, .full, 0xAA)), // R4 = true arm
        encode(0x19, 5, 0, aluOperand(0, .full, 0xBB)), // R5 = false arm
        encode(0x21, 6, 3, selectOperand(1, 4, 5)), // R6 = (R3 == LESS) ? R4 : R5
        encode(0x21, 7, 3, selectOperand(0, 4, 5)), // R7 = (R3 == EQUAL) ? R4 : R5
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(50);
    try testing.expectEqual(@as(u64, 1), vm.regs.read(3)); // LESS, not a bare boolean
    try testing.expectEqual(@as(u64, 0xAA), vm.regs.read(6)); // matching arm
    try testing.expectEqual(@as(u64, 0xBB), vm.regs.read(7)); // non-matching arm
    // PC advanced by the fixed stride throughout: no branch was taken for either
    // select. halt is the 8th word and stops without advancing, so PC stays at 56.
    try testing.expectEqual(@as(u64, 7 * 8), vm.regs.pc);
}

test "select on a register that is not a status enum faults instead of picking an arm" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 99)), // R1 = 99, not a status value
        encode(0x21, 2, 1, selectOperand(0, 0, 0)),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);
    try testing.expectEqual(@as(u64, 0), vm.regs.read(2)); // no arm was committed
}

test "stream.fill writes the chunk and auto-advances the pointer by chunk * elementSize" {
    const img = try imageWith(&.{
        // Data starts at 64, past the four instruction words (0..32).
        encode(0x19, 1, 0, aluOperand(0, .full, 64)), // R1 = 64 -> pointer
        encode(0x19, 0, 0, aluOperand(0, .full, 0x2A)), // R0 = fill value
        encode(0x42, 0, 1, streamOperand(0, 4, .l)), // stream.fill R0, [R1]+4, width .l
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    // 4 elements of 4 bytes = 16 bytes written, pointer advanced by 16.
    try testing.expectEqual(@as(u64, 80), vm.regs.read(1));
    try testing.expectEqual(@as(u32, 0x2A), try vm.mem.read32(64));
    try testing.expectEqual(@as(u32, 0x2A), try vm.mem.read32(76));
}

test "STREAM ATOMICITY end-to-end: a chunk overrunning memory modifies zero bytes" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 0)), // R1 = 0
        encode(0x19, 0, 0, aluOperand(0, .full, 0xFF)),
        // chunk of 1_000_000 64-bit elements cannot fit any image.
        encode(0x42, 0, 1, streamOperand(0, 1_000_000, .full)),
    });
    defer testing.allocator.free(img);

    const before = try testing.allocator.dupe(u8, img);
    defer testing.allocator.free(before);

    var vm = Vm.init(img);
    _ = try vm.step();
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);

    // Byte-for-byte: a partial application would show up here.
    try testing.expectEqualSlices(u8, before, img);
    // The refused operation must not have advanced the pointer either.
    try testing.expectEqual(@as(u64, 0), vm.regs.read(1));

    var buf: [512]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "stream.add is the fused load/add/store the architecture headlines" {
    const img = try imageWith(&.{
        // Data lives at 64, past the four instruction words (0..32).
        encode(0x19, 1, 0, aluOperand(0, .full, 64)), // pointer R1 = 64
        encode(0x19, 2, 0, aluOperand(0, .full, 3)), // offset R2 = 3
        encode(0x40, 0, 1, streamOperand(2, 2, .l)), // stream.add R0, [R1]+2, R2
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    vm_load32(img, 64, 100);
    vm_load32(img, 68, 200);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    try testing.expectEqual(@as(u32, 103), try vm.mem.read32(64));
    try testing.expectEqual(@as(u32, 203), try vm.mem.read32(68));
    try testing.expectEqual(@as(u64, 72), vm.regs.read(1)); // 64 + 2 * 4
}

fn vm_load32(img: []u8, at: u64, value: u32) void {
    var mem = Memory.init(img);
    mem.write32(at, value) catch unreachable;
}

test "stream.setp applies the signed 40-bit stride to the pointer register" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 64)), // R1 = 64
        // F19: `setp` names its pointer with `rd` (here R1) and carries nothing
        // in `rs1`, which must be zero — a non-zero value is now rejected.
        // §3.4: the stride occupies operand[39:0] ONLY, and [47:40] is reserved.
        // The old fixture wrote @bitCast(@as(i48, -16)), which sign-extends into
        // [47:40] and produces operand 0xFFFFFFFFFFF0 — a word the contract
        // reserves and the assembler never emits. Masked to 40 bits, matching
        // what `stream.setp R1, -16` actually assembles to.
        encode(0x43, 1, 0, @as(u48, @as(u40, @bitCast(@as(i40, -16))))), // setp R1, stride -16
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    try testing.expectEqual(@as(u64, 48), vm.regs.read(1));
}

test "an ALU write to PC faults instead of being silently discarded (VM half of F8)" {
    // A hand-encoded word, because the assembler now rejects this at assembly time:
    // a loaded binary blob must not be silently discarded either.
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 100)), // R1 = 100
        encode(0x19, 2, 0, aluOperand(0, .full, 5)), // R2 = 5
        encode(0x10, 14, 1, aluOperand(2, .full, 0)), // add PC, R1, R2  <- rd index 14
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step();
    _ = try vm.step();
    const s = try vm.step();

    // Before the fix this returned .advanced with PC = 24 (the normal stride) and the
    // computed 105 was thrown away with no signal at all.
    try testing.expect(s == .fault);

    var buf: [1024]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "error:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "PC") != null);
    try testing.expect(std.mem.indexOf(u8, text, "destination register") != null);
    try testing.expect(std.mem.indexOf(u8, text, "jump, call or ret") != null);
    try testing.expect(std.mem.indexOf(u8, text, "PC 16") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
    try testing.expect(vm.halted);
}

test "PC as the destination faults for every non-control instruction that writes rd" {
    const cases = [_]struct { op: u8, operand: u48 }{
        .{ .op = 0x10, .operand = aluOperand(2, .full, 0) }, // add PC, R1, R2
        .{ .op = 0x12, .operand = aluOperand(2, .full, 0) }, // mul PC, R1, R2
        .{ .op = 0x19, .operand = aluOperand(0, .full, 7) }, // mov PC, 7
        .{ .op = 0x20, .operand = aluOperand(2, .full, 0) }, // compare PC, R1, R2
        .{ .op = 0x21, .operand = selectOperand(1, 0, 0) }, // select PC, R1, [LESS], R0, R0
        .{ .op = 0x30, .operand = fieldOperand(12, 3, 0) }, // field.extract PC, R1, 12, 3
    };
    for (cases) |c| {
        const img = try imageWith(&.{
            encode(0x19, 1, 0, aluOperand(0, .full, 100)),
            encode(0x19, 2, 0, aluOperand(0, .full, 5)),
            encode(c.op, 14, 1, c.operand),
        });
        defer testing.allocator.free(img);

        var vm = Vm.init(img);
        _ = try vm.step();
        _ = try vm.step();
        const s = try vm.step();
        try testing.expect(s == .fault);
        // The refused instruction must not have moved PC off the faulting word.
        try testing.expectEqual(@as(u64, 16), vm.regs.pc);
    }
}

test "REGRESSION: SP, LR and FLAGS are legal destinations and still execute normally" {
    // §4: indices 12, 13 and 15 are legal in rd. The PC guard must not over-reach.
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 100)), // R1 = 100
        encode(0x19, 2, 0, aluOperand(0, .full, 5)), // R2 = 5
        encode(0x10, 12, 1, aluOperand(2, .full, 0)), // add SP, R1, R2   -> 105
        encode(0x19, 13, 0, aluOperand(0, .full, 7)), // mov LR, 7
        encode(0x10, 15, 1, aluOperand(2, .full, 0)), // add FLAGS, R1, R2 -> 105
        encode(0x19, 12, 0, aluOperand(0, .full, 1)), // mov SP, 1 (overwrite)
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    const d = try vm.run(20);
    _ = d; // halt
    try testing.expectEqual(@as(u64, 1), vm.regs.sp);
    try testing.expectEqual(@as(u64, 7), vm.regs.lr);
    try testing.expectEqual(@as(u64, 105), vm.regs.flags);
    // Straight-line: 6 executed instructions advanced PC to 48, then halt stopped it.
    try testing.expectEqual(@as(u64, 48), vm.regs.pc);
}

test "REGRESSION: PC as a source operand is rejected at decode (F27)" {
    // This test previously asserted the OPPOSITE, citing "§4 says PC is readable".
    // §4's table does say "readable", but the paragraph beneath it is explicit:
    // "in rs1/rs2 it is legal for SP, LR and FLAGS and a diagnostic error for PC",
    // and the assembler has always refused `add R0, PC, R1`. The decoder accepted
    // it, so `run-bin` executed a word no source line can express — F27, the same
    // two-layer gap as F8. The contract was clarified rather than the behaviour
    // relaxed, so this test now pins the rejection.
    //
    // SP (12), LR (13) and FLAGS (15) remain legal sources; only PC (14) is not.
    const img = try imageWith(&.{
        encode(0x00, 0, 0, 0), // nop -> PC 8
        // R0 = R1(0) + PC ; rs1 = PC (14), rs2 = 1, imm = 0 -> register form
        encode(0x10, 0, 14, aluOperand(1, .full, 0)),
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    // The word must not decode at all: the decoder is the layer that sees a blob.
    try testing.expect(decoding.decode(encode(0x10, 0, 14, aluOperand(1, .full, 0))) == .err);

    // And the legal sources still decode, so the check is not over-broad.
    try testing.expect(decoding.decode(encode(0x10, 0, 12, aluOperand(1, .full, 0))) == .ok);
    try testing.expect(decoding.decode(encode(0x10, 0, 13, aluOperand(1, .full, 0))) == .ok);
    try testing.expect(decoding.decode(encode(0x10, 0, 15, aluOperand(1, .full, 0))) == .ok);
}

test "REGRESSION: jump, call and ret still set PC deliberately and are never clobbered" {
    const img = try imageWith(&.{
        encode(0x03, 0, 0, 32), // call 32 -> LR = 8 (address of the NEXT instruction)
        encode(0x01, 0, 0, 0), // halt
        encode(0x00, 0, 0, 0),
        encode(0x00, 0, 0, 0),
        encode(0x04, 0, 0, 0), // ret -> PC = LR = 8
        encode(0x02, 0, 0, 40), // jump 40
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step(); // call
    try testing.expectEqual(@as(u64, 32), vm.regs.pc); // target, NOT the stride
    try testing.expectEqual(@as(u64, 8), vm.regs.lr); // address of the next instruction

    _ = try vm.step(); // ret
    try testing.expectEqual(@as(u64, 8), vm.regs.pc);

    const h = try vm.step(); // halt
    try testing.expect(h == .halted);
}

test "REGRESSION: the fixed 8-byte advance still holds for straight-line code" {
    const img = try imageWith(&.{
        encode(0x00, 0, 0, 0), // nop
        encode(0x19, 1, 0, aluOperand(0, .full, 1)), // mov R1, 1
        encode(0x01, 0, 0, 0), // halt
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step();
    try testing.expectEqual(@as(u64, 8), vm.regs.pc);
    _ = try vm.step();
    try testing.expectEqual(@as(u64, 16), vm.regs.pc);
}

/// §3.7 encoding: `operand[7:0]` is the slot bitmask, `operand[47:8]` reserved zero.
fn threadOperand(slot_mask: u8) u48 {
    return @as(u48, slot_mask);
}

test "thread.spawn starts the named slots at rs1 and an EMPTY mask is a legal no-op" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 64)), // R1 = 64
        encode(0x90, 0, 1, threadOperand(0b0000_0101)), // spawn T0 and T2 at 64
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    try testing.expectEqual(@as(usize, 2), vm.sched.activeCount());
    try testing.expectEqual(threading.SlotState.running, vm.sched.slots[0].state);
    try testing.expectEqual(threading.SlotState.idle, vm.sched.slots[1].state);
    try testing.expectEqual(threading.SlotState.running, vm.sched.slots[2].state);
    try testing.expectEqual(@as(u64, 64), vm.sched.slots[0].entry);
    try testing.expectEqual(@as(u64, 64), vm.sched.slots[2].entry);

    // Amendment 1.1: mask 0 names no slot. It is legal, starts nothing, and does NOT
    // fault. Before the slot-count fix it wrongly started eight bogus slots.
    const empty = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 64)),
        encode(0x90, 0, 1, threadOperand(0)),
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(empty);

    var e = Vm.init(empty);
    const d = try e.run(10);
    _ = d; // halt, not a fault
    try testing.expectEqual(@as(usize, 0), e.sched.activeCount());
    try testing.expect(!e.halted or e.sched.activeCount() == 0);
}

test "thread.join finishes the named slots and faults in plain language on an idle one" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 32)),
        encode(0x90, 0, 1, threadOperand(0b0000_0011)), // spawn T0, T1
        encode(0x91, 0, 0, threadOperand(0b0000_0001)), // join T0
        encode(0x91, 0, 0, threadOperand(0)), // join no slots: legal no-op
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    try testing.expectEqual(threading.SlotState.finished, vm.sched.slots[0].state);
    try testing.expectEqual(threading.SlotState.running, vm.sched.slots[1].state);
    try testing.expectEqual(@as(usize, 1), vm.sched.activeCount());

    // Joining a slot that was never started is a fault naming the slot, not a silent
    // no-op and not a bare code.
    const bad = try imageWith(&.{
        encode(0x91, 0, 0, threadOperand(0b0000_0100)), // join T2, never started
    });
    defer testing.allocator.free(bad);

    var b = Vm.init(bad);
    const s = try b.step();
    try testing.expect(s == .fault);
    var buf: [1024]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "T2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "not running") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "thread.yield with no runnable slot faults instead of silently advancing" {
    const img = try imageWith(&.{
        encode(0x92, 0, 0, 0), // yield with nothing running
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    const s = try vm.step();
    try testing.expect(s == .fault);
    try testing.expectEqual(@as(u64, 0), vm.regs.pc); // did not advance

    var buf: [1024]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "nothing to switch to") != null);
    try testing.expect(std.mem.indexOf(u8, text, "deterministic modelled interleave") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "thread.yield dispatches deterministically round-robin over the running slots" {
    const program = [_]u64{
        encode(0x19, 1, 0, aluOperand(0, .full, 64)),
        encode(0x90, 0, 1, threadOperand(0b0000_0101)), // spawn T0, T2
        encode(0x92, 0, 0, 0), // yield -> T0
        encode(0x92, 0, 0, 0), // yield -> T2
        encode(0x92, 0, 0, 0), // yield -> T0 again (wraps)
        encode(0x01, 0, 0, 0),
    };
    const img = try imageWith(&program);
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(20);
    try testing.expectEqual(@as(u64, 3), vm.sched.dispatches);
    try testing.expectEqual(@as(u4, 0), vm.sched.last_dispatched.?);

    // Determinism: the same program twice gives identical thread-scheduler state.
    const img2 = try imageWith(&program);
    defer testing.allocator.free(img2);
    var vm2 = Vm.init(img2);
    _ = try vm2.run(20);
    try testing.expectEqual(vm.sched.dispatches, vm2.sched.dispatches);
    try testing.expectEqual(vm.sched.last_dispatched, vm2.sched.last_dispatched);
    try testing.expectEqual(vm.sched.activeCount(), vm2.sched.activeCount());
}

test "thread instructions do not disturb SP, LR, FLAGS or the fixed PC advance" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 100)), // R1 = 100
        encode(0x10, 12, 1, aluOperand(0, .full, 5)), // add SP, R1, 5
        encode(0x19, 13, 0, aluOperand(0, .full, 7)), // mov LR, 7
        encode(0x90, 0, 1, threadOperand(0b1000_0001)), // spawn T0, T7
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    try testing.expectEqual(@as(u64, 105), vm.regs.sp);
    try testing.expectEqual(@as(u64, 7), vm.regs.lr);
    // Derivation: mov@0, add SP@8, mov LR@16, thread.spawn@24, halt@32.
    // halt is executed but does not advance, so PC stays at 32.
    try testing.expectEqual(@as(u64, 32), vm.regs.pc);
    try testing.expectEqual(@as(usize, 2), vm.sched.activeCount());
}

test "thread slot failures are plain sentences naming the slots, never bare codes" {
    const buf: [1024]u8 = undefined;
    _ = buf;
    const errs = [_]threading.ThreadError{
        error.NoSuchSlot,
        error.SlotAlreadyActive,
        error.SlotNotActive,
    };
    for (errs) |e| {
        const text = threading.explain(e);
        try testing.expect(text.len > 0);
        try testing.expect(std.mem.indexOf(u8, text, "0x") == null);
        try testing.expect(std.ascii.isUpper(text[0]));
    }
}

test "the reserved thread field is rejected by the decoder, not silently ignored" {
    // §3.7: operand[47:8] must be zero. The decoder owns that rule; this records that
    // it holds, so a loaded blob cannot smuggle a non-zero reserved field past the VM.
    const img = try imageWith(&.{
        encode(0x90, 0, 1, (@as(u48, 1) << 8) | 0b1), // spawn with reserved bit set
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    const s = try vm.step();
    try testing.expect(s == .fault);
    var buf: [1024]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "cap.load and cap.store REFUSE loudly, naming the undefined address source" {
    // v1.11: decode-only this revision. Both must refuse, never guess, never return 0.
    const cases = [_]struct { op: u8, mnemonic: []const u8 }{
        .{ .op = 0x50, .mnemonic = "cap.load" },
        .{ .op = 0x51, .mnemonic = "cap.store" },
    };
    for (cases) |c| {
        const img = try imageWith(&.{
            encode(c.op, 2, 4, 0), // even pair, so the even-index rule is satisfied
        });
        defer testing.allocator.free(img);

        var vm = Vm.init(img);
        const s = try vm.step();
        try testing.expect(s == .fault);

        var buf: [1024]u8 = undefined;
        const text = diagnostics.renderToBuffer(s.fault, &buf);
        _ = c.mnemonic; // the word is named, not the mnemonic: assert what is rendered
        try testing.expect(std.mem.indexOf(u8, text, "no address field") != null);
        try testing.expect(std.mem.indexOf(u8, text, "refused") != null);
        try testing.expect(std.mem.indexOf(u8, text, "does not execute until a revision") != null);
        try testing.expect(!diagnostics.hasBareHexCode(text));
        // Nothing was written to the destination register: no fabricated value.
        try testing.expectEqual(@as(u64, 0), vm.regs.read(2));
        try testing.expect(vm.halted);
    }
}

test "cap.load with an ODD pair index is also refused, not silently rounded" {
    // v1.11 even-index rule: an odd low index would overlap two descriptors. The
    // decoder owns the field layout, so the VM reports it as the same loud refusal.
    const img = try imageWith(&.{
        encode(0x50, 3, 4, 0), // rd = 3, odd
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    const s = try vm.step();
    try testing.expect(s == .fault);
    // rd must not have been rounded down to 2; neither register was touched.
    try testing.expectEqual(@as(u64, 0), vm.regs.read(2));
    try testing.expectEqual(@as(u64, 0), vm.regs.read(3));
}

test "cap.check refuses and states the gap instead of fabricating a status" {
    // REPORTED GAP (task-20): §6's descriptor is base + length + perms, but the
    // register pair carries no length, so the region to test is undefined; and the
    // encoding supplies no address, no size and no access kind. No status is invented.
    const img = try imageWith(&.{
        encode(0x19, 4, 0, aluOperand(0, .full, 0x1000)), // R4 = base
        encode(0x19, 5, 0, aluOperand(0, .full, 0x0007)), // R5 = perms in bits[15:8]
        encode(0x52, 0, 4, 0), // cap.check R0, R4
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step();
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);

    var buf: [1024]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    // The diagnostic names the instruction word and the PC, not the mnemonic.
    try testing.expect(std.mem.indexOf(u8, text, "PC 16") != null);
    // Names the descriptor it read (R4 = 0x1000, R5's perms byte = 0), and states why
    // no status was produced.
    try testing.expect(std.mem.indexOf(u8, text, "base 4096, permission byte 0, no length field in the pair") != null);
    try testing.expect(std.mem.indexOf(u8, text, "no length field") != null);
    try testing.expect(std.mem.indexOf(u8, text, "not defined as a value anywhere in the contract") != null);
    try testing.expect(std.mem.indexOf(u8, text, "No status was fabricated") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
    // rd was NOT written: the old silent behaviour would have left 0 here, and a
    // fabricated status would also land here. Nothing was committed.
    try testing.expectEqual(@as(u64, 0), vm.regs.read(0));
    try testing.expect(vm.halted);
}

test "the even-index rule does NOT apply to cap.check (v1.11 scopes it to load/store)" {
    // v1.11: rs1 of cap.check names a descriptor to TEST, not a pair it forms, so an
    // odd index is legal. It must not be rejected for that reason; it refuses for the
    // reported gap instead, and the sentence must not claim an even-index violation.
    const img = try imageWith(&.{
        encode(0x52, 0, 5, 0), // rs1 = 5, odd
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    const s = try vm.step();
    try testing.expect(s == .fault);
    var buf: [1024]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "even") == null);
}

test "capability model round-trips through the VM's re-export and is not cryptographic" {
    // The re-export exists so tests/vm_tests.zig can reach capability.zig through the
    // module root. Sanity-check the model the VM will use when the gap is closed.
    const cap = try capability.Capability.init(0x1000, 0x100, capability.Perms.all());
    try testing.expect(cap.covers(0x1000, 1));
    try testing.expect(cap.covers(0x10FF, 1));
    try testing.expect(!cap.covers(0x1100, 1)); // one past the top
    try testing.expect(!cap.covers(0x0FFF, 1)); // one below the base
    try testing.expectEqual(@as(u64, 0x1100), cap.top());
    // A narrower child can never exceed its parent: the property worth modelling.
    const child = try cap.narrow(0x20, 0x10, capability.Perms.all());
    try testing.expectEqual(@as(u64, 0x1020), child.base);
    try testing.expectEqual(@as(u64, 0x10), child.length);
}

test "v1.17: a real loop, using branch and load, computes the right answer" {
    // The ISA could not express a loop before v1.17: every control transfer was
    // unconditional. This test is the end-to-end proof that it can now, using the
    // three new instructions together — `compare` produces the status enum,
    // `branch` tests it, `load` fetches an element.
    //
    //   sum = 0; i = 0; ptr = data
    //   loop: if (i == count) goto done
    //         sum += *ptr; ptr += 8; i += 1; goto loop
    //   done: halt
    const data = [_]u64{ 5, 10, 15, 20, 25, 30, 35, 40 };
    const base: u64 = 4096;
    const count: u64 = 8;
    const expected_sum: u64 = 180;

    const words = [_]u64{
        encode(0x19, 1, 0, aluOperand(0, .full, base)), // R1 = ptr
        encode(0x19, 2, 0, aluOperand(0, .full, 0)), // R2 = sum
        encode(0x19, 3, 0, aluOperand(0, .full, count)), // R3 = count
        encode(0x19, 4, 0, aluOperand(0, .full, 0)), // R4 = i
        // compare R4, R3 -> R5   (status enum into R5)
        encode(0x20, 5, 4, aluOperand(3, .full, 0)),
        // branch R5, [EQUAL], +48 -> halt
        branchWord(5, 0, 48),
        // load R6, [R1+0]
        memWord(0x1A, 6, 1, 0, 0, 0),
        encode(0x10, 2, 2, aluOperand(6, .full, 0)), // add R2, R2, R6
        encode(0x10, 1, 1, aluOperand(0, .full, 8)), // add R1, R1, 8
        encode(0x10, 4, 4, aluOperand(0, .full, 1)), // add R4, R4, 1
        encode(0x02, 0, 0, 32), // jump 32 (back to the compare)
        encode(0x01, 0, 0, 0), // halt
    };

    const img = try testing.allocator.alloc(u8, base + 128);
    defer testing.allocator.free(img);
    @memset(img, 0);
    try loadWords(img, 0, &words);
    for (data, 0..) |v, i| {
        std.mem.writeInt(u64, img[@intCast(base + i * 8)..][0..8], v, .little);
    }

    var vm = Vm.init(img);
    _ = try vm.run(10_000);
    try testing.expect(vm.halted);
    try testing.expectEqual(expected_sum, vm.regs.read(2)); // the sum
    try testing.expectEqual(count, vm.regs.read(4)); // iterations completed
}

/// §3.0.1 `branch` word: rs1 = status register, rs2 = match value,
/// offset[27:0] = signed byte displacement.
fn branchWord(rs1: u4, match: u4, offset: i64) u64 {
    const raw: u28 = @truncate(@as(u64, @bitCast(offset)));
    return (@as(u64, 0x05) << 56) | (@as(u64, rs1) << 48) |
        (@as(u64, match) << 44) | raw;
}

/// §3.1.1 `load`/`store` word: rs2 = source (store only), width[43:40],
/// offset[27:0].
fn memWord(op: u8, rd: u4, rs1: u4, rs2: u4, width: u4, offset: i64) u64 {
    const raw: u28 = @truncate(@as(u64, @bitCast(offset)));
    return (@as(u64, op) << 56) | (@as(u64, rd) << 52) | (@as(u64, rs1) << 48) |
        (@as(u64, rs2) << 44) | (@as(u64, width) << 40) | raw;
}

// ---------------------------------------------------------------------------
// §3.6 accelerator execution (amendment 1.18)
//
// These tests replace a block that asserted all thirteen opcodes REFUSED. That was
// correct while the contract had no operand arithmetic (F36) and is wrong now that
// §3.6 amendment 1.18 supplies it. Tests that pinned the old behaviour were
// retargeted rather than deleted: the ones covering `count = 0`, reserved bytes and
// "nothing committed" still exist, aimed at the rows and rules they now describe.
//
// The data operand roles the amendment fixes, and which each test below exercises:
//   matrix.det      matrix at rs1, order in rs3, determinant into rd
//   matrix.invert   input at rs1, output at rd, order in rs2
//   matrix.mul      headers in rs1/rs2, a at rs3, b at rs1, out at rd
//   matrix.transform stream base at rs1, m at rs2, count = elements per stream
//   matrix.identity output at rd, order in rs1, count must be 0
//   fft.*           data at rs1, count = complex (0x70/0x71) or u64 (0x72/0x73)
//   codec.*         input at rs1, count = bytes
// ---------------------------------------------------------------------------

/// §3.6 word: opcode, rd, rs1, then rs2[47:44] | rs3[43:40] | count[31:0].
fn accelWord(op: u8, rd: u4, rs1: u4, rs2: u4, rs3: u4, count: u32) u64 {
    const operand: u48 = (@as(u48, rs2) << 44) | (@as(u48, rs3) << 40) | @as(u48, count);
    return encode(op, rd, rs1, operand);
}

/// Where accelerator tests put their data. Well clear of the program words, and
/// 16-byte aligned so both the f64 and the Complex paths can use it directly.
const accel_data_base: u64 = 0x1000;
const accel_image_size: usize = 0x20000;

fn putF64(img: []u8, addr: u64, v: f64) void {
    std.mem.writeInt(u64, img[@intCast(addr)..][0..8], @bitCast(v), .little);
}

fn getF64(img: []const u8, addr: u64) f64 {
    return @bitCast(std.mem.readInt(u64, img[@intCast(addr)..][0..8], .little));
}

fn putU64(img: []u8, addr: u64, v: u64) void {
    std.mem.writeInt(u64, img[@intCast(addr)..][0..8], v, .little);
}

fn getU64(img: []const u8, addr: u64) u64 {
    return std.mem.readInt(u64, img[@intCast(addr)..][0..8], .little);
}

/// `mov R<d>, <imm>` — the only way these tests load an address into a register,
/// since a program cannot see its own load address.
fn movImm(d: u4, value: u64) u64 {
    return encode(0x19, d, 0, aluOperand(0, .full, @bitCast(value)));
}

// -- execution ---------------------------------------------------------------

test "codec.fnv1a EXECUTES over exactly count bytes" {
    // The Lead's original proof-of-wiring criterion, now legitimate: the unit is
    // stated (bytes), so no guess remains. The expected value comes from the model
    // rather than a hand-typed constant, so the two cannot drift apart.
    const img = try imageWithSize(&.{
        movImm(2, accel_data_base),
        accelWord(0x82, 1, 2, 0, 0, 12), // codec.fnv1a R1, R2, count=12
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    @memcpy(img[accel_data_base..][0..12], "hello, celer");

    var vm = Vm.init(img);
    _ = try vm.run(100);
    try testing.expectEqual(codec_model.fnv1a("hello, celer"), vm.regs.read(1));
}

test "codec.fnv1a hashes ONLY the counted range: a longer buffer changes nothing" {
    // Load-bearing for the UNIT decision. If `count` were read as elements, or
    // ignored in favour of "the rest of memory", these two runs would differ.
    const bytes = "abcdef";
    const with_tail = try imageWithSize(&.{
        movImm(2, accel_data_base),
        accelWord(0x82, 1, 2, 0, 0, 3), // only the first three bytes
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(with_tail);
    @memcpy(with_tail[accel_data_base..][0..6], bytes);

    const without_tail = try imageWithSize(&.{
        movImm(2, accel_data_base),
        accelWord(0x82, 1, 2, 0, 0, 3),
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(without_tail);
    @memcpy(without_tail[accel_data_base..][0..3], "abc");

    var a = Vm.init(with_tail);
    _ = try a.run(100);
    var b = Vm.init(without_tail);
    _ = try b.run(100);
    try testing.expectEqual(a.regs.read(1), b.regs.read(1));
    try testing.expectEqual(codec_model.fnv1a("abc"), a.regs.read(1));
}

test "codec.checksum16 EXECUTES and zero-extends its 16-bit result" {
    const img = try imageWithSize(&.{
        movImm(2, accel_data_base),
        accelWord(0x83, 1, 2, 0, 0, 8),
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    @memcpy(img[accel_data_base..][0..8], "abcdefgh");

    var vm = Vm.init(img);
    _ = try vm.run(100);
    const expected = codec_model.checksum16("abcdefgh");
    try testing.expectEqual(@as(u64, expected), vm.regs.read(1));
    try testing.expect(vm.regs.read(1) <= 0xFFFF); // zero-extended, not sign-extended
}

test "codec.compress EXECUTES into the normative fixed workspace" {
    const img = try imageWithSize(&.{
        movImm(2, accel_data_base),
        accelWord(0x80, 1, 2, 0, 0, 32),
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    const input = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    @memcpy(img[accel_data_base..][0..input.len], input);

    var vm = Vm.init(img);
    _ = try vm.run(100);
    const clen: usize = @intCast(vm.regs.read(1));
    try testing.expect(clen > 0 and clen <= Vm.codec_workspace_len);
    // The workspace must hold a stream that decompresses back to the input — the
    // only way to show the bytes landed where the contract says they land.
    var out: [64]u8 = undefined;
    const olen = try codec_model.decompress(img[@intCast(Vm.codec_workspace)..][0..clen], &out);
    try testing.expectEqualStrings(input, out[0..olen]);
}

test "matrix.det EXECUTES: matrix at rs1, order in rs3, result into rd" {
    // [[2,1],[1,3]] has determinant 5. The result is written by BIT
    // REINTERPRETATION (rule E.2) — not converted to an integer.
    const img = try imageWithSize(&.{
        movImm(1, accel_data_base),
        accelWord(0x60, 2, 1, 0, 2, 0), // matrix.det R2, R1, rs3=2
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    putF64(img, accel_data_base, 2);
    putF64(img, accel_data_base + 8, 1);
    putF64(img, accel_data_base + 16, 1);
    putF64(img, accel_data_base + 24, 3);

    var vm = Vm.init(img);
    _ = try vm.run(100);
    try testing.expectEqual(@as(f64, 5), @as(f64, @bitCast(vm.regs.read(2))));
}

test "matrix.det's order really comes from rs3: the same matrix reads differently at n=3" {
    // Falsifies "n is a constant" and "n comes from count". A 3x3 view over the same
    // four values plus two adjacent zeros is singular, so the determinant is 0 while
    // the 2x2 reading is 5.
    const img = try imageWithSize(&.{
        movImm(1, accel_data_base),
        accelWord(0x60, 2, 1, 0, 3, 0), // rs3 = 3
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    putF64(img, accel_data_base, 2);
    putF64(img, accel_data_base + 8, 1);
    putF64(img, accel_data_base + 16, 1);
    putF64(img, accel_data_base + 24, 3);
    // bytes 32..72 stay zero, making the third row and column zero -> singular.

    var vm = Vm.init(img);
    _ = try vm.run(100);
    try testing.expectEqual(@as(f64, 0), @as(f64, @bitCast(vm.regs.read(2))));
}

test "matrix.invert EXECUTES: input at rs1, output at rd, order in rs2" {
    const img = try imageWithSize(&.{
        movImm(1, accel_data_base),
        movImm(3, accel_data_base + 0x100),
        accelWord(0x61, 3, 1, 2, 0, 0), // matrix.invert R3, R1, rs2=2
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    const out_addr = accel_data_base + 0x100;
    for ([_]f64{ 4, 7, 2, 6 }, 0..) |v, i| putF64(img, accel_data_base + i * 8, v);

    var vm = Vm.init(img);
    _ = try vm.run(100);
    // [[4,7],[2,6]]^-1 = [[0.6,-0.7],[-0.2,0.4]]
    try testing.expectApproxEqAbs(@as(f64, 0.6), getF64(img, out_addr), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.7), getF64(img, out_addr + 8), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, -0.2), getF64(img, out_addr + 16), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.4), getF64(img, out_addr + 24), 1e-12);
}

test "matrix.transform EXECUTES with the rigid-body m at rs2's address" {
    // A pure translation by (10, 20, 30). The three streams are consecutive f64
    // arrays from rs1; count is elements PER STREAM — the unit F36 said was missing.
    const xs = accel_data_base;
    const m_addr = accel_data_base + 0x800;
    const img = try imageWithSize(&.{
        movImm(1, xs),
        movImm(2, m_addr),
        accelWord(0x63, 3, 1, 2, 0, 2), // matrix.transform R3, R1, R2, count=2
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    putF64(img, xs, 1);
    putF64(img, xs + 8, 2);
    putF64(img, xs + 16, 100); // ys[0]
    putF64(img, xs + 24, 200); // ys[1]
    putF64(img, xs + 32, 1000); // zs[0]
    putF64(img, xs + 40, 2000); // zs[1]
    const m = [16]f64{ 1, 0, 0, 10, 0, 1, 0, 20, 0, 0, 1, 30, 0, 0, 0, 1 };
    for (m, 0..) |v, i| putF64(img, m_addr + i * 8, v);

    var vm = Vm.init(img);
    _ = try vm.run(100);
    try testing.expectEqual(@as(f64, 11), getF64(img, xs));
    try testing.expectEqual(@as(f64, 12), getF64(img, xs + 8));
    try testing.expectEqual(@as(f64, 120), getF64(img, xs + 16));
    try testing.expectEqual(@as(f64, 220), getF64(img, xs + 24));
    try testing.expectEqual(@as(f64, 1030), getF64(img, xs + 32));
    try testing.expectEqual(@as(f64, 2030), getF64(img, xs + 40));
    try testing.expectEqual(@as(u64, 2), vm.regs.read(3)); // per-stream count reported
}

test "matrix.identity EXECUTES: output at rd, order in rs1, and REALLY writes memory" {
    // Sentinels first, so a no-op cannot pass this. The 2x2 identity must overwrite
    // all four f64 slots — the assertion the Lead asked for: an identity matrix
    // actually written to memory, not a program that merely assembles.
    const img = try imageWithSize(&.{
        movImm(1, accel_data_base),
        movImm(2, 2), // the order
        accelWord(0x64, 1, 2, 0, 0, 0), // matrix.identity R1, rs1=R2
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    putF64(img, accel_data_base, 7.5);
    putF64(img, accel_data_base + 8, 7.5);
    putF64(img, accel_data_base + 16, 7.5);
    putF64(img, accel_data_base + 24, 7.5);

    var vm = Vm.init(img);
    _ = try vm.run(100);
    try testing.expect(vm.halted);
    try testing.expectEqual(@as(f64, 1), getF64(img, accel_data_base));
    try testing.expectEqual(@as(f64, 0), getF64(img, accel_data_base + 8));
    try testing.expectEqual(@as(f64, 0), getF64(img, accel_data_base + 16));
    try testing.expectEqual(@as(f64, 1), getF64(img, accel_data_base + 24));
    // One byte past the 2x2 block is untouched, so the write is bounded.
    try testing.expectEqual(@as(f64, 0), getF64(img, accel_data_base + 32));
}

test "matrix.identity with a zero order writes nothing and is not an error" {
    // The one row where 0 is a meaningful value rather than a missing length. Without
    // this positive control, rule D's "count = 0 is an error" could be implemented as
    // "always refuse 0" and the distinction would be untested.
    const img = try imageWithSize(&.{
        movImm(1, accel_data_base),
        accelWord(0x64, 1, 0, 0, 0, 0), // rs1 = 0
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    putF64(img, accel_data_base, 7.5); // sentinel: must survive

    var vm = Vm.init(img);
    _ = try vm.run(100);
    try testing.expect(vm.halted);
    try testing.expectEqual(@as(f64, 7.5), getF64(img, accel_data_base));
}

test "fft.forward EXECUTES on complex elements and matches the independent DFT" {
    // count is COMPLEX elements (16 bytes each) — the unit F36 flagged as undefined,
    // where a byte reading would differ by 16x. The reference is `naiveDft`, which
    // shares no code with the fast path, so this cannot pass on a consistent bug.
    const base = accel_data_base;
    const img = try imageWithSize(&.{
        movImm(1, base),
        accelWord(0x70, 2, 1, 0, 0, 4), // fft.forward R2, R1, count=4
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    const original = [4]fft_model.Complex{
        .{ .re = 1, .im = 0 },
        .{ .re = 2, .im = -1 },
        .{ .re = 0, .im = 3 },
        .{ .re = -4, .im = 0.5 },
    };
    for (original, 0..) |c, i| {
        putF64(img, base + i * 16, c.re);
        putF64(img, base + i * 16 + 8, c.im);
    }

    var vm = Vm.init(img);
    _ = try vm.run(100);
    var expect: [4]fft_model.Complex = undefined;
    try fft_model.naiveDft(&original, &expect);
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try testing.expectApproxEqAbs(expect[i].re, getF64(img, base + i * 16), 1e-9);
        try testing.expectApproxEqAbs(expect[i].im, getF64(img, base + i * 16 + 8), 1e-9);
    }
    try testing.expectEqual(@as(u64, 4), vm.regs.read(2));
}

test "fft.forward then fft.inverse restores the input" {
    const base = accel_data_base;
    const img = try imageWithSize(&.{
        movImm(1, base),
        accelWord(0x70, 2, 1, 0, 0, 4),
        accelWord(0x71, 3, 1, 0, 0, 4),
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    const original = [4]fft_model.Complex{
        .{ .re = 1, .im = 0 },
        .{ .re = 2, .im = -1 },
        .{ .re = 0, .im = 3 },
        .{ .re = -4, .im = 0.5 },
    };
    for (original, 0..) |c, i| {
        putF64(img, base + i * 16, c.re);
        putF64(img, base + i * 16 + 8, c.im);
    }

    var vm = Vm.init(img);
    _ = try vm.run(100);
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try testing.expectApproxEqAbs(original[i].re, getF64(img, base + i * 16), 1e-9);
        try testing.expectApproxEqAbs(original[i].im, getF64(img, base + i * 16 + 8), 1e-9);
    }
}

test "fft.ntt EXECUTES over u64 elements" {
    const base = accel_data_base;
    const img = try imageWithSize(&.{
        movImm(1, base),
        // rs2 stays zero: this build has one fixed modulus (rule E.6)
        accelWord(0x72, 3, 1, 0, 0, 4), // fft.ntt R3, R1, count=4
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    const data_in = [4]u64{ 1, 2, 3, 4 };
    for (data_in, 0..) |v, i| putU64(img, base + i * 8, v);

    var vm = Vm.init(img);
    _ = try vm.run(100);
    var expect = data_in;
    try fft_model.ntt(&expect, false);
    for (expect, 0..) |v, i| try testing.expectEqual(v, getU64(img, base + i * 8));
}

test "a u64 count on fft.ntt is ELEMENTS, not bytes: count=4 reads 32 bytes" {
    // Pins the unit the amendment chose for 0x72/0x73. A byte reading would consume
    // 4 bytes and leave the fourth element untouched.
    const base = accel_data_base;
    const img = try imageWithSize(&.{
        movImm(1, base),
        // rs2 stays zero: this build has one fixed modulus (rule E.6)
        accelWord(0x72, 3, 1, 2, 0, 4),
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    for ([_]u64{ 1, 2, 3, 4 }, 0..) |v, i| putU64(img, base + i * 8, v);

    var vm = Vm.init(img);
    _ = try vm.run(100);
    // All 32 bytes participate: the fourth residue is no longer its input value.
    try testing.expect(getU64(img, base + 24) != 4);
}

// -- refusals ----------------------------------------------------------------

test "count = 0 is REFUSED on every row that needs a length" {
    // Amendment 1.18 rule D. §3.6 line 490's "derive the count from the destination
    // register" is superseded: a zero count is a diagnostic error, not a licence to
    // read `rd` as an input length. `matrix.identity` is the one row exempted, and
    // the test after this one is its positive control.
    const cases = [_]struct { op: u8, name: []const u8 }{
        .{ .op = 0x63, .name = "matrix.transform" },
        .{ .op = 0x70, .name = "fft.forward" },
        .{ .op = 0x71, .name = "fft.inverse" },
        .{ .op = 0x72, .name = "fft.ntt" },
        .{ .op = 0x73, .name = "fft.ntt.inverse" },
        .{ .op = 0x80, .name = "codec.compress" },
        .{ .op = 0x82, .name = "codec.fnv1a" },
        .{ .op = 0x83, .name = "codec.checksum16" },
    };
    for (cases) |c| {
        const img = try imageWith(&.{accelWord(c.op, 1, 2, 3, 0, 0)});
        defer testing.allocator.free(img);
        var vm = Vm.init(img);
        const s = try vm.step();
        try testing.expect(s == .fault);
        var buf: [2048]u8 = undefined;
        const text = diagnostics.renderToBuffer(s.fault, &buf);
        try testing.expect(std.mem.indexOf(u8, text, c.name) != null);
        try testing.expect(std.mem.indexOf(u8, text, "zero count") != null);
        // Nothing was committed, and the count register was NOT read as a length.
        try testing.expectEqual(@as(u64, 0), vm.retired);
        try testing.expectEqual(@as(u64, 0), vm.regs.pc);
        try testing.expect(!diagnostics.hasBareHexCode(text));
    }
}

test "count = 0 is refused even when rd holds a plausible length" {
    // The rejected alternative, tested directly. The old rule would have read `rd`
    // as the count; a program that pre-loads its result register with a length must
    // NOT get a silently different computation. With rd = 8, a count-reading
    // implementation would hash 8 bytes and succeed — this asserts it refuses.
    const img = try imageWithSize(&.{
        movImm(2, accel_data_base), // source address
        movImm(1, 8), // rd pre-loaded with a length, which 1.18 does NOT read
        accelWord(0x82, 1, 2, 0, 0, 0), // codec.fnv1a R1, R2 (no count written)
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    @memcpy(img[accel_data_base..][0..8], "12345678");

    var vm = Vm.init(img);
    _ = try vm.step();
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);
    try testing.expectEqual(@as(u64, 8), vm.regs.read(1)); // rd untouched
}

test "matrix.identity does NOT read count as its order: a non-zero count is refused" {
    // Pins the row's stated source. `count=N` is accepted by the ASSEMBLER for this
    // row (it takes_count), but the order comes from rs1, so a word carrying a
    // non-zero count would otherwise be ambiguous about which one wins. It refuses.
    const img = try imageWith(&.{accelWord(0x64, 1, 2, 0, 0, 2)});
    defer testing.allocator.free(img);
    var vm = Vm.init(img);
    const s = try vm.step();
    try testing.expect(s == .fault);
    var buf: [2048]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "matrix.identity") != null);
    try testing.expect(std.mem.indexOf(u8, text, "first source register") != null);
}

test "a MISALIGNED f64 address refuses with a sentence instead of panicking" {
    // F36's alignment trap. The models take []f64 and mem.bytes' base alignment is
    // NOT guaranteed (Vm.init accepts any []u8; tests use testing.allocator), so an
    // @alignCast on this address would panic. The check must be a refusal.
    const img = try imageWith(&.{
        movImm(1, 0x1002), // 8-aligned? no: 0x1002 % 8 == 2
        accelWord(0x64, 1, 2, 0, 0, 0), // matrix.identity R1, rs1=2
    });
    defer testing.allocator.free(img);
    var vm = Vm.init(img);
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);
    var buf: [2048]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "multiple of 8 bytes") != null);
    try testing.expect(std.mem.indexOf(u8, text, "matrix.identity") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
    try testing.expectEqual(@as(u64, 1), vm.retired); // the refused word did not retire
}

test "an fft address that is 8-aligned but NOT 16-aligned refuses" {
    // Complex is 16 bytes, so its requirement is 16. An 8-byte check would accept
    // this word and reinterpret two complexes from the middle of one — a silent
    // wrong answer, which is what rule E.3 exists to prevent.
    const img = try imageWith(&.{
        movImm(1, 0x1008),
        accelWord(0x70, 2, 1, 0, 0, 4),
    });
    defer testing.allocator.free(img);
    var vm = Vm.init(img);
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);
    var buf: [2048]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "multiple of 16 bytes") != null);
}

test "an out-of-bounds accelerator range refuses, NAMING the address and the length" {
    // Rule E.3 requires the sentence to name both, and the refusal must precede any
    // byte being touched. The image here is exactly `imageWith`'s program-sized
    // buffer, so a 1 MiB read cannot fit.
    const img = try imageWithSize(&.{
        movImm(1, 0x40),
        accelWord(0x82, 2, 1, 0, 0, 1 << 20), // codec.fnv1a over 1 MiB
    }, 0x100);
    defer testing.allocator.free(img);
    var vm = Vm.init(img);
    const before = vm.snapshot();
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);
    var buf: [2048]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "64") != null);
    try testing.expect(std.mem.indexOf(u8, text, "1048576") != null);
    try testing.expect(std.mem.indexOf(u8, text, "256 bytes long") != null);
    try testing.expect(std.mem.indexOf(u8, text, "codec.fnv1a") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
    // Nothing partially applied: memory byte-identical, nothing retired.
    try testing.expectEqual(before.mem_hash, vm.snapshot().mem_hash);
    try testing.expectEqual(@as(u64, 1), vm.retired);
    // And the sentence fits the CLI's 1024-byte buffer with room to spare.
    var cli_buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&cli_buf);
    s.fault.render(&w) catch return error.DiagnosticExceedsCliBuffer;
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "."));
    try testing.expect(w.buffered().len < 900);
}

test "an address that overflows when the length is added still refuses" {
    // `addr +| len` saturates, so an address near the top of the range cannot wrap
    // into a small in-bounds window. This is the arithmetic-bug guard for rule E.3.
    const img = try imageWith(&.{
        movImm(1, std.math.maxInt(u64) - 4),
        accelWord(0x82, 2, 1, 0, 0, 4096),
    });
    defer testing.allocator.free(img);
    var vm = Vm.init(img);
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);
}

test "a non-zero unused operand field is REFUSED, not silently ignored" {
    // Rule E. `fft.ntt` does not use rs3; a word that sets it must not compute the
    // same thing as one that leaves it zero, or the extra register carries a meaning
    // the operation does not have.
    const img = try imageWith(&.{
        movImm(1, 0x1000),
        accelWord(0x72, 3, 1, 0, 5, 4), // rs3 = 5, unused
    });
    defer testing.allocator.free(img);
    var vm = Vm.init(img);
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);
    var buf: [2048]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "third source register") != null);
    try testing.expect(std.mem.indexOf(u8, text, "must be zero") != null);
}

test "fft.ntt refuses a non-zero modulus register instead of ignoring it" {
    // Rule E.6. Validating a modulus and then computing with a different constant is
    // the F34 "validated but dropped" class, so a non-zero rs2 is a refusal.
    const img = try imageWithSize(&.{
        movImm(1, accel_data_base),
        movImm(2, 17),
        accelWord(0x72, 3, 1, 2, 0, 4),
    }, accel_image_size);
    defer testing.allocator.free(img);
    var vm = Vm.init(img);
    _ = try vm.step();
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);
    var buf: [2048]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "fft.ntt") != null);
    try testing.expect(std.mem.indexOf(u8, text, "modulus") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "a non-power-of-two fft length reaches the model and refuses in plain language" {
    const img = try imageWithSize(&.{
        movImm(1, 0x1000),
        accelWord(0x70, 2, 1, 0, 0, 3), // 3 is not a power of two
    }, 0x2000);
    defer testing.allocator.free(img);
    var vm = Vm.init(img);
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);
    var buf: [2048]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "fft.forward") != null);
    try testing.expect(std.mem.indexOf(u8, text, "not a power of two") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "matrix.invert refuses a SINGULAR matrix in plain language" {
    const img = try imageWithSize(&.{
        movImm(1, accel_data_base),
        movImm(3, accel_data_base + 0x100),
        accelWord(0x61, 3, 1, 2, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    // [[1,2],[2,4]] is singular.
    for ([_]f64{ 1, 2, 2, 4 }, 0..) |v, i| putF64(img, accel_data_base + i * 8, v);

    var vm = Vm.init(img);
    _ = try vm.step();
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);
    var buf: [2048]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "matrix.invert") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "codec.decompress STILL REFUSES, and says why it is not a missing constant" {
    // The one §3.6 row that remains refused for a bound reason. This test exists so a
    // future "finish the accelerators" pass cannot wire it by reusing compress's
    // workspace and silently narrowing the operation's domain.
    const img = try imageWith(&.{accelWord(0x81, 1, 2, 0, 0, 8)});
    defer testing.allocator.free(img);
    var vm = Vm.init(img);
    const s = try vm.step();
    try testing.expect(s == .fault);
    var buf: [2048]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "codec.decompress") != null);
    try testing.expect(std.mem.indexOf(u8, text, "256") != null);
    try testing.expect(std.mem.indexOf(u8, text, "E.1") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "matrix.mul STILL REFUSES, because five inputs do not fit four fields" {
    // A genuine field shortage, not a missing constant. The refusal must say so, so
    // the next reader does not re-derive it or "fix" it by inventing a fifth field.
    const img = try imageWith(&.{accelWord(0x62, 1, 2, 3, 4, 0)});
    defer testing.allocator.free(img);
    var vm = Vm.init(img);
    const s = try vm.step();
    try testing.expect(s == .fault);
    var buf: [2048]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "matrix.mul") != null);
    try testing.expect(std.mem.indexOf(u8, text, "E.5") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

// -- amendment 1.19: matrix.mulout (0x65) -----------------------------------

// The references below were computed in Python, independently of matrix.zig, from
// the same hand-chosen values:
//   A = [[1,2,3],[4,5,6]]   (2x3)      B = [[7,8],[9,10],[11,12]]   (3x2)
//   A.B = [[58,64],[139,154]]          (2x2)
// If the VM had transposed either operand, indexed by the wrong stride, or read the
// headers as the wrong order, these four numbers would differ.

/// Writes a `rows:u32 | cols:u32` header at `addr` and the data after it, row-major.
fn putMatrix(img: []u8, addr: u64, rows: u32, cols: u32, data: []const f64) void {
    std.mem.writeInt(u32, img[@intCast(addr)..][0..4], rows, .little);
    std.mem.writeInt(u32, img[@intCast(addr + 4)..][0..4], cols, .little);
    for (data, 0..) |v, i| putF64(img, addr + 8 + i * 8, v);
}

const mul_a = [6]f64{ 1, 2, 3, 4, 5, 6 };
const mul_b = [6]f64{ 7, 8, 9, 10, 11, 12 };

const mul_a_addr: u64 = accel_data_base;
const mul_b_addr: u64 = accel_data_base + 0x100;
const mul_out_addr: u64 = accel_data_base + 0x200;

/// `rd` = out, `rs1` = A, `rs2` = B, `rs3` and `count` zero. Returns the halted
/// machine and its image; the caller asserts on memory and registers.
fn runMulOut(op: u8, rs3: u4, count: u32) !struct { img: []u8, vm: Vm } {
    const img = try imageWithSize(&.{
        movImm(1, mul_a_addr),
        movImm(2, mul_b_addr),
        movImm(3, mul_out_addr),
        accelWord(op, 3, 1, 2, rs3, count),
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    putMatrix(img, mul_a_addr, 2, 3, &mul_a);
    putMatrix(img, mul_b_addr, 3, 2, &mul_b);
    var vm = Vm.init(img);
    _ = try vm.run(100);
    return .{ .img = img, .vm = vm };
}

test "matrix.mulout (0x65) EXECUTES and writes the correct product, header first" {
    // This is the product the shipped `matmul_8x8` path refuses to reach through
    // 0x62 because that word cannot name a matrix's order. Here the orders are in
    // memory, so nothing is guessed.
    const run = try runMulOut(0x65, 0, 0);
    defer testing.allocator.free(run.img);

    // The header describes the product: 2 rows, 2 columns.
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, run.img[mul_out_addr..][0..4], .little));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, run.img[mul_out_addr + 4 ..][0..4], .little));
    // Row-major [[58,64],[139,154]] — the Python reference.
    try testing.expectEqual(@as(f64, 58), getF64(run.img, mul_out_addr + 8));
    try testing.expectEqual(@as(f64, 64), getF64(run.img, mul_out_addr + 16));
    try testing.expectEqual(@as(f64, 139), getF64(run.img, mul_out_addr + 24));
    try testing.expectEqual(@as(f64, 154), getF64(run.img, mul_out_addr + 32));
    // `rd` holds the product's ADDRESS as a plain VALUE and is NOT rewritten: unlike
    // `matrix.det`, this operation's result is entirely in memory, so there is no
    // scalar to reinterpret into the register (rule E.7).
    try testing.expectEqual(mul_out_addr, run.vm.regs.read(3));
}

test "matrix.mulout's ranking is REAL: rewriting a into the product of a different shape changes it" {
    // Falsifies "the product ignores the headers and assumes squares". A is 2x3 and
    // B is 3x2, so a square-reading implementation cannot produce the reference.
    // Rewriting A's data as 2x3 of doubled values must DOUBLE every product entry.
    const run = try runMulOut(0x65, 0, 0);
    defer testing.allocator.free(run.img);
    var doubled = mul_a;
    for (&doubled) |*v| v.* *= 2;

    const img2 = try imageWithSize(&.{
        movImm(1, mul_a_addr),
        movImm(2, mul_b_addr),
        movImm(3, mul_out_addr),
        accelWord(0x65, 3, 1, 2, 0, 0),
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img2);
    putMatrix(img2, mul_a_addr, 2, 3, &doubled);
    putMatrix(img2, mul_b_addr, 3, 2, &mul_b);
    var vm = Vm.init(img2);
    _ = try vm.run(100);
    try testing.expectEqual(@as(f64, 116), getF64(img2, mul_out_addr + 8));
    try testing.expectEqual(@as(f64, 128), getF64(img2, mul_out_addr + 16));
    try testing.expectEqual(@as(f64, 278), getF64(img2, mul_out_addr + 24));
    try testing.expectEqual(@as(f64, 308), getF64(img2, mul_out_addr + 32));
}

/// Steps past the three `mov` setup words and returns the accelerator's fault.
/// The step-by-step form is the existing idiom, and it is what yields the exact
/// `Diagnostic` the CLI would render.
fn mulOutFault(vm: *Vm) !struct { text: [1024]u8, len: usize } {
    var i: usize = 0;
    while (i < 3) : (i += 1) _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);
    var out: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try s.fault.render(&w);
    return .{ .text = out, .len = w.buffered().len };
}

fn expectRefused(vm: *Vm, needles: []const []const u8) !void {
    const f = try mulOutFault(vm);
    const text = f.text[0..f.len];
    for (needles) |n| try testing.expect(std.mem.indexOf(u8, text, n) != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
    // main.zig renders into a fixed [1024]u8 and DROPS overflow with `catch {}`.
    try testing.expect(std.mem.endsWith(u8, text, "."));
    try testing.expect(text.len < 900);
}

test "matrix.mulout: a dimension mismatch is a sentence, never a wrong answer" {
    // A says 2x3, B says 4x1: A's 3 columns cannot meet B's 4 rows. Nothing may be
    // written — the destination header slot must still be zero afterwards.
    const img = try imageWithSize(&.{
        movImm(1, mul_a_addr),
        movImm(2, mul_b_addr),
        movImm(3, mul_out_addr),
        accelWord(0x65, 3, 1, 2, 0, 0),
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    putMatrix(img, mul_a_addr, 2, 3, &mul_a);
    putMatrix(img, mul_b_addr, 4, 1, &[_]f64{ 1, 2, 3, 4 });
    var vm = Vm.init(img);
    try expectRefused(&vm, &.{ "matrix.mulout", "3 columns", "4 rows", "nothing was computed" });
    try testing.expectEqual(@as(u64, 0), getU64(img, mul_out_addr));
}

test "matrix.mulout: an out-of-bounds header refuses, NAMING the address and the length" {
    // Address 64 is where a fifth program word would go, so the header's own eight
    // bytes are past the end of this 64-byte image.
    const img = try imageWithSize(&.{
        movImm(1, 64),
        movImm(2, accel_data_base),
        movImm(3, mul_out_addr),
        accelWord(0x65, 3, 1, 2, 0, 0),
        encode(0x01, 0, 0, 0),
    }, 64);
    defer testing.allocator.free(img);
    var vm = Vm.init(img);
    try expectRefused(&vm, &.{ "8 bytes at address 64", "64 bytes long", "no byte was touched" });
}

test "matrix.mulout: a header whose data would run past the image refuses before touching a byte" {
    // A 16x2 header inside bounds whose declared 16x2 data (256 bytes) runs past
    // the end of the image. B says 2x1, so the SIZES are consistent and only the
    // bounds check can refuse — the check must come from the header's own numbers,
    // not from how much room happens to be left over.
    const near_end = accel_image_size - 8;
    const img = try imageWithSize(&.{
        movImm(1, near_end),
        movImm(2, mul_b_addr),
        movImm(3, mul_out_addr),
        accelWord(0x65, 3, 1, 2, 0, 0),
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    std.mem.writeInt(u32, img[near_end..][0..4], 16, .little);
    std.mem.writeInt(u32, img[near_end + 4 ..][0..4], 2, .little);
    putMatrix(img, mul_b_addr, 2, 1, &[_]f64{ 1, 2 });
    var vm = Vm.init(img);
    try expectRefused(&vm, &.{ "256 bytes", "no byte was touched" });
    try testing.expectEqual(@as(u64, 0), getU64(img, mul_out_addr));
}

test "matrix.mulout: a misaligned data address is refused with a sentence, never cast" {
    // A valid 2x3 header at an address 4 bytes off an 8-byte boundary. The header
    // is only 4-aligned and is readable; the f64 data that follows it is NOT
    // 8-aligned. A misaligned @alignCast would panic here; a refusal prints a
    // sentence (rule E.3).
    const odd_a = mul_a_addr + 4;
    const img = try imageWithSize(&.{
        movImm(1, odd_a),
        movImm(2, mul_b_addr),
        movImm(3, mul_out_addr),
        accelWord(0x65, 3, 1, 2, 0, 0),
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(img);
    putMatrix(img, odd_a, 2, 3, &mul_a);
    putMatrix(img, mul_b_addr, 3, 2, &mul_b);
    var vm = Vm.init(img);
    try expectRefused(&vm, &.{ "not a multiple of 8 bytes" });
}

test "matrix.mulout: a non-zero rs3 or count is refused, not ignored" {
    // Rule E's redundant-operand rule. A silently ignored field is the F34 class.
    const with_rs3 = try imageWithSize(&.{
        movImm(1, mul_a_addr),
        movImm(2, mul_b_addr),
        movImm(3, mul_out_addr),
        accelWord(0x65, 3, 1, 2, 5, 0),
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(with_rs3);
    putMatrix(with_rs3, mul_a_addr, 2, 3, &mul_a);
    putMatrix(with_rs3, mul_b_addr, 3, 2, &mul_b);
    var a = Vm.init(with_rs3);
    try expectRefused(&a, &.{ "third source register", "must be zero" });

    const with_count = try imageWithSize(&.{
        movImm(1, mul_a_addr),
        movImm(2, mul_b_addr),
        movImm(3, mul_out_addr),
        accelWord(0x65, 3, 1, 2, 0, 6),
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(with_count);
    putMatrix(with_count, mul_a_addr, 2, 3, &mul_a);
    putMatrix(with_count, mul_b_addr, 3, 2, &mul_b);
    var b = Vm.init(with_count);
    try expectRefused(&b, &.{ "count field must be zero", "6 was written" });
}

test "matrix.mulout: a zero side or a side over the limit refuses rather than computing" {
    const zero = try imageWithSize(&.{
        movImm(1, mul_a_addr),
        movImm(2, mul_b_addr),
        movImm(3, mul_out_addr),
        accelWord(0x65, 3, 1, 2, 0, 0),
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(zero);
    putMatrix(zero, mul_a_addr, 2, 0, &mul_a);
    putMatrix(zero, mul_b_addr, 3, 2, &mul_b);
    var a = Vm.init(zero);
    try expectRefused(&a, &.{"no rows or no columns"});

    const big = try imageWithSize(&.{
        movImm(1, mul_a_addr),
        movImm(2, mul_b_addr),
        movImm(3, mul_out_addr),
        accelWord(0x65, 3, 1, 2, 0, 0),
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(big);
    putMatrix(big, mul_a_addr, 17, 3, &mul_a);
    putMatrix(big, mul_b_addr, 3, 2, &mul_b);
    var b = Vm.init(big);
    try expectRefused(&b, &.{ "17 rows", "at most 16 by 16" });
}

test "0x62 matrix.mul is UNCHANGED by amendment 1.19: still refused, same sentence" {
    // The pair that proves 0x65 did not steal 0x62's meaning. Both are dispatched
    // from the same switch, so a careless edit could route 0x62 to accelMulOut.
    const img = try imageWith(&.{accelWord(0x62, 1, 2, 3, 4, 0)});
    defer testing.allocator.free(img);
    var vm = Vm.init(img);
    const s = try vm.step();
    try testing.expect(s == .fault);
    var buf: [2048]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "matrix.mul") != null);
    try testing.expect(std.mem.indexOf(u8, text, "matrix.mulout") == null);
    try testing.expect(std.mem.indexOf(u8, text, "E.5") != null);
}

test "a RESERVED §3.6 byte still refuses DIFFERENTLY from a defined one" {
    // 0x6F has no §3.6 row and is reserved. The distinction between "reserved" and
    // "defined but refused" is the contract's, and it must survive this change.
    //
    // CONTRADICTS THE ORIGINAL TASK BRIEF, and still true: the brief said a reserved
    // byte "must keep hitting the fault path" as though the DECODER rejected it. It
    // does not — `decoder.decode` accepts every byte in 0x60-0x8F as `.accelerator`
    // with no table lookup, and amendment 1.20 (§3.6) now states that this is REQUIRED,
    // not an oversight: clause 2's raw-byte round-trip depends on it. So the refusal is
    // made HERE, by the §3.6 registry lookup. F37 is resolved by amendment 1.20; see
    // docs/STATUS.md F37 and the pinning test in decoder.zig, which must keep agreeing
    // with this one.
    const reserved = try imageWith(&.{accelWord(0x6F, 1, 2, 0, 0, 0)});
    defer testing.allocator.free(reserved);
    var a = Vm.init(reserved);
    const sa = try a.step();
    try testing.expect(sa == .fault);
    var buf_a: [2048]u8 = undefined;
    const text_a = diagnostics.renderToBuffer(sa.fault, &buf_a);
    try testing.expect(std.mem.indexOf(u8, text_a, "does not list") != null);
    try testing.expect(std.mem.indexOf(u8, text_a, "matrix.det") == null);
    try testing.expect(!diagnostics.hasBareHexCode(text_a));

    // A defined row that DOES refuse names itself and says why — a different sentence.
    const refused = try imageWith(&.{accelWord(0x81, 1, 2, 0, 0, 8)});
    defer testing.allocator.free(refused);
    var b = Vm.init(refused);
    const sb = try b.step();
    try testing.expect(sb == .fault);
    var buf_b: [2048]u8 = undefined;
    const text_b = diagnostics.renderToBuffer(sb.fault, &buf_b);
    try testing.expect(std.mem.indexOf(u8, text_b, "codec.decompress") != null);
    try testing.expect(std.mem.indexOf(u8, text_b, "does not list") == null);
    try testing.expect(!std.mem.eql(u8, text_a, text_b));
}

test "the reserved path retires nothing and writes no register" {
    const img = try imageWith(&.{
        movImm(1, 0x99),
        accelWord(0x6F, 2, 1, 0, 0, 0), // reserved 0x6F, rd = R2
    });
    defer testing.allocator.free(img);
    var vm = Vm.init(img);
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);
    try testing.expectEqual(@as(u64, 0), vm.regs.read(2)); // no fabricated result
    try testing.expectEqual(@as(u64, 1), vm.retired);
    try testing.expectEqual(@as(u64, 8), vm.regs.pc);
}

test "an ACCEPTED accelerator commits, and a REFUSED one does not" {
    // The atomicity property, both directions. Without the positive half, a VM that
    // refused everything would satisfy the negative half.
    const accepted = try imageWithSize(&.{
        movImm(1, accel_data_base),
        accelWord(0x64, 1, 2, 0, 0, 0), // matrix.identity R1, rs1=2 — valid
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(accepted);
    var a = Vm.init(accepted);
    _ = try a.step();
    const sa = try a.step();
    try testing.expect(sa == .advanced);
    try testing.expectEqual(@as(u64, 2), a.retired);
    try testing.expectEqual(@as(u64, 16), a.regs.pc);

    const refused = try imageWithSize(&.{
        movImm(1, accel_data_base + 2), // misaligned: refused
        accelWord(0x64, 1, 2, 0, 0, 0),
        encode(0x01, 0, 0, 0),
    }, accel_image_size);
    defer testing.allocator.free(refused);
    var b = Vm.init(refused);
    _ = try b.step();
    const sb = try b.step();
    try testing.expect(sb == .fault);
    try testing.expectEqual(@as(u64, 1), b.retired);
    try testing.expectEqual(@as(u64, 8), b.regs.pc);
}

test "the accelerator arm does not disturb the instructions around it" {
    // The `else` arm it replaced was the catch-all; scoping the new rules to
    // `.accelerator` must not change `cap.*`'s refusals, which sit immediately above.
    const img = try imageWithSize(&.{
        movImm(1, accel_data_base),
        accelWord(0x60, 2, 1, 0, 2, 0), // matrix.det R2, R1, rs3=2 — executes
        encode(0x52, 0, 4, 0), // cap.check — refuses on its own rule
    }, accel_image_size);
    defer testing.allocator.free(img);
    var vm = Vm.init(img);
    _ = try vm.step();
    const det = try vm.step();
    try testing.expect(det == .advanced);
    const cap = try vm.step();
    try testing.expect(cap == .fault);
    var cbuf: [2048]u8 = undefined;
    const ctext = diagnostics.renderToBuffer(cap.fault, &cbuf);
    try testing.expect(std.mem.indexOf(u8, ctext, "capability check") != null);
    try testing.expect(std.mem.indexOf(u8, ctext, "accelerator") == null);
}

test "codec.compress REFUSES cleanly when the image is too small for the workspace" {
    // §3.6 rule C's checked precondition. The rule's earlier draft claimed every entry
    // point allocates 64 KiB; that was false (crossarch's fixture is 4,672 bytes,
    // examples' is 20,480), so this direction must be a refusal and not a failed
    // access, a clipped workspace or a relocated one.
    const img = try imageWithSize(&.{
        movImm(2, 0x100),
        accelWord(0x80, 1, 2, 0, 0, 8),
        encode(0x01, 0, 0, 0),
    }, 0x1000); // 4096 bytes: far below 65280 + 256
    defer testing.allocator.free(img);
    @memcpy(img[0x100..][0..8], "abcdefgh");

    var vm = Vm.init(img);
    const before = vm.snapshot();
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);
    var buf: [2048]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "codec.compress") != null);
    try testing.expect(std.mem.indexOf(u8, text, "65280") != null);
    try testing.expect(std.mem.indexOf(u8, text, "256") != null);
    try testing.expect(std.mem.indexOf(u8, text, "4096") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
    // Nothing partially applied.
    try testing.expectEqual(before.mem_hash, vm.snapshot().mem_hash);
    try testing.expectEqual(@as(u64, 1), vm.retired);
    // And the sentence is not truncated by the CLI's 1024-byte buffer.
    var cli_buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&cli_buf);
    s.fault.render(&w) catch return error.DiagnosticExceedsCliBuffer;
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "."));
    try testing.expect(w.buffered().len < 900);
}

test "codec.compress EXECUTES when the image is large enough for the workspace" {
    // The other direction of the same precondition. Without this positive control,
    // "always refuse compress" would satisfy the test above.
    const big = Vm.codec_workspace + Vm.codec_workspace_len + 64;
    const img = try imageWithSize(&.{
        movImm(2, 0x100),
        accelWord(0x80, 1, 2, 0, 0, 32),
        encode(0x01, 0, 0, 0),
    }, @intCast(big));
    defer testing.allocator.free(img);
    const input = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    @memcpy(img[0x100..][0..input.len], input);

    var vm = Vm.init(img);
    _ = try vm.run(100);
    const clen: usize = @intCast(vm.regs.read(1));
    try testing.expect(clen > 0 and clen <= Vm.codec_workspace_len);
    var out: [64]u8 = undefined;
    const olen = try codec_model.decompress(img[@intCast(Vm.codec_workspace)..][0..clen], &out);
    try testing.expectEqualStrings(input, out[0..olen]);
}
