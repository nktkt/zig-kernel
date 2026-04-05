# Zig Kernel Roadmap

A step-by-step roadmap for growing an x86 kernel written in Zig toward a Linux-scale operating system.
Each milestone builds on the previous one.

## Current State

- **v1.1** — 10,391 LOC / 46 source files / 56 shell commands
- Level: xv6-grade reached (MS1 ~90%), MS2 foundations (~10%)

---

## Milestone 1: xv6-grade — ~10,000 LOC (REACHED — ~90%)

**Goal**: A UNIX-like kernel with fork/exec, process isolation, hierarchical filesystem, and signals.

**Completion criteria**: `fork` spawns a shell, and `ls`/`cat` run as child processes.

### 1-1. Per-process page tables (~800 LOC) — ⚠️ INFRA DONE
- [x] vmm.zig: createAddressSpace, cloneAddressSpace, freeAddressSpace, mapUserPage, unmapUserPage
- [x] timerSchedule switches CR3 when page_dir differs between tasks
- [x] All tasks initialized with kernel PD (identity mapped)
- [ ] Allocate separate user pages per process (all share kernel PD currently)
- Ref: xv6 `vm.c`

### 1-2. fork (~600 LOC) — ⚠️ PARTIAL (stack copy works, no address space isolation)
- [x] Process duplication (kernel + user stack copy)
- [x] Child returns 0, parent returns child PID
- [x] PPID tracking, process tree
- [x] SYS_FORK syscall
- [ ] **Fork does not create separate address space (depends on 1-1)**
- [ ] Copy-on-Write (CoW) with page fault handler
- Ref: xv6 `proc.c:fork()`

### 1-3. exec (~400 LOC) — ⚠️ PARTIAL (ELF parser exists, no independent address space)
- [x] ELF32 parser and loader (elf.zig)
- [x] Load from ramfs, create user task
- [x] Program header (PT_LOAD) handling
- [ ] **Load ELF into independent address space (depends on 1-1)**
- [ ] Rebuild user stack (argc, argv)
- [ ] Release old address space on exec
- Ref: xv6 `exec.c`

### 1-4. wait / exit / signals (~500 LOC) — ✅ COMPLETE
- [x] SYS_WAIT (reap zombie children, collect exit code)
- [x] Orphan reparenting to init (pid=0)
- [x] Signals: SIGKILL, SIGTERM, SIGINT
- [x] Zombie state, parent wakeup on child exit
- [x] `kill` shell command
- [x] Ctrl+C → SIGINT (keyboard driver detects modifier keys)
- Ref: xv6 `proc.c:wait()`, `kill()`

### 1-5. Hierarchical filesystem (~800 LOC) — ✅ COMPLETE
- [x] Inode-based ramfs with directory support
- [x] mkdir, cd, pwd commands
- [x] Path resolution (`/dir/subdir/file`, `.`, `..`)
- [x] `ls` shows file type (file/dir) with color

### 1-6. VT100 console (~500 LOC) — ✅ MOSTLY COMPLETE
- [x] Escape sequence parser (ESC [ params cmd)
- [x] Cursor movement (CSI A/B/C/D/H)
- [x] Erase display/line (CSI J/K)
- [x] SGR colors (CSI m, ANSI 30-37, 40-47, 90-97, bold)
- [x] Tab, carriage return handling
- [x] Ctrl+C (SIGINT), Ctrl+D (EOT), Ctrl+L (clear)
- [ ] Line buffering (canonical mode)

### 1-7. Complete exception handlers (~300 LOC) — ✅ COMPLETE
- [x] ISR 0-19 registered
- [x] Page fault shows CR2 address + read/write/user/kernel from error code
- [x] Error code display
- [x] Stack trace (EBP chain walk, 10 frames max)
- [x] `panic()` function with serial dump (isr.zig)
- [x] Blue Screen of Death (panic_screen.zig) with register dump

### 1-8. init process (~200 LOC) — ✅ COMPLETE (simplified)
- [x] Kernel (PID=0) serves as init
- [x] Zombie processes automatically reaped in timerSchedule
- [x] init.zig: reapZombies() infrastructure
- [x] Shell runs as kernel's main interactive interface

### 1-9. Test infrastructure (~500 LOC) — ⚠️ PARTIAL
- [x] QEMU automated test scripts with QMP
- [x] Screenshot capture and verification
- [x] Serial output logging
- [x] Kernel logging subsystem (log.zig: debug/info/warn/err/fatal)
- [x] benchmark shell command (timer.zig)
- [ ] CI setup (GitHub Actions)

### Previously completed (v0.5-v0.7) — ✅ VERIFIED WORKING
- [x] Preemptive round-robin scheduler with timer interrupt
- [x] INT 0x80 syscalls (exit, write, getpid, yield, sleep, fork, wait, kill, getppid)
- [x] PCI bus enumeration (pci.zig)
- [x] ATA PIO read/write driver (ata.zig)
- [x] FAT16 read/write filesystem (fat16.zig)
- [x] Intel E1000 NIC driver (e1000.zig)
- [x] Network stack: Ethernet, ARP, IPv4, ICMP ping (net.zig)
- [x] TCP (3-way handshake, send/recv, FIN close) (tcp.zig)
- [x] UDP sockets (bind, sendto, recvfrom) (udp.zig)
- [x] RAM filesystem with inode hierarchy (ramfs.zig)
- [x] VFS with file descriptors (vfs.zig)
- [x] Pipe IPC with ring buffer (pipe.zig)
- [x] Multi-user system: root/guest, su, login (user.zig)
- [x] ELF32 loader (elf.zig)
- [x] 56 shell commands

---

## Milestone 2: Hobby OS — ~50,000 LOC (FOUNDATIONS — ~10%)

**Goal**: GUI, full TCP, USB, x86_64. Usable as a daily-driver hobby OS.

> Skeleton modules for all 11 subsystems + utility libraries (v1.1). TCP has retransmission/congestion control. GUI has VGA Mode 13h working. ext2 has write support. ~3,500 LOC implemented out of ~34,500 estimated.

### 2-1. x86_64 migration (~3,000 LOC) — ❌ NOT STARTED
- [ ] Long mode transition (GDT64, CR4.PAE, EFER.LME, CR0.PG)
- [ ] 64-bit page tables (4-level: PML4 → PDPT → PD → PT)
- [ ] syscall/sysret via STAR/LSTAR MSR
- [ ] 64-bit TSS
- [ ] Update build.zig target to x86_64
- Foundation: CPUID detection available in smp.zig
- Ref: OSDev "Setting Up Long Mode"

### 2-2. SMP basics (~2,000 LOC) — ⚠️ 105/2,000 LOC (5%)
- [x] BSP APIC ID detection via CPUID
- [x] SpinLock primitives (lock xchg atomic operations)
- [x] CPU count detection
- [ ] AP (Application Processor) startup (INIT-SIPI-SIPI)
- [ ] Per-CPU variables (GS base)
- [ ] SMP-aware scheduler (per-CPU run queues)

### 2-3. ACPI basics (~2,000 LOC) — ⚠️ 251/2,000 LOC (13%)
- [x] RSDP/RSDT/MADT/FADT parser structure (acpi.zig)
- [x] ACPI shutdown function (PM1a_CNT)
- [ ] RSDP discovery working (currently disabled — crashes on BIOS ROM access)
- [ ] Local APIC + I/O APIC initialization (replace legacy PIC)

### 2-4. Framebuffer + GUI (~8,000 LOC) — ⚠️ 378/8,000 LOC (5%)
- [x] Framebuffer graphics library: putPixel, drawRect, fillRect, drawChar (framebuf.zig)
- [x] Built-in 8x16 bitmap font
- [x] PS/2 mouse driver with IRQ12 (mouse.zig)
- [x] VGA Mode 13h (320x200, 256 colors) via direct register programming
- [x] `gui` command: demo with gradient, colored rectangles, text, mode switch
- [ ] Window manager, event queue, terminal emulator

### 2-5. Full TCP implementation (~3,000 LOC) — ⚠️ 366/3,000 LOC (12%)
- [x] 3-way handshake, data send/receive, FIN close
- [x] Retransmission with RTO + exponential backoff (5 retries)
- [x] Congestion control: slow start (cwnd), congestion avoidance (ssthresh)
- [x] TIME_WAIT state with 2MSL (4s) timer
- [ ] Sliding window, out-of-order buffer, keep-alive

### 2-6. DNS + DHCP (~1,000 LOC) — ⚠️ 389/1,000 LOC (39%)
- [x] DNS resolver: A record query/response via UDP (dns.zig)
- [x] DHCP client: DISCOVER/OFFER/REQUEST/ACK (dhcp.zig)
- [ ] Auto-configure IP on boot, config persistence

### 2-7. ext2 filesystem (~3,000 LOC) — ⚠️ 342/3,000 LOC (11%)
- [x] Superblock, block groups, inode reading, directory listing (read-only)
- [ ] Write support, bitmap management, indirect blocks

### 2-8. Block device layer (~2,000 LOC) — ⚠️ 111/2,000 LOC (6%)
- [x] Generic BlockDev struct, ATA backend (blkdev.zig)
- [ ] Page cache, partition table parsing (MBR, GPT)

### 2-9. USB (~4,500 LOC) — ⚠️ 153/4,500 LOC (3%)
- [x] UHCI controller detection and reset (uhci.zig)
- [ ] Device enumeration, HID driver, Mass Storage

### 2-10. POSIX extensions (~3,000 LOC) — ⚠️ 94/3,000 LOC (3%)
- [x] dup, dup2, lseek, getcwd, chdir (posix.zig)
- [ ] select/poll, shared memory, semaphores, TTY/PTY

### 2-11. Userspace tools (~3,000 LOC) — ⚠️ ~600/3,000 LOC (20%)
- [x] 56 shell commands with command history (up/down arrow)
- [x] Environment variables with $VAR expansion (env.zig)
- [x] Shift key, Ctrl+C/D/L, arrow keys, extended keyboard
- [x] libc-like string utilities (string.zig)
- [x] Formatting utilities (fmt.zig), logging (log.zig)
- [x] Generic data structures (ringbuf.zig, bitmap.zig, list.zig)
- [ ] Shell redirection, pipe chains, background jobs
- [ ] Coreutils: wc, head, tail, grep, sort
- [ ] Text editor

**Done when**: A GUI terminal window works, DNS resolves, and HTTP GET succeeds

---

## Milestone 3: MINIX-grade — ~100,000 LOC

**Goal**: Partial POSIX compatibility. Some existing C programs can be compiled and run natively.

- [ ] 100+ POSIX syscalls
- [ ] mmap / demand paging / disk swap
- [ ] ext3 journaling
- [ ] IPv6 dual stack
- [ ] AHCI (SATA) + NVMe drivers
- [ ] Dynamic linker (ld.so)
- [ ] /proc and /dev filesystems
- [ ] Port musl libc + busybox

**Done when**: musl libc + busybox run, basic POSIX test suite passes

---

## Milestone 4: Production OS — ~500,000 LOC

**Goal**: An OS real users can use. Self-hosting, web browser, package manager.

---

## Milestone 5: Linux-grade — ~36,000,000 LOC

**Goal**: Production-ready. Any hardware, any workload.

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
| v0.9 | 5,647 | MS1 ⚠️ ~65% | Hierarchical FS, VT100 console, cwd prompt |
| v1.0 | 7,582 | MS2 ⚠️ | ACPI, SMP, mouse, DNS, DHCP, ext2, USB, framebuffer (foundations) |
| v1.0.1 | 7,734 | MS1 ⚠️ ~90% | CR3 switching, Ctrl+C SIGINT, init zombie reaping, panic+stack trace |
| v1.0.2 | 8,228 | — | exec argv, TCP retransmit+congestion, VGA Mode 13h GUI, ext2 write |
| **v1.1** | **10,391** | **xv6-grade** | **Cmd history, env vars, sysinfo, shift keys, 9 utility modules, 56 cmds** |

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
