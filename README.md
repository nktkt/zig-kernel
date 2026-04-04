# Zig Kernel

An x86 operating system kernel written from scratch in Zig. Started as a minimal 150-line boot stub, now a 7,500+ LOC system with multitasking, networking, filesystems, and more.

## Quick Start

```bash
zig build
qemu-system-i386 -kernel zig-out/bin/kernel \
  -device e1000,netdev=n0 -netdev user,id=n0 \
  -drive file=disk.img,format=raw,if=ide
```

## Features

### Core
- Multiboot1 boot, GDT (kernel + user segments + TSS), IDT with PIC remapping
- Preemptive round-robin scheduler (1kHz timer interrupt)
- Per-process virtual memory manager, fork/exec/wait/exit
- Signals (SIGKILL, SIGTERM, SIGINT), zombie reaping
- 9 syscalls via INT 0x80 (exit, write, getpid, yield, fork, wait, kill, getppid, sleep)

### Memory
- Bitmap physical memory manager (4KB pages, up to 4GB)
- First-fit heap allocator with block splitting/coalescing
- Identity-mapped paging with PSE (132MB), MMIO mapping support

### Filesystems
- **ramfs**: In-memory inode-based filesystem with directory hierarchy (mkdir, cd, pwd)
- **FAT16**: Read/write support on ATA disk (create, write, delete files)
- **ext2**: Read-only filesystem reader (superblock, inodes, directories)
- **VFS**: Unified file descriptor table (open/read/write/close/stat)

### Networking
- Intel E1000 NIC driver (PCI MMIO, DMA TX/RX descriptor rings)
- ARP (request/reply, cache), IPv4, ICMP echo (ping)
- TCP (3-way handshake, data transfer, FIN close)
- UDP sockets (bind, sendto, recvfrom)
- DNS resolver (A record query via UDP)
- DHCP client (DISCOVER/OFFER/REQUEST/ACK)

### Drivers & Hardware
- PCI bus enumeration
- ATA PIO read/write (LBA28)
- PS/2 keyboard (scancode set 1) and mouse (IRQ12, 3-byte packets)
- PIT timer (1kHz), RTC clock, serial port (COM1 38400 baud)
- VGA text mode with VT100 escape sequences (cursor, colors, erase)
- Framebuffer graphics primitives (pixel, rect, char with 8x16 font)
- USB UHCI controller detection
- Block device abstraction layer

### System
- ACPI table parser (RSDP/RSDT/MADT/FADT), shutdown support
- SMP detection (CPUID, APIC ID, spinlock primitives)
- Multi-user system (root/guest, su, login, UID/GID)
- Pipe IPC (ring buffer)
- POSIX extensions (dup, dup2, lseek, getcwd, chdir)
- ELF32 loader
- CPU exception handlers (ISR 0-19, page fault with CR2)

### Shell (44 commands)
```
help clear mem heap alloc free malloc mfree uptime ticks date paging
ps run ls cat write rm touch cp stat mkdir cd pwd lspci disk dwrite
net ping dns fork kill exec whoami users su pipe tcp
acpi shutdown smp ext2 usb blk reboot
```

## Architecture

```
src/
├── kernel.zig      Entry point, Multiboot header, init sequence
├── gdt.zig         Global Descriptor Table (6 entries)
├── idt.zig         Interrupt Descriptor Table, PIC, ISR stubs
├── isr.zig         CPU exception handler (fault display + halt)
├── pmm.zig         Physical memory manager (bitmap)
├── heap.zig        Kernel heap allocator (first-fit)
├── paging.zig      Page tables, identity mapping, MMIO
├── vmm.zig         Per-process virtual memory manager
├── pit.zig         Programmable Interval Timer (1kHz)
├── rtc.zig         Real-Time Clock (CMOS)
├── serial.zig      COM1 serial debug output
├── vga.zig         VGA text mode + VT100 escape parser
├── keyboard.zig    PS/2 keyboard driver
├── mouse.zig       PS/2 mouse driver
├── tss.zig         Task State Segment (Ring 3→0)
├── task.zig        Process management, scheduler, fork/wait/signals
├── syscall.zig     System call dispatcher (INT 0x80)
├── elf.zig         ELF32 loader
├── ramfs.zig       In-memory filesystem (inode + directories)
├── fat16.zig       FAT16 filesystem (read/write)
├── ext2.zig        ext2 filesystem (read-only)
├── vfs.zig         Virtual filesystem layer
├── pipe.zig        Pipe IPC
├── pci.zig         PCI bus enumeration
├── ata.zig         ATA PIO disk driver
├── blkdev.zig      Block device abstraction
├── e1000.zig       Intel E1000 NIC driver
├── net.zig         Network stack (Ethernet/ARP/IPv4/ICMP)
├── tcp.zig         TCP implementation
├── udp.zig         UDP sockets
├── dns.zig         DNS resolver
├── dhcp.zig        DHCP client
├── acpi.zig        ACPI table parser
├── smp.zig         SMP detection, spinlocks
├── uhci.zig        USB UHCI controller
├── framebuf.zig    Framebuffer graphics
├── posix.zig       POSIX extensions
├── user.zig        Multi-user management
└── shell.zig       Interactive shell (44 commands)

build.zig           Build config (x86 freestanding, SSE/AVX disabled)
linker.ld           Linker script (1MB base, 16KB stack)
ROADMAP.md          Development roadmap to Linux-scale OS
```

## Prerequisites

- [Zig](https://ziglang.org/) 0.15+
- [QEMU](https://www.qemu.org/) (`qemu-system-i386`)
- Optional: `mtools` for creating FAT16 disk images

## Version History

| Version | LOC | Highlights |
|---------|-----|-----------|
| v0.1 | 150 | Boot + VGA text |
| v0.2 | 518 | GDT, IDT, keyboard, PMM |
| v0.3 | 964 | Shell, timer, heap |
| v0.4 | 1,220 | Paging, serial, RTC |
| v0.5 | 1,719 | User space, TSS, syscalls, multitasking |
| v0.6 | 3,236 | PCI, ATA, FAT16, E1000 NIC, ARP/IPv4/ICMP |
| v0.7 | 4,724 | VFS, pipes, TCP/UDP, multi-user, ELF loader |
| v0.8 | 5,218 | fork/wait/signals, VMM, full ISR |
| v0.9 | 5,647 | Hierarchical FS, VT100 console |
| **v1.0** | **7,582** | **ACPI, SMP, mouse, DNS, DHCP, ext2, USB, framebuffer** |

See [ROADMAP.md](ROADMAP.md) for the path from here to Linux-scale.

## License

MIT
