const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const module = b.createModule(.{
        .root_source_file = b.path("src/kernel.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .red_zone = false,
    });

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = module,
    });

    kernel.setLinkerScript(b.path("linker.ld"));
    b.installArtifact(kernel);
}
