# Zig Kernel Roadmap

x86 カーネルを段階的に拡張し、Linux 級の OS を目指すロードマップ。
各マイルストーンは前段階の完了を前提とする。

## 現在地

- **v0.7** — 4,724 LOC / 22 ファイル
- 到達レベル: 教育 OS (Phase 2 完了)

---

## Milestone 1: xv6 級 — ~10,000 LOC

**目標**: fork/exec が動く UNIX ライクなカーネル。プロセス分離、階層FS、シグナル。

### 1-1. per-process ページテーブル (~800 LOC)
- [ ] プロセスごとのページディレクトリ作成
- [ ] カーネル空間 (上位) + ユーザー空間 (下位) の分離
- [ ] コンテキストスイッチ時に CR3 切替
- [ ] ユーザー空間へのマッピング API (`map_page`, `unmap_page`)
- 参考: xv6 `vm.c`

### 1-2. fork (~600 LOC)
- [ ] プロセス複製 (ページテーブル + スタック + レジスタコピー)
- [ ] Copy-on-Write (CoW) ページフォルト連携
- [ ] PID 管理の強化 (プロセスツリー, PPID)
- [ ] SYS_FORK syscall 追加
- 参考: xv6 `proc.c:fork()`

### 1-3. exec (~400 LOC)
- [ ] ELF を独立アドレス空間にロード
- [ ] ユーザースタック再構築 (argc, argv)
- [ ] 古いアドレス空間の解放
- [ ] SYS_EXEC syscall 追加
- 参考: xv6 `exec.c`

### 1-4. wait/exit/signal (~500 LOC)
- [ ] SYS_WAIT (子プロセス終了待ち + 終了コード取得)
- [ ] 親プロセス終了時の orphan reaping (init が引き取る)
- [ ] シグナル基盤: SIGKILL, SIGTERM, SIGINT
- [ ] Ctrl+C → SIGINT 送信
- 参考: xv6 `proc.c:wait()`, `kill()`

### 1-5. ファイルシステム改善 (~800 LOC)
- [ ] inode ベースの設計 (inode テーブル, ブロックビットマップ)
- [ ] ディレクトリ階層 (mkdir, rmdir, chdir, getcwd)
- [ ] パス解決 (`/dir/subdir/file`)
- [ ] `.` と `..` エントリ
- 参考: xv6 `fs.c`

### 1-6. コンソール改善 (~500 LOC)
- [ ] VT100 エスケープシーケンス (\033[H, \033[2J, カラー, カーソル移動)
- [ ] 行バッファリング (canonical mode)
- [ ] Ctrl+D (EOF), Ctrl+C (interrupt)
- 参考: Linux `drivers/tty/vt/`

### 1-7. 例外ハンドラ完全 + デバッグ (~300 LOC)
- [ ] ISR 0-31 全登録
- [ ] スタックトレース表示 (EBP チェーン)
- [ ] ページフォルトでの詳細表示 (read/write, user/kernel)
- [ ] panic() 関数 + シリアルダンプ

### 1-8. init プロセス (~200 LOC)
- [ ] カーネルが PID=1 の init を自動起動
- [ ] init が /bin/sh (シェル) を fork+exec
- [ ] ゾンビプロセスの回収

### 1-9. テスト基盤 (~500 LOC)
- [ ] カーネル内セルフテスト (メモリ, スケジューラ, FS)
- [ ] QEMU 自動テストスクリプト (シリアル出力検証)
- [ ] CI (GitHub Actions) 設定

**完了条件**: `fork` でシェルを起動し、`ls`, `cat` が子プロセスで動く

---

## Milestone 2: Hobby OS — ~50,000 LOC

**目標**: GUI、完全な TCP、USB、x86_64。趣味で常用できるレベル。

### 2-1. x86_64 移行 (~3,000 LOC)
- [ ] Long mode 遷移 (GDT64, CR4.PAE, EFER.LME, CR0.PG)
- [ ] 64-bit ページテーブル (4-level: PML4→PDPT→PD→PT)
- [ ] syscall/sysret (STAR/LSTAR MSR)
- [ ] 64-bit TSS
- [ ] build.zig ターゲットを x86_64 に変更
- 参考: OSDev "Setting Up Long Mode"

### 2-2. SMP 基礎 (~2,000 LOC)
- [ ] MP テーブル / ACPI MADT 解析 → AP 数検出
- [ ] AP (Application Processor) 起動 (INIT-SIPI-SIPI)
- [ ] per-CPU 変数 (GS ベース)
- [ ] spinlock, ticket lock
- [ ] スケジューラの SMP 対応 (per-CPU run queue)
- 参考: OSDev "Symmetric Multiprocessing"

### 2-3. ACPI 基礎 (~2,000 LOC)
- [ ] RSDP/RSDT/XSDT 探索
- [ ] MADT (APIC 情報)
- [ ] FADT (電源制御)
- [ ] shutdown / reboot (ACPI 経由)
- [ ] Local APIC + I/O APIC (PIC 置き換え)
- 参考: ACPI spec, OSDev "APIC"

### 2-4. フレームバッファ + GUI (~8,000 LOC)
- [ ] Multiboot2 フレームバッファ or VESA VBE モード設定
- [ ] ピクセル描画 (putpixel, line, rect, fill)
- [ ] ビットマップフォントレンダリング
- [ ] マウスドライバ (PS/2)
- [ ] ウィンドウマネージャ (ウィンドウ, タイトルバー, 移動, リサイズ)
- [ ] イベントキュー (マウス/キーボード → ウィンドウ配送)
- [ ] ターミナルエミュレータウィンドウ
- 参考: SerenityOS `Userland/Services/WindowServer/`

### 2-5. TCP 完全実装 (~3,000 LOC)
- [ ] スライディングウィンドウ
- [ ] 再送タイマー (RTO, exponential backoff)
- [ ] 輻輳制御 (slow start, congestion avoidance)
- [ ] TIME_WAIT ステート
- [ ] keep-alive
- [ ] out-of-order 受信バッファ
- [ ] URG/PSH フラグ処理
- 参考: RFC 793, 5681, 6298

### 2-6. DNS + DHCP (~1,000 LOC)
- [ ] DHCP クライアント (DISCOVER→OFFER→REQUEST→ACK)
- [ ] DNS リゾルバ (A レコード, UDP query)
- [ ] `/etc/resolv.conf` 相当の設定
- 参考: RFC 2131 (DHCP), RFC 1035 (DNS)

### 2-7. ext2 ファイルシステム (~3,000 LOC)
- [ ] スーパーブロック解析
- [ ] ブロックグループディスクリプタ
- [ ] inode 読み書き (direct + indirect blocks)
- [ ] ディレクトリ操作 (lookup, create, unlink)
- [ ] ファイル読み書き (ブロック割当/解放)
- [ ] ブロック/inode ビットマップ管理
- 参考: ext2 spec (Dave Poirier)

### 2-8. ブロックデバイスレイヤー (~2,000 LOC)
- [ ] 汎用ブロック I/O インタフェース
- [ ] ページキャッシュ (read-ahead, dirty write-back)
- [ ] ATA/AHCI バックエンド抽象化
- [ ] パーティションテーブル (MBR, GPT) 解析

### 2-9. USB (~4,500 LOC)
- [ ] PCI から USB ホストコントローラ検出
- [ ] UHCI or OHCI ドライバ (USB 1.x)
- [ ] USB デバイス列挙 (GET_DESCRIPTOR, SET_ADDRESS)
- [ ] USB HID ドライバ (キーボード, マウス)
- [ ] USB Mass Storage (USB メモリ読み書き)
- 参考: USB 2.0 spec, OSDev "USB"

### 2-10. POSIX 拡張 (~3,000 LOC)
- [ ] select / poll
- [ ] dup / dup2
- [ ] fcntl
- [ ] 共有メモリ (shmget, shmat)
- [ ] semaphore
- [ ] プロセスグループ, セッション
- [ ] TTY / PTY

### 2-11. ユーザー空間ツール (~3,000 LOC)
- [ ] libc サブセット (printf, scanf, malloc, string.h, stdlib.h)
- [ ] シェル改善 (環境変数, `$PATH`, リダイレクト `>`, バックグラウンド `&`)
- [ ] coreutils: echo, wc, head, tail, grep, sort, uniq
- [ ] テキストエディタ (ed 相当)

**完了条件**: GUI ウィンドウでターミナルが動き、DNS 解決して HTTP GET できる

---

## Milestone 3: MINIX 級 — ~100,000 LOC

**目標**: POSIX サブセット互換。既存 C プログラムの一部がコンパイル・実行できる。

- [ ] POSIX syscall 100+ 個 (open, read, write, close, fork, exec, wait, pipe, dup2, stat, lseek, mmap, munmap, ioctl, socket, bind, listen, accept, connect, send, recv, select, poll, kill, signal, sigaction, getpid, getppid, getcwd, chdir, mkdir, rmdir, unlink, link, rename, chmod, chown, ...)
- [ ] mmap / demand paging / swap (ディスクスワップ)
- [ ] ext3 ジャーナリング (ordered mode)
- [ ] IPv6 デュアルスタック
- [ ] AHCI (SATA) ドライバ
- [ ] NVMe ドライバ
- [ ] 動的リンカ (ld.so 相当, ELF shared object)
- [ ] /proc ファイルシステム
- [ ] /dev ファイルシステム (デバイスノード)
- [ ] ネットワークソケット完全 (listen/accept/connect/shutdown)
- [ ] プロセスグループ, セッション, ジョブ制御 (fg, bg, jobs)
- [ ] newlib or musl libc 移植
- [ ] Lua or MicroPython 移植 (言語ランタイム動作検証)

**完了条件**: musl libc + busybox が動き、基本的な POSIX テストスイートが通る

---

## Milestone 4: 実用 OS — ~500,000 LOC

**目標**: 実際にユーザーが使える OS。ブラウザ、ファイルマネージャ、パッケージマネージャ。

- [ ] ドライバ群: NIC 10+種 (realtek, intel, broadcom), GPU (VESA/bochs-vga/virtio-gpu), HDA audio, XHCI (USB 3.0), NVME, virtio (net/blk/console)
- [ ] ファイルシステム群: FAT32, ext4, tmpfs, devfs, sysfs, procfs
- [ ] ネットワーク完全: netfilter/iptables 相当, NAT, bonding, VLAN, WiFi (802.11)
- [ ] セキュリティ: capabilities, seccomp, namespace (mount/PID/net)
- [ ] GUI ツールキット (ウィジェット: button, textbox, list, menu, dialog)
- [ ] ウィンドウマネージャ (タスクバー, ワークスペース, テーマ)
- [ ] アプリ: ファイルマネージャ, テキストエディタ, ターミナル, 画像ビューア
- [ ] パッケージマネージャ (ビルドシステム, 依存解決)
- [ ] セルフホスト (OS 上で OS をビルド)
- [ ] 完全 POSIX 互換テストスイート

**完了条件**: セルフホスト可能、ウェブブラウザが動く

---

## Milestone 5: Linux 級 — ~36,000,000 LOC

**目標**: プロダクション運用。あらゆるハードウェアとワークロード。

- [ ] アーキテクチャ: x86_64, ARM64, RISC-V, ...
- [ ] デバイスドライバ: 数千種 (全カテゴリ)
- [ ] コンテナ: cgroup v2, namespace 完全
- [ ] 仮想化: KVM 相当 (VMX/SVM)
- [ ] ファイルシステム: ext4, btrfs, xfs, nfs, ceph, ...
- [ ] ネットワーク: 全プロトコル, XDP/eBPF
- [ ] セキュリティ: SELinux, AppArmor, 暗号 API, 鍵管理
- [ ] リアルタイム: PREEMPT_RT
- [ ] 電源管理: ACPI 完全, suspend/hibernate
- [ ] パフォーマンス: perf, ftrace, eBPF

---

## 参考リソース

### 書籍
- "Operating Systems: Three Easy Pieces" (OSTEP) — 無料オンライン
- "Operating System Concepts" (Silberschatz) — 教科書定番
- "Linux Kernel Development" (Robert Love) — Linux 内部
- "Understanding the Linux Kernel" (Bovet & Cesati) — 詳細リファレンス

### ソースコード
- [xv6](https://github.com/mit-pdos/xv6-public) — MIT 教育 OS (~10K LOC)
- [SerenityOS](https://github.com/SerenityOS/serenity) — C++ 趣味 OS (~1M LOC)
- [MINIX 3](https://github.com/Stichting-MINIX-Research-Foundation/minix) — マイクロカーネル
- [Linux](https://github.com/torvalds/linux) — 目標

### OSDev
- [OSDev Wiki](https://wiki.osdev.org/) — OS 開発の百科事典
- [OSDev Forum](https://forum.osdev.org/) — Q&A

### 仕様書
- Intel SDM (Software Developer's Manual) — x86 アーキテクチャ
- ACPI Specification — 電源管理
- USB 2.0/3.0 Specification — USB
- ext2/ext4 disk layout — ファイルシステム
- RFC 793 (TCP), 791 (IP), 768 (UDP) — ネットワーク
