const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        // カーネル空間では SSE/AVX/x87 を無効化 (soft float)
        .cpu_features_add = std.Target.x86.featureSet(&.{.soft_float}),
        .cpu_features_sub = std.Target.x86.featureSet(&.{ .sse, .sse2, .avx, .x87 }),
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

    // Install the ELF64 binary
    b.installArtifact(kernel);

    // Convert ELF64 to ELF32-i386 for QEMU multiboot1 compatibility
    // QEMU's -kernel flag expects a 32-bit ELF for multiboot1 boot protocol
    const objcopy_cmd = b.addSystemCommand(&.{
        "llvm-objcopy",
        "--output-target=elf32-i386",
    });
    objcopy_cmd.addArtifactArg(kernel);
    const kernel32 = objcopy_cmd.addOutputFileArg("kernel32");
    const install_kernel32 = b.addInstallBinFile(kernel32, "kernel32");
    b.getInstallStep().dependOn(&install_kernel32.step);
}
