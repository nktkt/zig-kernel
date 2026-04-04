# Zig Kernel Roadmap

A step-by-step roadmap for growing an x86 kernel written in Zig toward a Linux-scale operating system.
Each milestone builds on the previous one.

## Current State

- **v1.0** — 7,582 LOC / 34 source files
- Level: Milestone 1 in progress (~65%), Milestone 2 foundations (~6%)

---

## Milestone 1: xv6-grade — ~10,000 LOC (IN PROGRESS — ~65%)

**Goal**: A UNIX-like kernel with fork/exec, process isolation, hierarchical filesystem, and signals.

**Completion criteria**: `fork` spawns a shell, and `ls`/`cat` run as child processes.

### 1-1. Per-process page tables (~800 LOC) — ❌ CODE EXISTS BUT UNUSED
- [x] vmm.zig: createAddressSpace, cloneAddressSpace, freeAddressSpace, mapUserPage, unmapUserPage
- [ ] **timerSchedule does NOT switch CR3 — all processes share kernel page directory**
- [ ] **No actual address space isolation between processes**
- [ ] Wire up CR3 switching in context switch
- [ ] Allocate separate user pages for each process
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

### 1-4. wait / exit / signals (~500 LOC) — ⚠️ MOSTLY WORKING
- [x] SYS_WAIT (reap zombie children, collect exit code)
- [x] Orphan reparenting to init (pid=0)
- [x] Signals: SIGKILL, SIGTERM
- [x] Zombie state, parent wakeup on child exit
- [x] `kill` shell command
- [ ] **Ctrl+C → SIGINT not wired up (keyboard handler doesn't detect it)**
- Ref: xv6 `proc.c:wait()`, `kill()`

### 1-5. Hierarchical filesystem (~800 LOC) — ✅ COMPLETE
- [x] Inode-based ramfs with directory support
- [x] mkdir, cd, pwd commands
- [x] Path resolution (`/dir/subdir/file`, `.`, `..`)
- [x] `ls` shows file type (file/dir) with color

### 1-6. VT100 console (~500 LOC) — ⚠️ PARTIAL
- [x] Escape sequence parser (ESC [ params cmd)
- [x] Cursor movement (CSI A/B/C/D/H)
- [x] Erase display/line (CSI J/K)
- [x] SGR colors (CSI m, ANSI 30-37, 40-47, 90-97, bold)
- [x] Tab, carriage return handling
- [ ] Line buffering (canonical mode)
- [ ] Ctrl+D (EOF), Ctrl+C (interrupt) handling

### 1-7. Complete exception handlers (~300 LOC) — ⚠️ PARTIAL
- [x] ISR 0-19 registered
- [x] Page fault shows CR2 address
- [x] Error code display
- [x] System halt on fatal exception
- [ ] Stack trace display (EBP chain walk)
- [ ] Detailed page fault info (read/write, user/kernel from error code bits)
- [ ] `panic()` function with serial dump

### 1-8. init process (~200 LOC) — ❌ NOT IMPLEMENTED
- [ ] **Kernel directly calls shell.init() — no PID=1 init process**
- [ ] Kernel should create init as first user process
- [ ] init fork+exec's /bin/sh (shell)
- [ ] Zombie process reaping by init

### 1-9. Test infrastructure (~500 LOC) — ⚠️ PARTIAL
- [x] QEMU automated test scripts with QMP
- [x] Screenshot capture and verification
- [x] Serial output logging
- [ ] In-kernel self-tests (memory, scheduler, FS)
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
- [x] 44 shell commands

---

## Milestone 2: Hobby OS — ~50,000 LOC (FOUNDATIONS ONLY — ~6%)

**Goal**: GUI, full TCP, USB, x86_64. Usable as a daily-driver hobby OS.

> Skeleton modules exist for all 11 subsystems (v1.0), but each needs significant expansion. ~1,939 LOC implemented out of ~34,500 estimated.

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

### 2-4. Framebuffer + GUI (~8,000 LOC) — ⚠️ 364/8,000 LOC (5%)
- [x] Framebuffer graphics library: putPixel, drawRect, fillRect, drawChar (framebuf.zig)
- [x] Built-in 8x16 bitmap font
- [x] PS/2 mouse driver with IRQ12 (mouse.zig)
- [ ] VESA VBE mode setting
- [ ] Window manager, event queue, terminal emulator

### 2-5. Full TCP implementation (~3,000 LOC) — ⚠️ basic only
- [x] 3-way handshake, data send/receive, FIN close
- [ ] Sliding window, retransmission, congestion control, TIME_WAIT

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

### 2-11. Userspace tools (~3,000 LOC) — ⚠️ 130/3,000 LOC (4%)
- [x] 44 shell commands
- [ ] libc subset, coreutils, text editor

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
| v1.0 | 7,582 | MS2 ⚠️ ~6% | ACPI, SMP, mouse, DNS, DHCP, ext2, USB, framebuffer (foundations) |

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
