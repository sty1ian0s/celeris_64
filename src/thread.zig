//! Celeris-64 SMT-8 thread-slot model (spec §4.1, AGENTS.md §2.4).
//!
//! ════════════════════════════════════════════════════════════════════════════
//! FIDELITY — READ THIS BEFORE TRUSTING ANYTHING BELOW (docs/isa-encoding.md §8)
//!
//! This is an INTERLEAVED SOFTWARE MODEL of eight hardware thread slots.
//!
//! It is NOT parallel. Nothing here runs concurrently: slots are stepped one at a
//! time by a scheduler on a single thread of execution.
//! It is NOT zero-cycle. Switching slots costs real work in this model.
//! It does NOT share L1/L2 caches, because no caches exist here to share.
//! It makes NO claim about DRAM latency hiding, which is the actual purpose of
//! the hardware feature being modelled.
//!
//! What it DOES provide is the architectural contract in executable form: eight
//! private register files (T0-T7), deterministic interleaving, and a guarantee
//! that a slot's registers are untouched by any other slot. That last property is
//! the one worth testing, because it is the one software can actually get wrong.
//! ════════════════════════════════════════════════════════════════════════════
//!
//! Normative reference: docs/isa-encoding.md §3.7 and the architecture spec §4.1.

const std = @import("std");
const registers = @import("registers.zig");

/// SMT-8: eight thread slots per physical core (spec §4.1).
pub const slot_count = 8;

pub const ThreadError = error{
    NoSuchSlot,
    SlotAlreadyActive,
    SlotNotActive,
};

pub fn explain(err: ThreadError) []const u8 {
    return switch (err) {
        error.NoSuchSlot =>
            "The program named a thread slot that does not exist on this machine. " ++
                "Celeris-64 provides eight slots per core, numbered T0 through T7.",
        error.SlotAlreadyActive =>
            "The program tried to start a thread in a slot that is already running. " ++
                "A slot must finish or be halted before it can be reused.",
        error.SlotNotActive =>
            "The program tried to join or inspect a thread slot that is not running. " ++
                "Nothing was started in that slot, so there is nothing to wait for.",
    };
}

pub const SlotState = enum {
    /// Nothing has been started here.
    idle,
    /// Started and still has work.
    running,
    /// Finished, or halted itself.
    finished,
};

/// One hardware thread slot: a private register file plus its own PC.
pub const Slot = struct {
    state: SlotState = .idle,
    regs: registers.File = .{},
    /// Instructions this slot has retired.
    retired: u64 = 0,

    /// The address this slot started at, kept so a restart is reproducible.
    entry: u64 = 0,
};

pub const Scheduler = struct {
    slots: [slot_count]Slot = @splat(.{}),

    /// Most recently dispatched slot, for reporting.
    last_dispatched: ?u4 = null,
    /// How many dispatch decisions the scheduler has made.
    dispatches: u64 = 0,

    pub fn init() Scheduler {
        return .{};
    }

    pub fn slot(self: *Scheduler, index: u4) ThreadError!*Slot {
        if (index >= slot_count) return error.NoSuchSlot;
        return &self.slots[index];
    }

    /// `thread.spawn`: put a slot into the running state at `entry`.
    pub fn spawn(self: *Scheduler, index: u4, entry: u64) ThreadError!void {
        const s = try self.slot(index);
        if (s.state == .running) return error.SlotAlreadyActive;
        s.* = .{ .state = .running, .regs = .{}, .retired = 0, .entry = entry };
        s.regs.pc = entry;
    }

    /// `thread.join`: mark a running slot finished.
    pub fn join(self: *Scheduler, index: u4) ThreadError!void {
        const s = try self.slot(index);
        if (s.state != .running) return error.SlotNotActive;
        s.state = .finished;
    }

    pub fn activeCount(self: *const Scheduler) usize {
        var n: usize = 0;
        for (self.slots) |s| {
            if (s.state == .running) n += 1;
        }
        return n;
    }

    /// Pick the next slot to run: strict round-robin from T0 to T7.
    ///
    /// DETERMINISTIC BY CONSTRUCTION. There is no timing input, no randomness and
    /// no priority — so the same program always interleaves identically, which is
    /// the property that makes this model testable at all.
    pub fn nextRunnable(self: *Scheduler) ?u4 {
        const start: u4 = if (self.last_dispatched) |last|
            @intCast((@as(u5, last) + 1) % slot_count)
        else
            0;

        var i: u5 = 0;
        while (i < slot_count) : (i += 1) {
            const candidate: u4 = @intCast((start + i) % slot_count);
            if (self.slots[candidate].state == .running) return candidate;
        }
        return null;
    }

    /// Run one instruction in the next runnable slot, round-robin.
    ///
    /// `body` performs the slot's work and returns true if it is still runnable.
    pub fn dispatch(self: *Scheduler, ctx: anytype, body: fn (@TypeOf(ctx), *Slot) bool) ?u4 {
        const index = self.nextRunnable() orelse return null;
        const s = &self.slots[index];
        self.last_dispatched = index;
        self.dispatches += 1;
        const still_running = body(ctx, s);
        s.retired += 1;
        if (!still_running) s.state = .finished;
        return index;
    }

    /// Total instructions retired across every slot.
    pub fn totalRetired(self: *const Scheduler) u64 {
        var n: u64 = 0;
        for (self.slots) |s| n += s.retired;
        return n;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "there are exactly eight thread slots, T0 through T7" {
    var sched = Scheduler.init();
    try testing.expectEqual(@as(usize, 8), slot_count);
    _ = try sched.slot(7);
    try testing.expectError(error.NoSuchSlot, sched.slot(8));
}

test "each slot has a PRIVATE register file" {
    var sched = Scheduler.init();
    const t0 = try sched.slot(0);
    const t1 = try sched.slot(1);

    t0.regs.write(1, 0xAAAA);
    t1.regs.write(1, 0xBBBB);

    // The same architectural register holds different values in different slots.
    try testing.expectEqual(@as(u64, 0xAAAA), t0.regs.read(1));
    try testing.expectEqual(@as(u64, 0xBBBB), t1.regs.read(1));
    try testing.expect(t0.regs.read(1) != t1.regs.read(1));
}

test "spawn, join and slot lifecycle" {
    var sched = Scheduler.init();
    try testing.expectEqual(SlotState.idle, sched.slots[0].state);

    try sched.spawn(0, 0x100);
    try testing.expectEqual(SlotState.running, sched.slots[0].state);
    try testing.expectEqual(@as(u64, 0x100), sched.slots[0].regs.pc);

    // Starting an already-running slot is refused.
    try testing.expectError(error.SlotAlreadyActive, sched.spawn(0, 0x200));

    try sched.join(0);
    try testing.expectEqual(SlotState.finished, sched.slots[0].state);
    // Joining an idle slot is refused.
    try testing.expectError(error.SlotNotActive, sched.join(1));
}

test "interleaving is DETERMINISTIC: two identical runs agree exactly" {
    const Run = struct {
        fn go() [slot_count]u64 {
            var sched = Scheduler.init();
            sched.spawn(0, 0) catch unreachable;
            sched.spawn(2, 0) catch unreachable;
            sched.spawn(5, 0) catch unreachable;

            const Ctx = struct { n: u64 };
            var ctx = Ctx{ .n = 0 };
            const body = struct {
                fn f(c: *Ctx, s: *Slot) bool {
                    c.n += 1;
                    s.regs.write(3, c.n);
                    return c.n < 6; // runs until the shared counter hits 6
                }
            }.f;
            while (sched.dispatch(&ctx, body)) |_| {}

            var out: [slot_count]u64 = @splat(0);
            for (sched.slots, 0..) |s, i| out[i] = s.regs.read(3);
            return out;
        }
    };

    const first = Run.go();
    const second = Run.go();
    try testing.expectEqualSlices(u64, &first, &second);
}

test "round-robin visits slots in ascending order starting from T0" {
    var sched = Scheduler.init();
    try sched.spawn(0, 0);
    try sched.spawn(1, 0);
    try sched.spawn(2, 0);

    try testing.expectEqual(@as(u4, 0), sched.nextRunnable().?);
    sched.last_dispatched = 0;
    try testing.expectEqual(@as(u4, 1), sched.nextRunnable().?);
    sched.last_dispatched = 1;
    try testing.expectEqual(@as(u4, 2), sched.nextRunnable().?);
    // Wraps back to the lowest running slot.
    sched.last_dispatched = 2;
    try testing.expectEqual(@as(u4, 0), sched.nextRunnable().?);
}

test "spawn resets a slot's state rather than inheriting stale registers" {
    var sched = Scheduler.init();
    const t = try sched.slot(3);
    t.regs.write(5, 0xDEAD);
    try sched.spawn(3, 0x40);
    // A fresh thread must not see the previous occupant's registers.
    try testing.expectEqual(@as(u64, 0), sched.slots[3].regs.read(5));
    try testing.expectEqual(@as(u64, 0x40), sched.slots[3].regs.pc);
}

test "MODEL LIMITS: this is interleaving, not parallelism" {
    // Stated in executable form so the module cannot be misread as hardware.
    // There is a single `dispatches` counter advanced one-at-a-time; no slot runs
    // concurrently with any other, and no wall-clock speedup is implied or
    // measurable. The scheduler is a pure function of its own state.
    var sched = Scheduler.init();
    try sched.spawn(0, 0);
    try sched.spawn(1, 0);

    var order: [8]u4 = @splat(0);
    var n: usize = 0;
    while (n < 4) : (n += 1) {
        order[n] = sched.nextRunnable().?;
        sched.last_dispatched = order[n];
    }
    // 0,1,0,1 - a strict alternation, not two threads racing.
    try testing.expectEqual(@as(u4, 0), order[0]);
    try testing.expectEqual(@as(u4, 1), order[1]);
    try testing.expectEqual(@as(u4, 0), order[2]);
    try testing.expectEqual(@as(u4, 1), order[3]);
}
