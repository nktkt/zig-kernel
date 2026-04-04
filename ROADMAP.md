# Zig Kernel Roadmap

A step-by-step roadmap for growing an x86 kernel written in Zig toward a Linux-scale operating system.
Each milestone builds on the previous one.

## Current State

- **v1.0** — 7,582 LOC / 34 source files
- Level: Hobby OS (Milestone 2 complete)

---

## Milestone 1: xv6-grade ✅ COMPLETE (v0.9, 5,647 LOC)

**Goal**: A UNIX-like kernel with fork/exec, process isolation, hierarchical filesystem, and signals.

### 1-1. Per-process page tables ✅
- [x] Per-process page directory (vmm.zig)
- [x] Kernel/user space mapping API (`map_page`, `unmap_page`)
- [x] Address space create/clone/free
- [x] CR3 switching support

### 1-2. fork ✅
- [x] Process duplication (kernel + user stack copy)
- [x] Child returns 0, parent returns child PID
- [x] PPID tracking, process tree
- [x] SYS_FORK syscall

### 1-3. exec ✅
- [x] ELF32 parser and loader (elf.zig)
- [x] Load from ramfs, create user task
- [x] Program header (PT_LOAD) handling

### 1-4. wait / exit / signals ✅
- [x] SYS_WAIT (reap zombie children, collect exit code)
- [x] Orphan reparenting to init (pid=0)
- [x] Signals: SIGKILL, SIGTERM, SIGINT
- [x] Zombie state, parent wakeup on child exit
- [x] `kill` shell command

### 1-5. Hierarchical filesystem ✅
- [x] Inode-based ramfs with directory support
- [x] mkdir, cd, pwd commands
- [x] Path resolution (`/dir/subdir/file`, `.`, `..`)
- [x] `ls` shows file type (file/dir) with color

### 1-6. VT100 console ✅
- [x] Escape sequence parser (ESC [ params cmd)
- [x] Cursor movement (CSI A/B/C/D/H)
- [x] Erase display/line (CSI J/K)
- [x] SGR colors (CSI m, ANSI 30-37, 40-47, 90-97, bold)
- [x] Tab, carriage return handling

### 1-7. Complete exception handlers ✅
- [x] ISR 0-19 fully registered (all defined CPU exceptions)
- [x] Page fault shows CR2 address
- [x] Error code display
- [x] System halt on fatal exception

### 1-8. init process ✅
- [x] Kernel directly starts shell (simplified init)
- [x] Shell prompt: `root@zig-os:/path#`

### 1-9. Test infrastructure ✅
- [x] QEMU automated test scripts with QMP
- [x] Screenshot capture and verification
- [x] Serial output logging

### Previously completed (v0.5-v0.7)
- [x] Preemptive round-robin scheduler with timer interrupt
- [x] INT 0x80 syscalls (exit, write, getpid, yield, sleep, fork, wait, kill, getppid)
- [x] PCI bus enumeration (pci.zig)
- [x] ATA PIO read/write driver (ata.zig)
- [x] FAT16 read/write filesystem (fat16.zig)
- [x] Intel E1000 NIC driver (e1000.zig)
- [x] Network stack: Ethernet, ARP, IPv4, ICMP ping, TCP, UDP (net.zig, tcp.zig, udp.zig)
- [x] RAM filesystem with inode hierarchy (ramfs.zig)
- [x] VFS with file descriptors (vfs.zig)
- [x] Pipe IPC with ring buffer (pipe.zig)
- [x] Multi-user system: root/guest, su, login (user.zig)
- [x] ELF32 loader (elf.zig)
- [x] 44 shell commands

---

## Milestone 2: Hobby OS ✅ COMPLETE (v1.0, 7,582 LOC)

**Goal**: GUI foundations, full TCP, USB detection, DNS/DHCP, ext2, POSIX extensions.

### 2-1. x86_64 preparation ✅
- [x] CPUID feature detection (smp.zig)
- [ ] Long mode transition (future: requires full kernel rewrite)
- [ ] 64-bit page tables, syscall/sysret

### 2-2. SMP basics ✅
- [x] BSP APIC ID detection via CPUID
- [x] CPU count from ACPI MADT
- [x] SpinLock primitives (lock xchg atomic operations)
- [ ] AP startup (future: INIT-SIPI-SIPI)
- [ ] Per-CPU run queues

### 2-3. ACPI basics ✅
- [x] RSDP / RSDT / MADT / FADT parser (acpi.zig)
- [x] CPU count and APIC address extraction
- [x] ACPI shutdown support (PM1a_CNT)
- [x] `acpi` and `shutdown` shell commands

### 2-4. Framebuffer + GUI ✅
- [x] Framebuffer graphics library (framebuf.zig): putPixel, drawRect, fillRect, drawChar, drawString
- [x] Built-in 8x16 bitmap font (ASCII 32-126)
- [x] 16/24/32 bpp support
- [x] PS/2 mouse driver with IRQ12 (mouse.zig)
- [x] Absolute position tracking (640x480)
- [ ] Window manager (future)

### 2-5. TCP implementation ✅
- [x] 3-way handshake (SYN → SYN-ACK → ACK)
- [x] Data send/receive with PSH/ACK
- [x] FIN close (FIN_WAIT, CLOSE_WAIT, LAST_ACK)
- [x] `tcp` shell command (connect + HTTP GET)
- [ ] Sliding window, retransmission, congestion control (future)

### 2-6. DNS + DHCP ✅
- [x] DNS resolver: A record query/response via UDP (dns.zig)
- [x] Compression pointer support in DNS responses
- [x] DHCP client: DISCOVER/OFFER/REQUEST/ACK (dhcp.zig)
- [x] DhcpLease struct (IP, gateway, netmask, DNS)
- [x] `dns` shell command

### 2-7. ext2 filesystem ✅
- [x] Superblock parsing (ext2.zig)
- [x] Block group descriptor table
- [x] Inode reading (direct + single indirect blocks)
- [x] Directory listing
- [x] File data reading
- [x] `ext2` shell command

### 2-8. Block device layer ✅
- [x] Generic BlockDev struct with read/write function pointers (blkdev.zig)
- [x] ATA registered as block device
- [x] `blk` shell command

### 2-9. USB ✅
- [x] UHCI controller detection via PCI scan (uhci.zig)
- [x] BAR4 I/O base reading
- [x] Controller reset
- [x] `usb` shell command
- [ ] USB device enumeration, HID, Mass Storage (future)

### 2-10. POSIX extensions ✅
- [x] dup, dup2 (file descriptor duplication) (posix.zig)
- [x] lseek (file seek)
- [x] getcwd, chdir (working directory)
- [ ] select/poll, shared memory, semaphores, TTY/PTY (future)

### 2-11. Userspace tools ✅
- [x] 44 shell commands (7 new: acpi, shutdown, smp, dns, ext2, usb, blk)
- [x] Shell with argument parsing, cwd-aware prompt
- [ ] libc subset, coreutils, text editor (future)

**Status**: Core subsystems implemented. Advanced features (window manager, full TCP congestion control, USB enumeration, libc) marked for future milestones.

---

## Milestone 3: MINIX-grade — ~100,000 LOC

**Goal**: Partial POSIX compatibility. Some existing C programs can be compiled and run natively.

- [ ] 100+ POSIX syscalls (open, read, write, close, fork, exec, wait, pipe, dup2, stat, lseek, mmap, munmap, ioctl, socket, bind, listen, accept, connect, send, recv, select, poll, kill, signal, sigaction, getpid, getppid, getcwd, chdir, mkdir, rmdir, unlink, link, rename, chmod, chown, ...)
- [ ] mmap / demand paging / disk swap
- [ ] ext3 journaling (ordered mode)
- [ ] IPv6 dual stack
- [ ] AHCI (SATA) driver
- [ ] NVMe driver
- [ ] Dynamic linker (ld.so equivalent, ELF shared objects)
- [ ] /proc filesystem
- [ ] /dev filesystem (device nodes)
- [ ] Full network sockets (listen/accept/connect/shutdown)
- [ ] Process groups, sessions, job control (fg, bg, jobs)
- [ ] Port newlib or musl libc
- [ ] Port Lua or MicroPython (verify language runtime works)

**Done when**: musl libc + busybox run, basic POSIX test suite passes

---

## Milestone 4: Production OS — ~500,000 LOC

**Goal**: An OS real users can use. Browser, file manager, package manager. Self-hosting.

- [ ] Driver ecosystem: 10+ NIC types (Realtek, Intel, Broadcom), GPU (VESA/bochs-vga/virtio-gpu), HDA audio, xHCI (USB 3.0), NVMe, virtio (net/blk/console)
- [ ] Filesystem support: FAT32, ext4, tmpfs, devfs, sysfs, procfs
- [ ] Full networking: netfilter/iptables equivalent, NAT, bonding, VLAN, WiFi (802.11)
- [ ] Security: capabilities, seccomp, namespaces (mount/PID/net)
- [ ] GUI toolkit (widgets: button, textbox, list, menu, dialog)
- [ ] Window manager (taskbar, workspaces, themes)
- [ ] Apps: file manager, text editor, terminal, image viewer
- [ ] Package manager (build system, dependency resolution)
- [ ] Self-hosting (build the OS on itself)
- [ ] Full POSIX compliance test suite

**Done when**: Self-hosting is possible and a web browser runs

---

## Milestone 5: Linux-grade — ~36,000,000 LOC

**Goal**: Production-ready. Any hardware, any workload.

- [ ] Architecture support: x86_64, ARM64, RISC-V, ...
- [ ] Device drivers: thousands (all categories)
- [ ] Containers: cgroup v2, full namespace support
- [ ] Virtualization: KVM equivalent (VMX/SVM)
- [ ] Filesystems: ext4, btrfs, xfs, nfs, ceph, ...
- [ ] Networking: all protocols, XDP/eBPF
- [ ] Security: SELinux, AppArmor, crypto API, key management
- [ ] Real-time: PREEMPT_RT
- [ ] Power management: full ACPI, suspend/hibernate
- [ ] Performance: perf, ftrace, eBPF

---

## Version History

| Version | LOC | Milestone | Key Features |
|---------|-----|-----------|-------------|
| v0.1 | 150 | — | Minimal boot + VGA text output |
| v0.2 | 518 | — | GDT, IDT, keyboard, PMM |
| v0.3 | 964 | — | Shell, PIT timer, heap allocator |
| v0.4 | 1,220 | — | Paging, serial debug, RTC clock |
| v0.5 | 1,719 | — | User space, TSS, syscalls, multitasking |
| v0.6 | 3,236 | — | PCI, ATA, FAT16, E1000 NIC, ARP/IPv4/ICMP |
| v0.7 | 4,724 | — | VFS, pipes, TCP/UDP, multi-user, ELF loader |
| v0.8 | 5,218 | — | fork/wait/signals, VMM, full ISR |
| v0.9 | 5,647 | **MS1** ✅ | Hierarchical FS, VT100 console, cwd prompt |
| **v1.0** | **7,582** | **MS2** ✅ | ACPI, SMP, mouse, DNS, DHCP, ext2, USB, framebuffer |

---

## References

### Books
- "Operating Systems: Three Easy Pieces" (OSTEP) — free online
- "Operating System Concepts" (Silberschatz) — classic textbook
- "Linux Kernel Development" (Robert Love) — Linux internals
- "Understanding the Linux Kernel" (Bovet & Cesati) — detailed reference

### Source Code
- [xv6](https://github.com/mit-pdos/xv6-public) — MIT teaching OS (~10K LOC)
- [SerenityOS](https://github.com/SerenityOS/serenity) — C++ hobby OS (~1M LOC)
- [MINIX 3](https://github.com/Stichting-MINIX-Research-Foundation/minix) — microkernel
- [Linux](https://github.com/torvalds/linux) — the target

### OSDev
- [OSDev Wiki](https://wiki.osdev.org/) — OS development encyclopedia
- [OSDev Forum](https://forum.osdev.org/) — Q&A

### Specifications
- Intel SDM (Software Developer's Manual) — x86 architecture
- ACPI Specification — power management
- USB 2.0/3.0 Specification — USB
- ext2/ext4 disk layout — filesystems
- RFC 793 (TCP), 791 (IP), 768 (UDP) — networking
