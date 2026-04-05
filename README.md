# Zig Kernel

An x86 operating system kernel written from scratch in Zig. 50,000+ LOC across 136 source files with 110+ subsystems — from boot to GUI, networking, filesystems, and a shell with 80+ commands.

Started as 150 lines. Now a hobby OS.

## Quick Start

```bash
zig build
qemu-system-i386 -kernel zig-out/bin/kernel \
  -device e1000,netdev=n0 -netdev user,id=n0 \
  -drive file=disk.img,format=raw,if=ide
```

## What Works (verified in QEMU)

- **Boot** → 20+ subsystems initialize OK
- **`ping 10.0.2.2`** → `Reply from 10.0.2.2: time=1ms`
- **`fork`** → Parent/child process creation, wait, exit code 42
- **`gui`** → VGA Mode 13h graphics with colored rectangles and text
- **`mkdir test && cd test && write hello.txt hi && cat hello.txt`** → Hierarchical filesystem
- **`su guest`** → `guest@zig-os:/$` → `su root` → `root@zig-os:/#`
- **`Ctrl+C`** → SIGINT to running processes
- **`sysinfo`** → neofetch-style system overview
- **FAT16 disk** → `dwrite file.txt content` writes to real disk

## Features

### Core (v0.1–v0.5)
- Multiboot1 boot, GDT, IDT, PIC, TSS
- Preemptive round-robin scheduler (1kHz PIT)
- fork/exec/wait/exit with zombie reaping
- Signals: SIGKILL, SIGTERM, SIGINT (Ctrl+C)
- 9 syscalls via INT 0x80
- Per-process page directory (CR3 switching)

### Memory
- Bitmap PMM (4KB pages, 4GB addressable)
- First-fit heap, slab allocator (6 caches), buddy allocator (7 orders)
- Pool allocator (8 fixed sizes), LRU cache
- Virtual memory areas (VMA) per process

### Filesystems
- **ramfs** — Inode-based with directory hierarchy
- **FAT16** — Read/write on ATA disk
- **FAT32** — Read-only with LFN support
- **ext2** — Read/write with bitmap allocation
- **tmpfs** — PMM-backed temporary filesystem
- **devfs** — /dev/null, zero, random, console, serial, mem
- **procfs** — /proc/version, meminfo, cpuinfo, mounts
- VFS layer, mount points, Unix permissions, path utilities

### Networking
- Intel E1000 NIC driver (PCI MMIO, DMA)
- Ethernet frames, VLAN (802.1Q)
- ARP (cache with aging), IPv4 (fragmentation/reassembly), IPv6 basics
- ICMP ping, TCP (retransmit, congestion control, TIME_WAIT)
- UDP sockets, BSD socket API (16 sockets)
- DNS, DHCP, NTP, TFTP, HTTP/1.0, Telnet
- Firewall (32 rules), routing table (16 entries), network stats

### GUI
- VGA Mode 13h (320x200, 256 colors)
- Canvas: line, circle, ellipse, triangle, bezier, flood fill
- Window manager: 8 windows, z-order compositing, title bars
- Widgets: label, button, checkbox, progress bar, text input
- Event queue, 3 visual themes, VGA palette programming
- 8x16 + 8x8 bitmap fonts with bold/outline rendering
- 4 virtual consoles with scrollback

### Drivers
- PCI enumeration + device database (50+ devices)
- ATA PIO (LBA28) + MBR partition parsing
- PS/2 keyboard (shift, Ctrl, arrow keys, F1-F3)
- PS/2 mouse (IRQ12, position tracking)
- VGA text (VT100 escape sequences) + framebuffer
- Serial (COM1, 38400 baud)
- USB UHCI + VirtIO detection

### Process Management
- CFS-like scheduler (vruntime, nice values -20..19)
- Kernel threads, semaphores, read-write locks, futex
- Message queues, shared memory, event flags
- Process capabilities (12 Linux-style caps)
- 32 POSIX signals with handler registration
- Pseudo-terminals (4 PTY pairs)

### Security
- Multi-user: root/guest, su, login, UID/GID
- File permissions (rwxrwxrwx + setuid/setgid/sticky)
- Process capabilities (CAP_SYS_ADMIN, CAP_NET_RAW, etc.)
- Packet filter firewall

### Libraries
- String (strlen, strcmp, atoi, itoa, contains)
- Math (sqrt, pow, gcd, prime, fixed-point, sine table)
- Regex (NFA, char classes, quantifiers)
- JSON parser, Base64, UTF-8, CRC32/FNV-1a
- RLE + LZ77 compression, color manipulation
- Sorting (6 algorithms), binary search
- Ring buffer, bitmap, linked list, priority queue, hash table, memory pool

### Applications
- **Shell** — 80+ commands, history (↑↓), aliases, tab completion, scripting
- **Editor** — ed-like (insert, delete, substitute, save/load)
- **Games** — Number guessing + snake
- **Benchmarks** — 8 kernel benchmarks with timing
- **Init scripts** — Boot automation

### Debug & Profiling
- Panic with BSOD + register dump + stack trace
- ISR 0-19 with page fault details (read/write/user/kernel)
- Kernel symbol table with address resolution
- Function profiler + PC sampling histogram
- Watchdog timer, kernel logging (5 levels)
- In-kernel test suite (8 tests)

## Architecture

```
136 source files, 50,001 LOC

src/
├── Boot & Core         kernel.zig, gdt.zig, idt.zig, tss.zig, init.zig
├── Memory              pmm.zig, heap.zig, slab.zig, buddy.zig, pool_alloc.zig,
│                       paging.zig, vmm.zig, vma.zig, mmu.zig, cache.zig
├── Process             task.zig, scheduler_rr.zig, scheduler_cfs.zig,
│                       kthread.zig, signal_handler.zig, workqueue.zig
├── Syscall             syscall.zig, syscall_table.zig, posix.zig, errno.zig, ioctl.zig
├── Filesystem          ramfs.zig, fat16.zig, fat32.zig, ext2.zig, tmpfs.zig,
│                       devfs.zig, procfs.zig, vfs.zig, mount.zig, path.zig, permission.zig
├── Networking          e1000.zig, net.zig, ethernet.zig, ip.zig, ipv6.zig,
│                       tcp.zig, udp.zig, icmp.zig, arp_cache.zig,
│                       dns.zig, dhcp.zig, ntp.zig, tftp.zig, http.zig, telnet.zig,
│                       socket_api.zig, firewall.zig, routing.zig, net_util.zig, netstat.zig
├── Drivers             pci.zig, pci_db.zig, ata.zig, blkdev.zig, disk_util.zig,
│                       keyboard.zig, mouse.zig, serial.zig, uhci.zig, virtio.zig
├── Display             vga.zig, framebuf.zig, canvas.zig, font.zig,
│                       window.zig, widget.zig, event.zig, theme.zig, vt.zig
├── IPC & Sync          pipe.zig, pty.zig, ipc.zig, semaphore.zig, rwlock.zig,
│                       futex.zig, kobject.zig
├── Security            user.zig, capability.zig, acpi.zig, smp.zig, power.zig
├── Libraries           string.zig, math.zig, fmt.zig, regex.zig, json.zig,
│                       base64.zig, utf8.zig, compress.zig, crypto.zig, color.zig,
│                       sort.zig, ringbuf.zig, bitmap.zig, list.zig, queue.zig,
│                       hashtable.zig, mempool.zig
├── Applications        shell.zig, shell_ext.zig, editor.zig, game.zig, ksh.zig,
│                       coreutils.zig, bench.zig, init_script.zig
├── Debug               isr.zig, panic_screen.zig, debug.zig, profiler.zig,
│                       watchdog.zig, ksym.zig, log.zig, test_suite.zig
└── Config              env.zig, config.zig, sysctl.zig, version.zig,
                        timer.zig, time.zig, cmos.zig, rtc.zig,
                        elf.zig, elf_parser.zig, tar.zig, archive.zig

build.zig              Zig build config (x86 freestanding, SSE/AVX disabled)
linker.ld              Linker script (1MB base, 16KB stack)
ROADMAP.md             5-milestone roadmap to Linux-scale
```

## Prerequisites

- [Zig](https://ziglang.org/) 0.15+
- [QEMU](https://www.qemu.org/) (`qemu-system-i386`)
- Optional: `mtools` for FAT16 disk images

## Version History

| Version | LOC | Highlights |
|---------|-----|-----------|
| v0.1 | 150 | Boot + VGA |
| v0.2 | 518 | GDT, IDT, keyboard, PMM |
| v0.3 | 964 | Shell, timer, heap |
| v0.4 | 1,220 | Paging, serial, RTC |
| v0.5 | 1,719 | User space, syscalls, multitasking |
| v0.6 | 3,236 | PCI, ATA, FAT16, E1000, networking |
| v0.7 | 4,724 | VFS, TCP/UDP, multi-user, ELF |
| v0.8 | 5,218 | fork/wait/signals, VMM |
| v0.9 | 5,647 | Hierarchical FS, VT100 |
| v1.0 | 7,582 | ACPI, SMP, DNS, DHCP, ext2, USB |
| v1.1 | 10,391 | Command history, env vars, sysinfo |
| v1.2 | 30,001 | GUI, canvas, CFS, 25 new modules |
| **v1.3** | **50,001** | **BSD sockets, firewall, IPC, profiler, 110+ subsystems** |

See [ROADMAP.md](ROADMAP.md) for the path to Linux-scale (MS3: 100K, MS4: 500K, MS5: 36M).

## License

MIT
