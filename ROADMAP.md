# Zig Kernel Roadmap

A step-by-step roadmap for growing an x86 kernel written in Zig toward a Linux-scale operating system.
Each milestone builds on the previous one.

## Current State

- **v0.7** — 4,724 LOC / 22 source files
- Level: Educational OS (Phase 2 complete)
- Features: preemptive multitasking, syscalls, ramfs, FAT16 R/W, PCI, ATA, E1000 NIC, ARP/IPv4/ICMP/TCP/UDP, VFS, pipes, multi-user

---

## Milestone 1: xv6-grade — ~10,000 LOC

**Goal**: A UNIX-like kernel with fork/exec, process isolation, hierarchical filesystem, and signals.

### 1-1. Per-process page tables (~800 LOC)
- [ ] Create per-process page directory
- [ ] Separate kernel space (upper) and user space (lower)
- [ ] Switch CR3 on context switch
- [ ] User-space mapping API (`map_page`, `unmap_page`)
- Ref: xv6 `vm.c`

### 1-2. fork (~600 LOC)
- [ ] Duplicate process (page tables + stack + registers)
- [ ] Copy-on-Write (CoW) with page fault handler
- [ ] Enhanced PID management (process tree, PPID)
- [ ] Add SYS_FORK syscall
- Ref: xv6 `proc.c:fork()`

### 1-3. exec (~400 LOC)
- [ ] Load ELF into independent address space
- [ ] Rebuild user stack (argc, argv)
- [ ] Release old address space
- [ ] Add SYS_EXEC syscall
- Ref: xv6 `exec.c`

### 1-4. wait / exit / signals (~500 LOC)
- [ ] SYS_WAIT (wait for child + collect exit code)
- [ ] Orphan reaping (init adopts orphaned children)
- [ ] Signal infrastructure: SIGKILL, SIGTERM, SIGINT
- [ ] Ctrl+C sends SIGINT
- Ref: xv6 `proc.c:wait()`, `kill()`

### 1-5. Filesystem improvements (~800 LOC)
- [ ] Inode-based design (inode table, block bitmap)
- [ ] Directory hierarchy (mkdir, rmdir, chdir, getcwd)
- [ ] Path resolution (`/dir/subdir/file`)
- [ ] `.` and `..` entries
- Ref: xv6 `fs.c`

### 1-6. Console improvements (~500 LOC)
- [ ] VT100 escape sequences (\033[H, \033[2J, colors, cursor movement)
- [ ] Line buffering (canonical mode)
- [ ] Ctrl+D (EOF), Ctrl+C (interrupt)
- Ref: Linux `drivers/tty/vt/`

### 1-7. Complete exception handlers + debugging (~300 LOC)
- [ ] Register ISR 0-31
- [ ] Stack trace display (EBP chain walk)
- [ ] Detailed page fault info (read/write, user/kernel)
- [ ] `panic()` function + serial dump

### 1-8. init process (~200 LOC)
- [ ] Kernel auto-starts PID=1 init process
- [ ] init fork+exec's /bin/sh (shell)
- [ ] Zombie process reaping

### 1-9. Test infrastructure (~500 LOC)
- [ ] In-kernel self-tests (memory, scheduler, FS)
- [ ] QEMU automated test scripts (serial output verification)
- [ ] CI setup (GitHub Actions)

**Done when**: `fork` spawns a shell, and `ls`/`cat` run as child processes

---

## Milestone 2: Hobby OS — ~50,000 LOC

**Goal**: GUI, full TCP, USB, x86_64. Usable as a daily-driver hobby OS.

### 2-1. x86_64 migration (~3,000 LOC)
- [ ] Long mode transition (GDT64, CR4.PAE, EFER.LME, CR0.PG)
- [ ] 64-bit page tables (4-level: PML4 → PDPT → PD → PT)
- [ ] syscall/sysret via STAR/LSTAR MSR
- [ ] 64-bit TSS
- [ ] Update build.zig target to x86_64
- Ref: OSDev "Setting Up Long Mode"

### 2-2. SMP basics (~2,000 LOC)
- [ ] Parse MP table / ACPI MADT to detect AP count
- [ ] AP (Application Processor) startup (INIT-SIPI-SIPI)
- [ ] Per-CPU variables (GS base)
- [ ] Spinlock, ticket lock
- [ ] SMP-aware scheduler (per-CPU run queues)
- Ref: OSDev "Symmetric Multiprocessing"

### 2-3. ACPI basics (~2,000 LOC)
- [ ] RSDP / RSDT / XSDT discovery
- [ ] MADT parsing (APIC info)
- [ ] FADT parsing (power control)
- [ ] Shutdown / reboot via ACPI
- [ ] Local APIC + I/O APIC (replace legacy PIC)
- Ref: ACPI spec, OSDev "APIC"

### 2-4. Framebuffer + GUI (~8,000 LOC)
- [ ] Multiboot2 framebuffer or VESA VBE mode setting
- [ ] Pixel drawing primitives (putpixel, line, rect, fill)
- [ ] Bitmap font rendering
- [ ] PS/2 mouse driver
- [ ] Window manager (windows, title bars, move, resize)
- [ ] Event queue (mouse/keyboard dispatch to windows)
- [ ] Terminal emulator window
- Ref: SerenityOS `Userland/Services/WindowServer/`

### 2-5. Full TCP implementation (~3,000 LOC)
- [ ] Sliding window
- [ ] Retransmission timer (RTO, exponential backoff)
- [ ] Congestion control (slow start, congestion avoidance)
- [ ] TIME_WAIT state
- [ ] Keep-alive
- [ ] Out-of-order receive buffer
- [ ] URG/PSH flag handling
- Ref: RFC 793, 5681, 6298

### 2-6. DNS + DHCP (~1,000 LOC)
- [ ] DHCP client (DISCOVER → OFFER → REQUEST → ACK)
- [ ] DNS resolver (A record, UDP query)
- [ ] `/etc/resolv.conf` equivalent config
- Ref: RFC 2131 (DHCP), RFC 1035 (DNS)

### 2-7. ext2 filesystem (~3,000 LOC)
- [ ] Superblock parsing
- [ ] Block group descriptors
- [ ] Inode read/write (direct + indirect blocks)
- [ ] Directory operations (lookup, create, unlink)
- [ ] File read/write (block alloc/free)
- [ ] Block/inode bitmap management
- Ref: ext2 spec (Dave Poirier)

### 2-8. Block device layer (~2,000 LOC)
- [ ] Generic block I/O interface
- [ ] Page cache (read-ahead, dirty write-back)
- [ ] ATA/AHCI backend abstraction
- [ ] Partition table parsing (MBR, GPT)

### 2-9. USB (~4,500 LOC)
- [ ] Detect USB host controllers via PCI
- [ ] UHCI or OHCI driver (USB 1.x)
- [ ] USB device enumeration (GET_DESCRIPTOR, SET_ADDRESS)
- [ ] USB HID driver (keyboard, mouse)
- [ ] USB Mass Storage (read/write USB drives)
- Ref: USB 2.0 spec, OSDev "USB"

### 2-10. POSIX extensions (~3,000 LOC)
- [ ] select / poll
- [ ] dup / dup2
- [ ] fcntl
- [ ] Shared memory (shmget, shmat)
- [ ] Semaphores
- [ ] Process groups, sessions
- [ ] TTY / PTY

### 2-11. Userspace tools (~3,000 LOC)
- [ ] libc subset (printf, scanf, malloc, string.h, stdlib.h)
- [ ] Shell improvements (env vars, `$PATH`, redirection `>`, background `&`)
- [ ] Coreutils: echo, wc, head, tail, grep, sort, uniq
- [ ] Text editor (ed equivalent)

**Done when**: A GUI terminal window works, DNS resolves, and HTTP GET succeeds

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
