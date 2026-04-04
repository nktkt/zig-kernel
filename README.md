# zig-kernel

A minimal x86 kernel written in Zig (~150 LOC). Boots via Multiboot, outputs colored text to VGA, and halts.

![Kernel Screenshot](/docs/screenshot.png)

## Structure

```
├── build.zig        # Zig build configuration (freestanding x86 target)
├── linker.ld        # Linker script (memory layout, stack allocation)
└── src/
    ├── kernel.zig   # Entry point, Multiboot header, kmain
    └── vga.zig      # VGA text mode driver (80x25, 16 colors, scrolling)
```

## Prerequisites

- [Zig](https://ziglang.org/) 0.15+
- [QEMU](https://www.qemu.org/) (`qemu-system-i386`)

## Build & Run

```bash
zig build
qemu-system-i386 -kernel zig-out/bin/kernel
```

## Features

- Multiboot1-compliant header (recognized by QEMU and GRUB)
- VGA text mode output with 16-color support
- Screen scrolling
- 16KB kernel stack defined via linker script
- No libc, no OS dependencies — fully freestanding

## License

MIT
