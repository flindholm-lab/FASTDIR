# FastDir
<img width="641" height="301" alt="image" src="https://github.com/user-attachments/assets/d457b985-63bf-4540-a556-5ec0be51207a" />

**FastDir (v2.42)** is a high-performance, drop-in replacement for the standard `DIR` command in MS-DOS and PC-DOS.

It is tailored specifically for vintage and low-spec systems (8088/8086, 286, 386) connected to modern, large storage solutions such as CompactFlash cards, SD adapters, and XT-IDE controllers. Native DOS utilities often crawl or freeze on large FAT volumes; FastDir eliminates these bottlenecks through low-level hardware optimizations, intelligent free-space detection, and memory-conscious algorithms.

## Key Features

* **Large Partition & FAT32 Support:**
  * Performs a version check for DOS 7.10+ before attempting FAT32 extended calls (`Int 21h, AX=7303h`), preventing system lockups on vintage DOS builds.
  * Tracks file counts and byte totals using 64-bit accumulators (`Comp` in Turbo Pascal, `Int64` in Free Pascal) to handle directory trees exceeding 2 GB.

* **Extreme Output Performance:**
  * **4 KB Buffered Console Output:** Bypasses the standard 128-byte DOS teletype bottleneck via `SetTextBuf`, drastically cutting `Int 21h` system calls during directory scans or file redirects.
  * **Zero-Allocation Streaming Mode:** When sorting (`/O`) is omitted, file entries display instantly as the filesystem discovers them. Eliminates memory overhead, heap constraints, and the 2,048-entry limit.
  * **One-Pass Recursive Scan (`/S`):** With broad match patterns (`*.*`), subdirectories are tracked during the primary file pass, removing the need for a secondary disk traversal per directory level.

* **Instant Free Space Assessment:**
  * **Sampled FAT Mode (`/QA`):** On FAT16 partitions under DOS 4.0+, reads the boot sector and samples 8 evenly distributed FAT sectors via `Int 25h` to extrapolate available space in milliseconds, bypassing slow, full-table scans.
  * **Bypass Switch (`/Q` or `/-F`):** Omits the free-space query entirely for instantaneous returns on sluggish media.

* **Direct-to-Video Color Rendering (`/C`):**
  * Renders colored output directly to text video RAM (yellow for directories, light green for `.COM`, `.EXE`, and `.BAT` executables).
  * Requires no external drivers (no `ANSI.SYS`) and does not link the Borland `Crt` unit (avoiding runtime error 200 on fast CPUs).
  * Features 4-line jump-scrolling via memory block copy to eliminate line-by-line scrolling stutter on slow 8088/8086 video subsystems.
  * Automatically falls back to standard output when piped or redirected to disk.

* **Robust Memory Management:**
  * Heap-allocated Quicksort avoids Real Mode 64 KB data segment (`DSEG`) limits.
  * Shortened string paths and heap-allocated subdirectory structures prevent stack overflows during deep recursive scans.

## Command-Line Syntax

```
FASTDIR [drive:][path][filename] [/W] [/P] [/B] [/L] [/S] [/C] [/T] [/Q] [/QA] [/O:ord] [/A:att]
```

### Options & Switches

| Switch | Description |
| :--- | :--- |
| `/W` | **Wide format:** Displays entries in 5 columns across the screen. |
| `/P` | **Pagination:** Pauses execution after each full screen of text until a key is pressed. |
| `/B` | **Bare format:** Outputs plain file names only (suppresses headers, footers, and sizes). |
| `/L` | **Lowercase:** Forces file and directory names to lowercase. |
| `/S` | **Subdirectories:** Recursively searches subfolders under the target directory. |
| `/C` | **Color:** Highlights directories in yellow and executables in green. |
| `/T` | **12-Hour Time:** Displays file timestamps in `HH:MMa/p` format (defaults to 24-hour). |
| `/Q` or `/-F` | **Quick mode:** Bypasses disk free space scanning completely. |
| `/QA` | **Quick Approximate:** Samples the FAT for near-instant space calculation (FAT16, DOS 4+). |
| `/?` | **Help:** Displays the command summary screen. |

### Sorting (`/O:order`)

Specify one or more sort keys. Prefix keys with `-` to sort in descending order (e.g., `/O:-S`).

| Key | Sort Criterion |
| :--- | :--- |
| `N` | Alphabetical by name |
| `E` | Alphabetical by file extension |
| `S` | By file size |
| `D` | By date and time |
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

FastDir parses the standard MS-DOS `DIRCMD` variable on execution. Switches can be concatenated without delimiters:

```bat
SET DIRCMD=/C/QA/O:GNE
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
* **Minimum OS:** MS-DOS / PC-DOS 3.30+ (DOS 4.0+ required for `/QA` packet reads; DOS 7.10+ for FAT32 extended calls).
* **Sort Limits:** Up to 2,048 entries per directory when sorting (`/O`) is active. Streaming mode (sorting disabled) handles an arbitrary number of entries.
* **Directory Nesting:** Up to 256 subdirectories tracked per folder level during recursive search.
