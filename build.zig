const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // everything under src/ lives in ONE module graph. Zig 0.17.1 rejects a file
    // that belongs to two modules, and src files import each other by relative
    // path (e.g. assembler.zig -> registers.zig), so a second module over src/
    // would put registers.zig in both. The suite reaches this graph by importing
    // it under the name "vm", which is what tests/vm_tests.zig expects.
    const src_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // A second handle on the SAME module, rooted at vm.zig, for the suite. It is
    // the same graph, so no file lands in two modules.
    const vm_mod = b.createModule(.{
        .root_source_file = b.path("src/vm.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{ .name = "celeris64", .root_module = src_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    b.step("run", "Run the Celeris-64 CLI").dependOn(&run_cmd.step);

    // The VM core's own inline tests.
    const vm_tests = b.addTest(.{ .root_module = vm_mod });

    // The independent verifier suite. It imports src/ as the module named "vm".
    const suite_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/vm_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    suite_tests.root_module.addImport("vm", vm_mod);

    // Tooling's files get their own root so their inline tests run even while the
    // VM graph is mid-flight. assembler.zig pulls in diagnostics.zig and
    // registers.zig, so this root covers those too.
    const tooling_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/assembler.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // disassembler.zig is NOT reachable from assembler.zig, so its tests need an
    // explicit root. Without this root the suite reported 260 passing while all
    // 56 disassembler tests — including every accelerator round-trip check — never
    // ran. A green suite that skips the tests for the feature under test is the
    // exact vacuous-green failure this project keeps hitting.
    const disassembler_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/disassembler.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // The dedicated hardware primitives get their own root. They import only
    // memory.zig, so this root keeps their inline tests running (including the
    // stream atomicity checks) independently of the VM graph.
    const primitives_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stream.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const field_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/field.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const select_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/select.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const decoder_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/decoder.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Phase 3 benchmarks drive the VM, so they need the src graph by module name
    // (Zig refuses to import outside a module root).
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("vm", vm_mod);
    const bench_tests = b.addTest(.{ .root_module = bench_mod });

    // The benchmark is also runnable, so its numbers can be read directly.
    const bench_exe = b.addExecutable(.{ .name = "celeris64-bench", .root_module = bench_mod });
    b.installArtifact(bench_exe);
    // Phase 3 native standard-library modules. Each is standalone, so one root
    // per module keeps their inline tests in the official suite.
    const stdlib_roots = [_][]const u8{
        "src/stdlib_ui.zig",
        "src/stdlib_gfx.zig",
        "src/stdlib_net.zig",
        "src/capability.zig",
        "src/thread.zig",
        "src/matrix.zig",
        "src/fft.zig",
        "src/codec.zig",
    };
    const bench_run = b.addRunArtifact(bench_exe);
    b.step("bench", "Run the simulator instruction-count benchmark").dependOn(&bench_run.step);

    // The independent verifier's adversarial suite (task-22). It is a SEPARATE root
    // rather than inline tests because `verifier` owns tests/ and must not write
    // src/. Its 24 tests were passing standalone for a full session while being
    // invisible to `zig build test` -- the same "a green suite nobody runs" failure
    // this project already hit when the disassembler's 56 tests were unreachable.
    // It embeds a RECORDED fact table, so it is a snapshot; tools/v22_live_check.sh
    // is what re-derives those facts from the current binary and catches drift.
    const verifier_mod = b.createModule(.{
        .root_source_file = b.path("tests/v22_cap_thread.zig"),
        .target = target,
        .optimize = optimize,
    });
    verifier_mod.addImport("vm", vm_mod);
    const verifier_tests = b.addTest(.{ .root_module = verifier_mod });

    // Reserved-field audit (tools/audit-reserved.sh): greps the decoder for an
    // enforcement point per declared reservation, then FALSIFIES by setting each
    // reserved field explicitly and requiring rejection. Kept as its own step rather
    // than folded into `test` because it runs the installed CLI, and a step that
    // silently no-ops when the binary is absent is worse than one you must ask for.
    // This defect class recurred twice (F6, and the v1.9 amendments), so it is
    // checked mechanically now rather than by prose reminder.
    const audit_cmd = b.addSystemCommand(&.{ "bash", "tools/audit-reserved.sh" });
    audit_cmd.step.dependOn(b.getInstallStep());
    b.step("audit", "Audit every reserved field the contract declares is rejected").dependOn(&audit_cmd.step);

    // Snapshot-drift check (tools/v22_live_check.sh): the verifier's suite embeds a
    // RECORDED table of the words the CLI produced. A recording cannot notice that the
    // binary changed afterwards -- the suite's author proved this by injecting the
    // pre-F14 regression and watching all 24 tests still pass. This step re-derives
    // every fact from the CURRENT binary and diffs it against the recording, so a
    // stale snapshot fails loudly instead of staying green. Separate from `test`
    // because it drives the installed CLI, and it refuses to pass when the binary is
    // missing rather than silently skipping.
    const live_cmd = b.addSystemCommand(&.{ "bash", "tools/v22_live_check.sh" });
    live_cmd.step.dependOn(b.getInstallStep());
    b.step("live-check", "Re-derive the verifier's recorded facts from the current binary").dependOn(&live_cmd.step);

    // RTL synthesis (tools/rtl-synth.sh): lowers the SystemVerilog to Verilog-2005
    // with sv2v, then synthesizes with Yosys and prints cell counts. Verilator
    // lints but never synthesizes, so this is the only step that turns the RTL into
    // gates. It reports NO timing and establishes NO clock frequency -- the script
    // repeats that on every run.
    //
    // Separate from `test` because it needs sv2v and Yosys installed under ~/.local,
    // which not every checkout has. It exits non-zero when either tool is missing
    // rather than skipping quietly: a synthesis step that silently no-ops would let
    // "the RTL has never been synthesized" stay true while `zig build synth` looked
    // green.
    const synth_cmd = b.addSystemCommand(&.{ "bash", "tools/rtl-synth.sh", "all" });
    b.step("synth", "Synthesize the RTL and report cell counts (no timing)").dependOn(&synth_cmd.step);

    const test_step = b.step("test", "Run the Celeris-64 test suite");
    test_step.dependOn(&b.addRunArtifact(vm_tests).step);
    test_step.dependOn(&b.addRunArtifact(suite_tests).step);
    test_step.dependOn(&b.addRunArtifact(tooling_tests).step);
    test_step.dependOn(&b.addRunArtifact(disassembler_tests).step);
    test_step.dependOn(&b.addRunArtifact(primitives_tests).step);
    test_step.dependOn(&b.addRunArtifact(field_tests).step);
    test_step.dependOn(&b.addRunArtifact(select_tests).step);
    test_step.dependOn(&b.addRunArtifact(decoder_tests).step);
    test_step.dependOn(&b.addRunArtifact(bench_tests).step);
    test_step.dependOn(&b.addRunArtifact(verifier_tests).step);

    for (stdlib_roots) |root| {
        const m = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }
}
