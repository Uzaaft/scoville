const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const log_level = b.option(
        std.log.Level,
        "log_level",
        "Log verbosity (err, warn, info, debug; default: info)",
    ) orelse .info;

    // Build options module shared by library and executable
    const options = b.addOptions();
    options.addOption(std.log.Level, "log_level", log_level);

    // Generate primary-selection protocol header and C source via wayland-scanner
    const wl_generate_header = b.addSystemCommand(&.{
        "wayland-scanner", "client-header",
    });
    wl_generate_header.addFileArg(b.path("protocols/primary-selection-unstable-v1.xml"));
    const primary_sel_header = wl_generate_header.addOutputFileArg("primary-selection-unstable-v1-client-protocol.h");

    const wl_generate_code = b.addSystemCommand(&.{
        "wayland-scanner", "private-code",
    });
    wl_generate_code.addFileArg(b.path("protocols/primary-selection-unstable-v1.xml"));
    const primary_sel_code = wl_generate_code.addOutputFileArg("primary-selection-unstable-v1-protocol.c");

    // Translate the C header into a Zig module (replaces @cImport)
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/wayland/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(primary_sel_header.dirname());
    translate_c.linkSystemLibrary("wayland-client", .{});

    const options_mod = options.createModule();

    // Library module
    const lib_mod = b.addModule("scoville", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = translate_c.createModule() },
            .{ .name = "build_options", .module = options_mod },
        },
    });

    // Compile the generated protocol glue C code
    lib_mod.addCSourceFile(.{
        .file = primary_sel_code,
    });

    // Link wayland-client and libc
    lib_mod.linkSystemLibrary("wayland-client", .{});
    lib_mod.link_libc = true;

    // Static library artifact
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "scoville",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // Executable
    const exe_mod = b.addModule("scoville-exe", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = translate_c.createModule() },
            .{ .name = "build_options", .module = options_mod },
        },
    });
    exe_mod.addCSourceFile(.{ .file = primary_sel_code });
    exe_mod.linkSystemLibrary("wayland-client", .{});
    exe_mod.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "scoville",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Tests
    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Format
    const fmt = b.addFmt(.{
        .paths = &.{"src"},
    });
    const fmt_step = b.step("fmt", "Format source files");
    fmt_step.dependOn(&fmt.step);
}
