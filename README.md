# FastDir
<img width="636" height="238" alt="image" src="https://github.com/user-attachments/assets/815c3ee1-d115-4f32-8472-c2ce7b5e3b41" />


**FastDir** is a high-performance, drop-in replacement for the standard `DIR` command in MS-DOS and PC-DOS.

It is tailored specifically for vintage and low-spec systems (8088/8086, 286, 386) connected to modern, large storage solutions such as CompactFlash cards, SD adapters, and XT-IDE controllers. Native DOS utilities often crawl or freeze on large FAT volumes; FastDir eliminates these bottlenecks through low-level hardware optimizations, intelligent free-space detection, native localization, and memory-conscious algorithms.

## Key Features

* **Large Partition & FAT32 Support:**
  * Probes for extended FAT32 free-space calls (`Int 21h, AX=7303h`) on any DOS 5.0+ kernel using defensive preset-carry detection, ensuring compatibility with DOSBox-X, FreeDOS, and Win9x while preventing crashes on older kernels.
  * Tracks directory sizes and drive totals using 64-bit accumulators (`Comp` in Turbo Pascal, `Int64` in Free Pascal) to handle file trees and partitions far exceeding 2 GB.
  * Automatically detects Windows NT/2000/XP NTVDM free-space reporting caps.

* **Long Filename Support (`/LFN`):**
  * Experimental LFN integration via the DOS LFN API (`Int 21h, AX=714Eh/714Fh/71A1h`), working seamlessly under Windows 9x DOS, DOSLFN TSR, and NT-family NTVDM.
  * Implements a 64 KB per-directory bump-allocated string pool (`TLfnPool`) for long names, eliminating per-entry heap fragmentation.
  * Automatically formats into an adaptive 3-column layout under `/W` (with truncation glyphs) and displays long names along the right column in detail mode.
  * Gracefully and silently falls back to standard 8.3 filenames if no LFN provider is active.

* **Flexible Display Modes & Internationalization:**
  * **Two-Column Detail Format (`/2`):** DR-DOS style dual-column detailed view divided by a clean CP437 box-drawing vertical bar.
  * **Human-Readable Sizes (`/H`):** Formats byte counts into dynamically scaled units (bytes, KB, MB, GB) with one decimal precision under 10 units (e.g., `1.4 MB`).
  * **Native DOS Localization (`InitCountry`):** Queries `Int 21h, AH=38h` on startup to honor the active `COUNTRY=` configuration, adapting thousands separators, decimal characters, date separators, date ordering (MDY, DMY, YMD), and time preferences.
  * **Clock Toggling (`/T`):** Inverts the default 12-hour or 24-hour clock determined by the country configuration.

* **Extreme Output Performance:**
  * **4 KB Buffered Console Output:** Replaces the standard 128-byte DOS teletype buffer with a 4 KB buffer via `SetTextBuf`, drastically reducing `Int 21h` system calls during screen writes and redirects.
  * **Zero-Allocation Streaming Mode:** When sorting (`/O`) is omitted, file entries stream immediately as the filesystem returns them, bypassing heap overhead and lifting the 2,048-entry limit.
  * **One-Pass Recursive Scan (`/S`):** With broad match patterns (`*.*`), subdirectories are tracked during the primary enumeration pass, eliminating a redundant disk read per tree level.

* **Instant Free Space Assessment:**
  * **Sampled FAT Mode (`/QA`):** On FAT16 partitions under DOS 3.31+ (Compaq DOS 3.31 and DOS 4.0+), directly reads the boot sector and samples 8 evenly distributed FAT sectors via `Int 25h` to extrapolate available space in milliseconds.
  * **Bypass Switch (`/Q` or `/-F`):** Omits the free-space query entirely for instantaneous returns on sluggish media.

* **Direct-to-Video Color Rendering (`/C`):**
  * Renders colored text directly to video RAM (yellow for directories, light green for `.COM`, `.EXE`, and `.BAT` executables).
  * Requires no external drivers (no `ANSI.SYS`) and does not link the Borland `Crt` unit (eliminating Runtime Error 200 on fast CPUs).
  * Employs 4-line jump-scrolling via direct memory block copy to eliminate line-by-line scrolling stutter on slow 8088/8086 video subsystems.
  * Automatically falls back to standard output when piped or redirected to disk.

* **Robust Memory Management & Safe Sorting:**
  * Heap-allocated Quicksort avoids Real Mode 64 KB data segment (`DSEG`) limits.
  * Unsigned 32-bit timestamp comparisons (`CmpUnsigned`) correctly sort file timestamps with years $\ge 2044$ (bit 31 set) rather than incorrectly ordering them before 1980.
  * Precomputes extensions for `/O:E` sorting to prevent $O(n \log n)$ string extraction loops.

## Command-Line Syntax

```
FASTDIR [drive:][path][filename] [/W] [/2] [/P] [/B] [/L] [/S] [/C] [/LFN] [/H] [/T] [/Q] [/QA] [/O:ord] [/A:att]
```

### Options & Switches

| Switch | Description |
| :--- | :--- |
| `/W` | **Wide format:** Displays entries horizontally (5 columns for 8.3 names; 3 columns for `/LFN`). |
| `/2` | **Two-column format:** Displays dual-column detailed entries with a vertical border (DR-DOS style). |
| `/P` | **Pagination:** Pauses execution after each full screen of text until a key is pressed. |
| `/B` | **Bare format:** Outputs plain file names only (suppresses headers, footers, and sizes; preserves LFN case). |
| `/L` | **Lowercase:** Forces file and directory names to lowercase. |
| `/S` | **Subdirectories:** Recursively searches subfolders under the target directory. |
| `/C` | **Color:** Highlights directories in yellow and executables in green via direct VRAM writes. |
| `/LFN`| **Long Filenames:** Enables long filename extraction on supported systems (Win9x, DOSLFN, NTVDM). |
| `/H` | **Human-Readable:** Renders file and partition sizes in KB, MB, or GB. |
| `/T` | **Toggle Clock:** Inverts the 12/24-hour time display format defined by the system `COUNTRY=` setting. |
| `/Q` or `/-F` | **Quick mode:** Bypasses disk free-space scanning completely. |
| `/QA` | **Quick Approximate:** Samples the FAT for near-instant space calculation (FAT16, DOS 3.31+). |
| `/?` | **Help:** Displays the command summary screen. |

### Sorting (`/O:order`)

Specify one or more sort keys. Prefix keys with `-` to sort in descending order (e.g., `/O:-S`).

| Key | Sort Criterion |
| :--- | :--- |
| `N` | Alphabetical by name |
| `E` | Alphabetical by file extension |
| `S` | By file size |
| `D` | By date and time (unsigned comparison supporting dates $\ge 2044$) |
| `G` | Group directories before files |

### Attribute Filtering (`/A:attrib`)

Filter entries by their file attributes. Prefix attributes with `-` to exclude them (e.g., `/A:-H-S`). A bare `/A` displays all files, including hidden and system entries.

| Key | Attribute |
| :--- | :--- |
| `D` | Directories |
| `R` | Read-only files |
| `H` | Hidden files |
| `S` | System files |
| `A` | Archive files |

## Environment Integration

FastDir parses the standard MS-DOS `DIRCMD` environment variable on execution. Switches can be concatenated without delimiters:

```bat
SET DIRCMD=/C/QA/O:GNE/H
```

You can alias or rename `FASTDIR.EXE` to `DIR.EXE` or run it from any directory in your `PATH`.

## Compilation

### Borland Turbo Pascal 6.0 / 7.0 (Target: 16-Bit Real Mode DOS)

```bat
tpc /M /B FASTDIR.PAS
```

*Creates an optimized 16-bit real-mode binary compatible with DOS 3.30 and later.*

### Free Pascal Compiler (Target: 32-Bit DPMI / go32v2)

```bat
fpc -Tgo32v2 -O3 FASTDIR.PAS
```

*Creates a 32-bit protected-mode DOS executable. Note: Direct `Int 25h` sector sampling (`/QA`) is disabled under DPMI and will automatically fall back to standard free-space detection routines.*

## Technical Specifications

* **Target Architecture:** IBM PC/XT/AT compatibles, 8088 through Pentium class.
* **Minimum OS:** MS-DOS / PC-DOS 3.30+ (DOS 3.31+ for `/QA` packet reads; DOS 5.0+ probed for extended FAT32 calls).
* **Sort Limits:** Up to 2,048 entries per directory when sorting (`/O`) is active. Streaming mode (sorting disabled) handles an arbitrary number of entries.
* **Directory Nesting:** Up to 256 subdirectories tracked per folder level during recursive search.
* **LFN Memory Pool:** Single 64 KB bump-allocated heap block per directory pass; display capped at 63 characters in sorted modes.

