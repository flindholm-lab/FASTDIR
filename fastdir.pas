{ =========================================================================== }
{ FASTDIR.PAS - High-Performance DIR Utility for MS-DOS & PC-DOS              }
{ Compatible with Turbo Pascal 6.0, 7.0, and Free Pascal (go32v2 target)      }
{                                                                             }
{ Designed for slow PCs (8088/8086, 286, 386, XT-IDE, CF cards, large disks): }
{   - Safe FAT32 free-space probe on any DOS 5+ (preset-carry detection)     }
{   - Instant free-space bypass switch (/Q or /-F)                            }
{   - Reads DIRCMD environment variable on startup                            }
{   - Heap-based Quicksort avoiding DSEG 64K limits                           }
{   - Full support for /W, /P, /B, /L, /S, /A, /O, and /?                     }
{                                                                             }
{ v2.13 fixes:                                                                }
{   - Volume label now searched in the ROOT directory with proper wildcard,   }
{     loops until a real volume entry is found, embedded dot stripped         }
{   - <DIR> marker printed in the size column; columns now align              }
{   - /S subdirectory list moved to the heap (no stack overflow on deep       }
{     trees); path strings shortened to reduce per-level stack usage          }
{   - Stack checking re-enabled ($S+) as recursion depth is unbounded         }
{   - Warning printed when MAX_ENTRIES is exceeded (was silent truncation)    }
{   - Grand totals accumulated in 64-bit (Comp / Int64) to survive > 2 GB     }
{   - FindClose added for Free Pascal builds (handle leak fix)                }
{ v2.20 speed optimizations for slow CPUs + fast flash media:              }
{   - 4 KB buffered console output (SetTextBuf) - far fewer DOS calls      }
{   - Streaming mode: with no /O sort, entries print as DOS returns them   }
{     (no heap storage, no 2048-entry limit, instant first line)           }
{   - /S collects subdirectories during the main scan when possible,       }
{     eliminating a full second directory read per level                   }
{   - Extension precomputed once per entry for /O:E (was recomputed        }
{     on every quicksort comparison)                                       }
{   - PadLeft/PadRight rewritten with FillChar/Move (no per-char copies)   }
{ v2.30:                                                                    }
{   - /C color mode: directories yellow, .COM/.EXE/.BAT green. Rendered    }
{     by direct video writes + BIOS scroll (no CRT unit, no ANSI.SYS       }
{     needed). Auto-disabled when output is redirected to a file/pipe.     }
{   - Switches may be run together: FASTDIR /C/Q/W  and  SET DIRCMD=/C/Q   }
{ v2.40:                                                                    }
{   - /C scrolling: direct-memory block move + 4-line jump scroll           }
{     (SCROLL_STEP) replaces per-line BIOS scrolls - far less stutter       }
{   - /QA: quick approximate free space. Samples 8 FAT sectors via          }
{     Int 25h and extrapolates instead of letting DOS walk the whole        }
{     FAT (FAT16, DOS 4+). Falls back to exact scan when not applicable.    }
{ v2.50:                                                                    }
{   - /LFN (experimental): long filenames via the DOS LFN API              }
{     (Int 21h 714Eh/4Fh/71A1h) - works under Win9x DOS, DOSLFN, NTVDM.    }
{     Long names live in a per-directory bump-allocated string pool        }
{     (fixed metadata records + contiguous name storage), display-capped;  }
{     auto-falls back to 8.3 when no LFN provider is present. Wide mode    }
{     switches to 3x26 columns with truncation markers under /LFN.         }
{   - /2 two-column detail format (DR-DOS style), /H human-readable        }
{     sizes, /T inverts the COUNTRY= 12/24-hour clock default              }
{   - COUNTRY=-aware output: thousands/decimal separators, date order      }
{     and separators, clock format - matching real DIR everywhere          }
{   - DIR-compatible mask semantics: 'T*' -> 'T*.*', literal directory     }
{     names list contents, wildcards never trigger the directory check     }
{ v2.60:                                                                    }
{   - /C now color-codes by file type via a packed-integer extension       }
{     table (90 extensions): executables green, archives & disk images     }
{     light red, documents/configs light cyan, media light blue, source    }
{     code bright white, backups/temp dark gray (auto-remapped to normal   }
{     on MDA/Hercules where dark gray is invisible)                        }
{   - 8088 tuning: running video offset in OutStr (no per-character MUL,   }
{     BDA cursor read), single contiguous entry pool instead of 2048       }
{     New() calls, single-pass thousands-separator formatting, LongRec     }
{     word access replacing 32-bit shifts in the sort comparator           }
{ v2.70 - color-mode rendering core rewritten for the 4.77 MHz 8088:       }
{   - CRTC hardware scrolling: the visible window slides through the       }
{     16 KB VRAM ring via the 6845 start-address register - zero-copy,     }
{     smooth 1-line scrolls; ring rewind only every ~77 lines. Screen,     }
{     BDA and cursor restored on exit via an ExitProc (crash-safe).        }
{   - LODSB/STOSW run blitter replaces the per-character write loop;       }
{     REP STOSW blank fills; hardware cursor synced only at /P pauses      }
{     and program exit instead of per string (no Int 10h in the hot path)  }
{   - MDA keeps software jump scroll (4 KB VRAM); FPC keeps BIOS paths     }
{ =========================================================================== }

{$A-,R-,S+,I-,Q-}      { Alignment off, range check off, STACK CHECK ON }
{$IFNDEF FPC}
{$M 32768, 0, 655360}  { 32K stack, up to 640K heap }
{$N+,E+}               { Enable Comp type via 8087 emulation }
{$ENDIF}

program FastDir;

uses
  Dos;  { Crt removed: its startup Delay() calibration crashes with
          Runtime Error 200 (divide by zero) on CPUs > ~200 MHz.
          ReadKey is replaced by a direct BIOS Int 16h call below. }

const
  PROG_VERSION   = '2.70-TP';
  MAX_ENTRIES    = 2048; { Maximum number of files processed per directory }
  MAX_SUBDIRS    = 256;  { Maximum subdirectories tracked per level for /S }
  WIDE_COLS      = 5;    { Number of columns for Wide (/W) display format }
  LFN_WIDE_COLS  = 3;    { /W /LFN: fewer, wider columns for long names }
  LFN_WIDE_WIDTH = 26;   { /W /LFN: column width (3 x 26 = 78 of 80) }

  { /LFN long-name string pool: names are bump-allocated into one
    contiguous block (reset per directory) instead of per-entry heap
    blocks - zero fragmentation, O(1) allocation }
  LFN_POOLSIZE   = 65520; { Largest single GetMem block in real mode }
  LFN_MAXSTORE   = 63;    { Display cap: sorted mode stores at most this
                            many chars per long name (a detail line can
                            only show ~30 anyway) }

  { Software jump-scroll distance in lines - used only where hardware
    CRTC scrolling is unavailable (MDA/Hercules, FPC builds). On color
    adapters /C scrolls via the CRTC start address: zero-copy, smooth,
    one line at a time. }
  SCROLL_STEP    = 4;

  { Text VRAM ring for CRTC hardware scrolling: CGA has 16 KB at B800h,
    enough for 102 lines of 80-column text. The visible window slides
    through it; a rare block copy back to offset 0 happens only when
    the window would cross the 16 KB wrap (once per ~77 scrolled lines). }
  RING_BYTES     = $4000;

  { /QA: number of FAT sectors sampled for the free-space estimate }
  EST_SAMPLES    = 8;

  { Text attributes for /C color mode (foreground on black) }
  CLR_NORMAL     = $07;  { Light gray - ordinary files & framework text }
  CLR_DIR        = $0E;  { Yellow      - directories }
  CLR_EXEC       = $0A;  { Light green - .COM / .EXE / .BAT }
  CLR_ARCH       = $0C;  { Light red   - archives & disk images }
  CLR_DOCS       = $0B;  { Light cyan  - documents, text, configs }
  CLR_MEDIA      = $09;  { Light blue  - images, audio, music, video }
  CLR_SRC        = $0F;  { Bright white- source code }
  CLR_JUNK       = $08;  { Dark gray   - backups/temp (normal on mono) }

  EXT_TABLE_MAX  = 96;   { Capacity of the extension color table }

  { Standard DOS File Attributes }
  ATTR_READONLY  = $01;
  ATTR_HIDDEN    = $02;
  ATTR_SYSTEM    = $04;
  ATTR_VOLUME    = $08;
  ATTR_DIRECTORY = $10;
  ATTR_ARCHIVE   = $20;
  ATTR_ANYFILE   = $3F;  { Mask for matching any file }

  { Sorting Keys }
  SORT_NONE      = 0;
  SORT_NAME      = 1;
  SORT_EXT       = 2;
  SORT_SIZE      = 3;
  SORT_DATE      = 4;

type
  { 64-bit accumulator: Comp under TP (needs $N+), Int64 under FPC }
{$IFDEF FPC}
  Big = Int64;
{$ELSE}
  Big = Comp;
{$ENDIF}

  { DOS paths never exceed 66 chars + drive; short strings keep the
    per-recursion-level stack frame small for deep /S traversals }
  PathStr12 = string[12];
  PathStr79 = string[79];

  { Word-level view of a LongInt: the 8088 has no barrel shifter, so
    'shr 16' costs a 16-iteration shift loop - direct word access is free }
  LongRec = record
    Lo, Hi: Word;
  end;

  { One extension-color rule: the (uppercase) extension packed into a
    LongInt (char1 + char2<<8 + char3<<16, unused positions zero) plus
    its display attribute. Integer compares instead of string compares. }
  TExtEntry = record
    Key  : LongInt;
    Attr : Byte;
  end;

  { Represents a single file or directory entry }
  PFileEntry = ^TFileEntry;
  TFileEntry = record
    Name : string[12];
    Ext  : string[4];  { Precomputed at insert time when sorting by /O:E }
    Attr : Byte;
    Time : LongInt;
    Size : LongInt;
    LOfs : Word;       { /LFN: offset of long name in LfnPool }
    LLen : Byte;       { /LFN: length of long name (0 = none stored) }
  end;

  { /LFN long-name pool (heap-allocated only when /LFN is active) }
  TLfnPool = array[0..LFN_POOLSIZE - 1] of Char;
  PLfnPool = ^TLfnPool;

  { Heap-allocated array to avoid hitting DSEG limitations in real mode }
  TFileArray = array[1..MAX_ENTRIES] of PFileEntry;
  PFileArray = ^TFileArray;

  { All entries live in ONE contiguous pool block (a single New instead
    of 2048 individual allocations - no heap fragmentation, no free-list
    walks). NOTE: 2048 x 30 bytes = 61,440, which must stay under the
    65,521-byte single-block limit - adding fields to TFileEntry or
    raising MAX_ENTRIES can silently break this, so mind the product. }
  TFilePool = array[1..MAX_ENTRIES] of TFileEntry;
  PFilePool = ^TFilePool;

  { Heap-allocated subdirectory list for /S (was on the stack: ~3.3 KB per
    recursion level, guaranteed overflow on deep trees) }
  TSubDirList = array[1..MAX_SUBDIRS] of PathStr12;
  PSubDirList = ^TSubDirList;

  { Data structure for DOS Int 21h, AX=7303h (Get Extended Free Space) }
  TFAT32FreeSpace = record
    StructureSize        : Word;
    StructureVersion     : Word;
    SectorsPerCluster    : LongInt;
    BytesPerSector       : LongInt;
    AvailableClusters    : LongInt;
    TotalClusters        : LongInt;
    AvailablePhysSectors : LongInt;
    TotalPhysSectors     : LongInt;
    AvailableAllocUnits  : LongInt;
    TotalAllocUnits      : LongInt;
    Reserved             : array[0..7] of Byte;
  end;

var
  { Command Line Options }
  OptWide        : Boolean;  { /W switch }
  Opt2Col        : Boolean;  { /2 switch: DR-DOS style two-column detail }
  OptPage        : Boolean;  { /P switch }
  OptBare        : Boolean;  { /B switch }
  OptLower       : Boolean;  { /L switch }
  OptSubDir      : Boolean;  { /S switch }
  OptSkipFree    : Boolean;  { /Q or /-F switch }
  OptEstimate    : Boolean;  { /QA switch: sampled free-space estimate }
  OptGroupDirs   : Boolean;  { /O:G switch (group directories first) }
  OptColor       : Boolean;  { /C switch }
  OptHuman       : Boolean;  { /H switch: human-readable sizes (KB/MB/GB) }
  OptLFN         : Boolean;  { /LFN switch (experimental long filenames) }
  LfnActive      : Boolean;  { /LFN requested AND the LFN API responded }
  LfnWarned      : Boolean;  { Fallback notice printed once }
  LfnPool        : PLfnPool; { Long-name string pool (nil unless /LFN) }
  PoolTop        : Word;     { Bump pointer into LfnPool }
  CurLfn         : string;   { Long name of the entry being displayed }
  LfnFindBuf     : array[0..317] of Byte; { 714Eh extended find buffer }
  OptAmPm        : Boolean;  { 12-hour am/pm time: default from COUNTRY=
                               time format byte, /T inverts the default }
  ColorActive    : Boolean;  { /C requested AND stdout is a real console }
  MonoMode       : Boolean;  { Video mode 7 (MDA/Hercules) - remap colors
                               that would be invisible on mono }

  { Software-tracked video state (/C): the hardware cursor is synced
    only at the /P pause and at program exit - no Int 10h per string }
  VidInited      : Boolean;  { Video state captured from the BDA }
  VidSeg         : Word;     { B800h color / B000h mono }
  VidCols        : Word;     { Columns per row (BDA 40:4A) }
  VidRowBytes    : Word;     { VidCols * 2 }
  VidPage        : Byte;     { Active display page }
  CurRow, CurCol : Byte;     { Software cursor position }
  VisOfs         : Word;     { VRAM byte offset of the visible top-left
                               (advances during CRTC hardware scrolling) }
  HwScrollOK     : Boolean;  { CRTC ring scrolling usable on this setup }
  ExitSave       : Pointer;  { Chained ExitProc for crash-safe restore }
  ExtTable       : array[1..EXT_TABLE_MAX] of TExtEntry;
  ExtCount       : Integer;  { Entries in use (0 when /C inactive) }

  SortKey        : Byte;     { Active sorting mechanism }
  SortReverse    : Boolean;  { Reverse sorting order flag }

  AttrRequire    : Byte;     { Mask of attributes that MUST be present }
  AttrExclude    : Byte;     { Mask of attributes that MUST NOT be present }

  LinesOnScreen  : Word;     { Detected rows on terminal }
  CurrentLine    : Word;     { Tracks output lines for /P pagination }
  ColIndex       : Word;     { Tracks current column for /W wide format }

  TargetMask     : string;   { File wildcard to search for }
  TargetDir      : string;   { Base directory to search }
  FirstHeader    : Boolean;  { True until the first 'Directory of' line is
                               printed - keeps it snug under the volume
                               header like real DIR, while /S puts a blank
                               line before each subsequent directory }

  TotalFiles     : LongInt;  { Global statistics counters }
  TotalDirs      : LongInt;
  TotalBytes     : Big;      { 64-bit: /S over a large tree exceeds 2 GB }

  { Country-dependent formatting, from DOS Int 21h AH=38h (like real DIR):
    e.g. COUNTRY=046 (Sweden) uses space as thousands separator and
    yy-mm-dd dates }
  ThousandsSep   : Char;     { Separator for FormatNumber/FormatBig }
  DecimalSep     : Char;     { Decimal separator for /H human sizes }
  DateSep        : Char;     { Date field separator }
  TimeSep        : Char;     { Time field separator }
  DateFmt        : Word;     { 0=mm dd yy (USA), 1=dd mm yy, 2=yy mm dd }

  { 4 KB output buffer: DOS Int 21h write calls drop from one per ~128
    bytes to one per 4 KB. Massive win on 8088 for /S and /B listings,
    and for output redirected to a file. }
  OutBuf         : array[0..4095] of Char;

  { Sector buffer for /QA boot-sector + FAT sampling (up to 1024 b/sec) }
  EstBuf         : array[0..1023] of Byte;

{ =========================================================================== }
{ STRING FORMATTING UTILITIES                                                 }
{ =========================================================================== }

{ Pads a string on the right side with spaces up to the target Width.
  FillChar-based: the old one-char-at-a-time loop performed a full string
  copy per appended space. }
function PadRight(const S: string; Width: Integer): string;
var
  Temp: string;
begin
  Temp := S;
  if Length(Temp) < Width then
  begin
    FillChar(Temp[Length(Temp) + 1], Width - Length(Temp), ' ');
    Temp[0] := Chr(Width);
  end;
  PadRight := Temp;
end;

{ Pads a string on the left side with spaces up to the target Width }
function PadLeft(const S: string; Width: Integer): string;
var
  Temp: string;
begin
  if Length(S) >= Width then
    PadLeft := S
  else
  begin
    FillChar(Temp[1], Width - Length(S), ' ');
    if Length(S) > 0 then
      Move(S[1], Temp[Width - Length(S) + 1], Length(S));
    Temp[0] := Chr(Width);
    PadLeft := Temp;
  end;
end;

{ Converts all characters in a string to uppercase }
function ToUpperStr(const S: string): string;
var
  I: Integer;
  Temp: string;
begin
  Temp := S;
  for I := 1 to Length(Temp) do
    Temp[I] := UpCase(Temp[I]);
  ToUpperStr := Temp;
end;

{ Converts all characters in a string to lowercase }
function ToLowerStr(const S: string): string;
var
  I: Integer;
  Temp: string;
begin
  Temp := S;
  for I := 1 to Length(Temp) do
    if Temp[I] in ['A'..'Z'] then
      Temp[I] := Chr(Ord(Temp[I]) + 32);
  ToLowerStr := Temp;
end;

{ =========================================================================== }
{ DATA FORMATTING UTILITIES                                                   }
{ =========================================================================== }

{ Reads the active DOS country information (Int 21h AH=38h) and captures
  the thousands/decimal separators, date/time separators, date field
  order, and the 12/24-hour clock preference, so output matches what
  real DIR prints under any COUNTRY= }
procedure InitCountry;
var
  Regs : Registers;
  Buf  : array[0..33] of Byte;
begin
  { Safe US-style defaults if the call fails (24-hour clock kept as the
    program default; /T can still force am/pm) }
  ThousandsSep := ',';
  DecimalSep   := '.';
  DateSep      := '-';
  TimeSep      := ':';
  DateFmt      := 0;
  OptAmPm      := False;

  FillChar(Regs, SizeOf(Regs), 0);
  FillChar(Buf, SizeOf(Buf), 0);
  Regs.AX := $3800;  { AL=0: current country }
  Regs.DS := Seg(Buf);
  Regs.DX := Ofs(Buf);
  Intr($21, Regs);

  if (Regs.Flags and FCarry) = 0 then
  begin
    DateFmt := Buf[0] or (Word(Buf[1]) shl 8);
    if DateFmt > 2 then DateFmt := 0;
    if Buf[7]  <> 0 then ThousandsSep := Chr(Buf[7]);   { ofs 07h }
    if Buf[9]  <> 0 then DecimalSep   := Chr(Buf[9]);   { ofs 09h }
    if Buf[11] <> 0 then DateSep      := Chr(Buf[11]);  { ofs 0Bh }
    if Buf[13] <> 0 then TimeSep      := Chr(Buf[13]);  { ofs 0Dh }
    { ofs 11h: time format, bit 0 = 0 -> 12-hour, 1 -> 24-hour.
      This sets the DEFAULT; the /T switch (parsed later) overrides. }
    OptAmPm := (Buf[17] and 1) = 0;
  end;
end;

{ Inserts thousands separators into a raw digit string. Single
  right-to-left pass into a fixed buffer: the old version prepended one
  char at a time (a full string copy per digit, O(N squared)) and ran an
  ~80-cycle DIV ('mod 3') per digit; this uses a rolling counter and one
  final Move. Buffer of 40 covers 64-bit values with separators + sign. }
function CommaFy(const Raw: string): string;
var
  Buf        : string[40];
  ResultStr  : string;
  I, O       : Integer;
  DigitCount : Integer;
begin
  O := 40;
  DigitCount := 0;
  for I := Length(Raw) downto 1 do
  begin
    { Separator before every 4th digit; never adjacent to a minus sign }
    if (Raw[I] <> '-') and (DigitCount = 3) then
    begin
      Buf[O] := ThousandsSep;
      Dec(O);
      DigitCount := 0;
    end;
    Buf[O] := Raw[I];
    Dec(O);
    if Raw[I] <> '-' then
      Inc(DigitCount);
  end;
  ResultStr[0] := Chr(40 - O);
  Move(Buf[O + 1], ResultStr[1], 40 - O);
  CommaFy := ResultStr;
end;

{ Converts a LongInt to a comma-separated string (1234567 -> 1,234,567) }
function FormatNumber(Value: LongInt): string;
var
  Raw: string;
begin
  Str(Value, Raw);
  FormatNumber := CommaFy(Raw);
end;

{ Converts a 64-bit value to a comma-separated string }
function FormatBig(Value: Big): string;
var
  Raw: string;
begin
{$IFDEF FPC}
  Str(Value, Raw);
{$ELSE}
  Str(Value:0:0, Raw);   { Comp printed via real syntax, 0 decimals }
{$ENDIF}
  FormatBig := CommaFy(Raw);
end;

{ /H: renders a byte count as a human-readable size. Bytes below 1024
  stay plain; one decimal below 10 units ('1,4 MB'), whole numbers above
  ('156 MB'). Base 1024; the decimal separator follows COUNTRY=. }
function HumanBig(V: Big): string;
var
  UnitVal    : Big;
  UnitStr    : string[2];
  Tenths     : LongInt;
  Whole, Fr  : LongInt;
  WStr, FStr : string[12];
begin
  if V < 1024 then
  begin
    HumanBig := FormatBig(V);
    Exit;
  end;

  UnitVal := 1024;
  UnitStr := 'KB';
  if V >= UnitVal * 1024 then
  begin
    UnitVal := UnitVal * 1024;
    UnitStr := 'MB';
  end;
  if V >= UnitVal * 1024 then
  begin
    UnitVal := UnitVal * 1024;
    UnitStr := 'GB';
  end;

  { One division gives tenths of a unit; bounded by 10239 so it always
    fits an Integer regardless of magnitude }
  Tenths := Trunc((V * 10) / UnitVal);
  Whole  := Tenths div 10;
  Fr     := Tenths mod 10;

  if Whole < 10 then
  begin
    Str(Whole, WStr);
    Str(Fr, FStr);
    HumanBig := WStr + DecimalSep + FStr + ' ' + UnitStr;
  end
  else
    HumanBig := FormatNumber(Whole) + ' ' + UnitStr;
end;

{ /H helper for 32-bit file sizes }
function HumanSize(V: LongInt): string;
var
  T: Big;
begin
  T := V;
  HumanSize := HumanBig(T);
end;

{ Formats a byte count for the 17-wide summary/free-space fields:
  human-readable with /H, exact grouped digits + ' bytes' otherwise }
function FmtSize17(V: Big): string;
begin
  if OptHuman then
    FmtSize17 := PadLeft(HumanBig(V), 17)
  else
    FmtSize17 := PadLeft(FormatBig(V), 17) + ' bytes';
end;

{ Unpacks DOS date/time format and formats it into human-readable strings }
procedure FormatDateTime(DateTimePack: LongInt; var DateStr, TimeStr: string);
var
  DT: DateTime;
  Hour12: Word;
  AmPm: Char;
  HStr, MStr, DStr, MoStr, YStr: string;
begin
  UnpackTime(DateTimePack, DT);

  { Format Date: MM-DD-YY }
  Str(DT.Month:2, MoStr);
  if MoStr[1] = ' ' then MoStr[1] := '0';

  Str(DT.Day:2, DStr);
  if DStr[1] = ' ' then DStr[1] := '0';

  Str((DT.Year mod 100):2, YStr);
  if YStr[1] = ' ' then YStr[1] := '0';

  { Assemble the date in the country's field order and separator }
  case DateFmt of
    1: DateStr := DStr + DateSep + MoStr + DateSep + YStr;  { dd mm yy }
    2: DateStr := YStr + DateSep + MoStr + DateSep + DStr;  { yy mm dd }
  else
    DateStr := MoStr + DateSep + DStr + DateSep + YStr;     { mm dd yy }
  end;

  if OptAmPm then
  begin
    { /T: 12-hour format HH:MMa / HH:MMp }
    if DT.Hour >= 12 then
    begin
      AmPm := 'p';
      if DT.Hour > 12 then
        Hour12 := DT.Hour - 12
      else
        Hour12 := 12;
    end
    else
    begin
      AmPm := 'a';
      if DT.Hour = 0 then
        Hour12 := 12
      else
        Hour12 := DT.Hour;
    end;

    Str(Hour12:2, HStr);
    Str(DT.Min:2, MStr);
    if MStr[1] = ' ' then MStr[1] := '0';

    TimeStr := HStr + TimeSep + MStr + AmPm;
  end
  else
  begin
    { Default: 24-hour format HH:MM (zero-padded) }
    Str(DT.Hour:2, HStr);
    if HStr[1] = ' ' then HStr[1] := '0';
    Str(DT.Min:2, MStr);
    if MStr[1] = ' ' then MStr[1] := '0';

    { Trailing space keeps the column exactly as wide as the am/pm
      variant so /T and default output align identically }
    TimeStr := HStr + TimeSep + MStr + ' ';
  end;
end;

{ Packs up to 3 extension characters into a LongInt lookup key }
function PackExt(C1, C2, C3: Byte): LongInt;
var
  K: LongInt;
begin
  LongRec(K).Lo := Word(C1) or (Word(C2) shl 8);
  LongRec(K).Hi := C3;
  PackExt := K;
end;

{ Adds a space-separated list of UPPERCASE extensions to the color table }
procedure AddExtGroup(const List: string; Attr: Byte);
var
  I       : Integer;
  C       : array[1..3] of Byte;
  N       : Integer;

  procedure Flush;
  begin
    if (N > 0) and (ExtCount < EXT_TABLE_MAX) then
    begin
      Inc(ExtCount);
      ExtTable[ExtCount].Key  := PackExt(C[1], C[2], C[3]);
      ExtTable[ExtCount].Attr := Attr;
    end;
    C[1] := 0; C[2] := 0; C[3] := 0;
    N := 0;
  end;

begin
  C[1] := 0; C[2] := 0; C[3] := 0;
  N := 0;
  for I := 1 to Length(List) do
  begin
    if List[I] = ' ' then
      Flush
    else if N < 3 then
    begin
      Inc(N);
      C[N] := Ord(List[I]);
    end;
  end;
  Flush;
end;

{ Builds the /C extension color table. First match wins, so the most
  common group (executables) is loaded first. On MDA/Hercules the dark
  gray "junk" color would be invisible, so it degrades to normal there. }
procedure InitExtColors;
var
  JunkAttr: Byte;
begin
  ExtCount := 0;

  AddExtGroup('COM EXE BAT', CLR_EXEC);

  { Archives & disk images }
  AddExtGroup('ZIP ARJ LZH LHA ARC PAK ZOO SQZ ICE HA UC2 RAR ' +
              '7Z GZ TGZ TAR CAB BZ2 ' +
              'IMG IMA DSK TD0 IMD VFD 360 720', CLR_ARCH);

  { Documents, text & configs }
  AddExtGroup('TXT DOC ME 1ST NFO DIZ FAQ NOW HLP MAN ASC WRI LOG ' +
              'INI CFG', CLR_DOCS);

  { Media: images, sampled audio, sequenced music, animation/video }
  AddExtGroup('GIF PCX BMP JPG JPE TIF PNG TGA LBM IFF ' +
              'WAV VOC SND AU MID CMF MOD S3M XM IT STM 669 MTM ' +
              'FLI FLC AVI MPG MPE', CLR_MEDIA);

  { Source code }
  AddExtGroup('PAS ASM C H CPP HPP BAS INC MAK DPR FOR PRG PY RC DEF',
              CLR_SRC);

  { Backups & temp files: de-emphasized - except on mono adapters,
    where attribute $08 renders invisible }
  if MonoMode then
    JunkAttr := CLR_NORMAL
  else
    JunkAttr := CLR_JUNK;
  AddExtGroup('BAK TMP OLD', JunkAttr);
end;

{ =========================================================================== }
{ OUTPUT AND PAGING UTILITIES                                                 }
{ =========================================================================== }

{ Returns True when STDOUT is the console (Int 21h AX=4400h IOCTL:
  DX bit 7 = handle is a device, bit 1 = it is the standard output device).
  When redirected to a file or pipe, /C color is silently disabled so the
  captured output stays clean. }
function StdOutIsConsole: Boolean;
var
  Regs: Registers;
begin
  FillChar(Regs, SizeOf(Regs), 0);
  Regs.AX := $4400;
  Regs.BX := 1; { STDOUT handle }
  Intr($21, Regs);
  StdOutIsConsole := ((Regs.Flags and FCarry) = 0) and
                     ((Regs.DX and $80) <> 0) and
                     ((Regs.DX and $02) <> 0);
end;

{ Writes a string with a text attribute. Colorless mode passes straight
  through to (buffered) DOS output. Color mode writes character+attribute
  words directly to video memory and scrolls via BIOS Int 10h/06h - this
  needs no ANSI.SYS and no CRT unit, and is faster than DOS teletype.
  Handles CR, LF, wrap, and scroll; syncs the BIOS cursor afterwards. }
{$IFNDEF FPC}
{ Programs the 6845 CRTC start-address register pair (0Ch/0Dh): the
  visible top-left of the screen moves to the given WORD offset, so the
  hardware scrolls the display with zero memory copying. Color CRTC at
  3D4h; the mono path never calls this. A 16-bit OUT writes the index
  to 3D4h and the data to 3D5h in one bus operation. }
procedure SetCRTCStart(WordOfs: Word); assembler;
asm
  mov  bx, WordOfs
  mov  dx, 03D4h
  mov  al, 0Ch          { Start Address High }
  mov  ah, bh
  out  dx, ax
  mov  al, 0Dh          { Start Address Low }
  mov  ah, bl
  out  dx, ax
end;

{ Fills WordCount words of VRAM with BlankWord at full bus speed.
  REP STOSW replaces a Pascal indexed loop that spent most of its
  cycles on counter/branch overhead. }
procedure FastBlank(Seg0, Ofs0, WordCount, BlankWord: Word); assembler;
asm
  mov  es, Seg0
  mov  di, Ofs0
  mov  cx, WordCount
  mov  ax, BlankWord
  cld
  rep  stosw
end;

{ Blits Count printable characters from PSrc to VidSeg:Ofs0 with the
  given attribute. LODSB/STOSW run inside the 8088 prefetch queue -
  several times faster than the compiled per-character loop. Control
  characters never reach this routine; OutStr splits runs around them. }
procedure BlitRun(Ofs0: Word; PSrc: Pointer; Count: Word; Attr: Byte); assembler;
asm
  push ds
  mov  es, VidSeg
  mov  di, Ofs0
  mov  cx, Count
  mov  ah, Attr
  lds  si, PSrc
  cld
  jcxz @Done
@CharLoop:
  lodsb
  stosw
  loop @CharLoop
@Done:
  pop  ds
end;
{$ENDIF}

{ Captures video geometry and cursor position from the BIOS Data Area
  once, the first time colored output happens }
procedure InitVideoState;
begin
  if VidInited then Exit;
  VidInited := True;
  VidCols     := MemW[$0040:$004A];
  VidRowBytes := VidCols shl 1;
  VidPage     := Mem[$0040:$0062];
  if MonoMode then
    VidSeg := $B000
  else
    VidSeg := $B800;
  CurCol := Mem[$0040 : $0050 + Word(VidPage) * 2];
  CurRow := Mem[$0040 : $0051 + Word(VidPage) * 2];
  VisOfs := MemW[$0040:$004E];
{$IFDEF FPC}
  HwScrollOK := False;   { No port I/O to the CRTC from this build }
{$ELSE}
  HwScrollOK := not MonoMode;  { MDA has only 4 KB - no ring to slide in }
{$ENDIF}
end;

{ Writes the software cursor position to the hardware cursor. Deferred:
  called only at the /P pause and at program exit instead of after every
  string - each call is an Int 10h dispatch the 8088 can ill afford. }
procedure SyncHardwareCursor;
var
  Regs: Registers;
begin
  if not (ColorActive and VidInited) then Exit;
  FillChar(Regs, SizeOf(Regs), 0);
  Regs.AH := $02;
  Regs.BH := VidPage;
  Regs.DH := CurRow;
  Regs.DL := CurCol;
  Intr($10, Regs);
end;

{ Puts the screen back the way DOS expects it: visible window copied to
  VRAM offset 0, CRTC start reset, BDA synced, hardware cursor parked.
  Installed as an ExitProc so even Halt or a runtime error can't leave
  the user's prompt on a shifted screen. }
procedure RestoreVideo;
begin
  if not (ColorActive and VidInited) then Exit;
{$IFNDEF FPC}
  if HwScrollOK and (VisOfs <> 0) then
  begin
    Move(Ptr(VidSeg, VisOfs)^, Ptr(VidSeg, 0)^,
         Word(LinesOnScreen) * VidRowBytes);
    VisOfs := 0;
    SetCRTCStart(0);
    MemW[$0040:$004E] := 0;
  end;
{$ENDIF}
  SyncHardwareCursor;
end;

{$F+}
procedure VideoExitProc;
begin
  ExitProc := ExitSave;
  RestoreVideo;
end;
{$F-}

{ Writes a string with a text attribute. Colorless mode passes straight
  through to (buffered) DOS output. Color mode blits runs of printable
  characters directly into video memory and scrolls via the CRTC start
  address (hardware, zero-copy, one smooth line at a time) - falling
  back to software jump scroll on MDA and BIOS scroll under FPC. The
  hardware cursor is NOT touched here; see SyncHardwareCursor. }
procedure OutStr(const S: string; Attr: Byte);
var
  I, J    : Integer;
  RunLen  : Word;
  Rows    : Byte;
  VOfs    : Word;
{$IFDEF FPC}
  Regs    : Registers;
  K       : Integer;
{$ENDIF}

  procedure ScrollCheck;
  begin
    if CurRow < Rows then Exit;
{$IFNDEF FPC}
    if HwScrollOK then
    begin
      { Ring wrap: if the window would slide past 16 KB, copy the
        visible screen back to offset 0 first (rare: every ~77 lines) }
      if VisOfs + (Word(Rows) + 1) * VidRowBytes > RING_BYTES then
      begin
        Move(Ptr(VidSeg, VisOfs)^, Ptr(VidSeg, 0)^,
             Word(Rows) * VidRowBytes);
        VisOfs := 0;
        SetCRTCStart(0);
        MemW[$0040:$004E] := 0;
        VOfs := (Word(CurRow) * VidCols + CurCol) shl 1;
      end;

      { Slide the hardware window down one row and blank the line that
        just became the bottom. VOfs is deliberately NOT adjusted: the
        origin advanced by exactly the amount the row number dropped. }
      Inc(VisOfs, VidRowBytes);
      SetCRTCStart(VisOfs shr 1);
      MemW[$0040:$004E] := VisOfs;   { Keep the BIOS's view coherent }
      FastBlank(VidSeg, VisOfs + Word(Rows - 1) * VidRowBytes, VidCols,
                Word(Ord(' ')) or (Word(CLR_NORMAL) shl 8));
      CurRow := Rows - 1;
    end
    else
    begin
      { MDA/Hercules: 4 KB VRAM, no ring - software jump scroll }
      Move(Ptr(VidSeg, Word(SCROLL_STEP) * VidRowBytes)^,
           Ptr(VidSeg, 0)^,
           Word(Rows - SCROLL_STEP) * VidRowBytes);
      FastBlank(VidSeg, Word(Rows - SCROLL_STEP) * VidRowBytes,
                Word(SCROLL_STEP) * VidCols,
                Word(Ord(' ')) or (Word(CLR_NORMAL) shl 8));
      CurRow := Rows - SCROLL_STEP;
      Dec(VOfs, Word(SCROLL_STEP) * VidRowBytes);
    end;
{$ELSE}
    { Protected mode: BIOS jump scroll }
    FillChar(Regs, SizeOf(Regs), 0);
    Regs.AH := $06;
    Regs.AL := SCROLL_STEP;
    Regs.BH := CLR_NORMAL;
    Regs.CH := 0;
    Regs.CL := 0;
    Regs.DH := Rows - 1;
    Regs.DL := Byte(VidCols) - 1;
    Intr($10, Regs);
    CurRow := Rows - SCROLL_STEP;
    Dec(VOfs, Word(SCROLL_STEP) * VidRowBytes);
{$ENDIF}
  end;

begin
  if not ColorActive then
  begin
    Write(S);
    Exit;
  end;

  InitVideoState;
  Rows := Byte(LinesOnScreen);
  { One multiply per string; inside the loop the offset only increments }
  VOfs := VisOfs + (Word(CurRow) * VidCols + CurCol) shl 1;

  I := 1;
  while I <= Length(S) do
  begin
    case S[I] of
      #13: begin
             Dec(VOfs, Word(CurCol) shl 1);
             CurCol := 0;
             Inc(I);
           end;
      #10: begin
             Inc(CurRow);
             Inc(VOfs, VidRowBytes);
             Inc(I);
             ScrollCheck;
           end;
    else
      begin
        { Gather the longest run of printable characters that fits on
          the current row, then blit it in one shot }
        J := I;
        RunLen := 0;
        while (J <= Length(S)) and (S[J] <> #13) and (S[J] <> #10) and
              (RunLen < VidCols - CurCol) do
        begin
          Inc(J);
          Inc(RunLen);
        end;
{$IFNDEF FPC}
        BlitRun(VOfs, @S[I], RunLen, Attr);
{$ELSE}
        for K := 0 to Integer(RunLen) - 1 do
          MemW[VidSeg : VOfs + Word(K) shl 1] :=
            Word(Ord(S[I + K])) or (Word(Attr) shl 8);
{$ENDIF}
        Inc(VOfs, RunLen shl 1);
        Inc(CurCol, RunLen);
        I := J;
        if CurCol >= VidCols then
        begin
          CurCol := 0;
          Inc(CurRow);
          ScrollCheck;   { VOfs already sits at the start of the next row }
        end;
      end;
    end;
  end;
end;

{ Writes a string followed by CR/LF, honoring the attribute }
procedure OutLn(const S: string; Attr: Byte);
begin
  if not ColorActive then
    WriteLn(S)
  else
    OutStr(S + #13#10, Attr);
end;

{ Waits for a keystroke via BIOS Int 16h, AH=00h. Replaces Crt.ReadKey.
  Unlike Crt's two-byte protocol, one BIOS call consumes the whole key
  (ASCII in AL, scan code in AH), so extended keys need no second read. }
function WaitForKey: Char;
var
  Regs: Registers;
begin
  FillChar(Regs, SizeOf(Regs), 0);
  Regs.AH := $00;
  Intr($16, Regs);
  WaitForKey := Chr(Regs.AL);
end;

{ Pauses output and waits for user keystroke if /P flag is active }
procedure HandlePaging;
var
  Ch: Char;
begin
  if not OptPage then Exit;

  Inc(CurrentLine);
  if CurrentLine >= (LinesOnScreen - 1) then
  begin
    OutStr('Press any key to continue . . .', CLR_NORMAL);
    if not ColorActive then Flush(Output);  { Show buffered lines first }
    SyncHardwareCursor;  { Deferred cursor: park it visibly at the prompt }
    Ch := WaitForKey;
    OutStr(#13 + '                                ' + #13, CLR_NORMAL);
    if not ColorActive then Flush(Output);
    CurrentLine := 0;
  end;
end;

{ Prints a line with an explicit color attribute and accounts for paging }
procedure PrintLineC(const S: string; Attr: Byte);
begin
  OutLn(S, Attr);
  HandlePaging;
end;

{ Prints a line of text in the normal attribute }
procedure PrintLine(const S: string);
begin
  PrintLineC(S, CLR_NORMAL);
end;

{ =========================================================================== }
{ VOLUME & FREE SPACE LOGIC                                                   }
{ =========================================================================== }

{ Prints the volume label and serial number for the given drive }
procedure PrintVolumeHeader(DriveLetter: Char);
var
  Regs       : Registers;
  SR         : SearchRec;
  DriveNum   : Byte;
  RootPath   : string[4];
  MediaID    : record
    InfoLevel  : Word;
    Serial     : LongInt;
    VolLabel   : array[1..11] of Char;
    FileSystem : array[1..8] of Char;
  end;
  SerialStr  : string[9];
  VolFound   : Boolean;
  VolName    : string[12];
  I, DotPos  : Integer;
begin
  if OptBare then Exit;

  DriveLetter := UpCase(DriveLetter);
  DriveNum := Ord(DriveLetter) - Ord('A') + 1;

  { The volume label lives ONLY in the root directory, so search X:\*.*
    explicitly (searching 'X:' would scan the drive's CURRENT directory).
    FindFirst attribute masks are INCLUSIVE - normal files also match -
    so loop until an entry that really has the volume bit is found. }
  RootPath := DriveLetter + ':\';
  VolFound := False;
  VolName  := '';

  FindFirst(RootPath + '*.*', ATTR_VOLUME, SR);
  while (DosError = 0) and not VolFound do
  begin
    if (SR.Attr and ATTR_VOLUME) <> 0 then
    begin
      VolFound := True;
      VolName := SR.Name;
      { DOS returns 8.3-mangled labels with an embedded dot
        (e.g. MYVOLUME.LBL) - strip it for display }
      DotPos := Pos('.', VolName);
      if DotPos > 0 then
        Delete(VolName, DotPos, 1);
    end
    else
      FindNext(SR);
  end;
{$IFDEF FPC}
  FindClose(SR);
{$ENDIF}

  if VolFound and (VolName <> '') then
    PrintLine(' Volume in drive ' + DriveLetter + ' is ' + VolName)
  else
    PrintLine(' Volume in drive ' + DriveLetter + ' has no label.');

  { Get Volume Serial Number via Int 21h AX=6900h }
  FillChar(MediaID, SizeOf(MediaID), 0);
  FillChar(Regs, SizeOf(Regs), 0);
  Regs.AX := $6900;
  Regs.BL := DriveNum;
  Regs.DS := Seg(MediaID);
  Regs.DX := Ofs(MediaID);
  Intr($21, Regs);

  if (Regs.Flags and FCarry) = 0 then
  begin
    SerialStr := '';
    for I := 28 downto 0 do
    begin
      if (I = 12) then SerialStr := SerialStr + '-';
      if (I mod 4 = 0) then
      begin
        case ((MediaID.Serial shr I) and $0F) of
          0..9   : SerialStr := SerialStr + Chr(((MediaID.Serial shr I) and $0F) + 48);
          10..15 : SerialStr := SerialStr + Chr(((MediaID.Serial shr I) and $0F) + 55);
        end;
      end;
    end;
    PrintLine(' Volume Serial Number is ' + SerialStr);
  end;
end;

{ --------------------------------------------------------------------------- }
{ /QA QUICK FREE-SPACE ESTIMATE                                               }
{ Reads the boot sector, then samples EST_SAMPLES sectors spread evenly       }
{ across the FAT and extrapolates the free-cluster ratio. ~9 sector reads     }
{ instead of DOS scanning the entire FAT (which is what makes plain DIR       }
{ crawl on big FAT16 partitions the first time). FAT16 + DOS 4+ only;         }
{ anything else falls back to the exact methods automatically.                }
{ --------------------------------------------------------------------------- }

{$IFNDEF FPC}
{ Absolute logical-sector read via Int 25h, packet method (DOS 3.31+/4+,
  required for partitions > 32 MB). Drive0 is 0-based (0=A). Int 25h
  leaves the old FLAGS on the stack and may clobber most registers, so
  this must be done in asm rather than through Intr(). }
function AbsDiskRead(Drive0: Byte; Sector: LongInt;
                     BufSeg, BufOfs: Word): Boolean;
var
  Pkt: record
    Sec : LongInt;
    Cnt : Word;
    BO  : Word;
    BS  : Word;
  end;
  Ok: Byte;
begin
  Pkt.Sec := Sector;
  Pkt.Cnt := 1;
  Pkt.BO  := BufOfs;
  Pkt.BS  := BufSeg;
  asm
    push ds
    push bp
    lea  bx, Pkt          { DS:BX -> disk address packet (local: SS-based) }
    mov  al, Drive0
    mov  cx, 0FFFFh       { CX=FFFF selects the packet method }
    push ss
    pop  ds
    int  25h
    sbb  al, al           { AL = FF on carry (error), 00 on success }
    popf                  { Int 25h leaves original FLAGS on the stack }
    pop  bp
    pop  ds
    mov  Ok, al
  end;
  AbsDiskRead := (Ok = 0);
end;
{$ELSE}
{ Real-mode Int 25h is unavailable from protected mode; /QA falls back
  to the exact free-space methods under Free Pascal builds. }
function AbsDiskRead(Drive0: Byte; Sector: LongInt;
                     BufSeg, BufOfs: Word): Boolean;
begin
  AbsDiskRead := False;
end;
{$ENDIF}

{ Estimates free space by FAT sampling. Returns False when the estimate
  cannot be made (FAT12/FAT32, odd geometry, read errors, DOS < 4), in
  which case the caller should use an exact method. Exact is returned
  True when the FAT was small enough that every sector was read, making
  the "estimate" actually an exact count. }
function EstimateFreeSpace(DriveNum: Byte; var FreeBytes: Big;
                           var Exact: Boolean): Boolean;
var
  BytesPerSec  : Word;
  SecPerClus   : Byte;
  ResvSecs     : Word;
  NumFATs      : Byte;
  RootEnt      : Word;
  SecPerFAT    : Word;
  TotSecs      : LongInt;
  RootDirSecs  : LongInt;
  DataStart    : LongInt;
  TotalClus    : LongInt;
  MaxCluster   : LongInt;
  EPS          : Word;     { FAT16 entries per FAT sector }
  SampCount    : Word;
  Step         : Word;
  K, I         : Word;
  SecIdx       : LongInt;
  GIdx         : LongInt;
  Sampled      : LongInt;
  FreeCnt      : LongInt;
  FreeClusters : LongInt;
begin
  EstimateFreeSpace := False;
  Exact := False;

  { Packet-method Int 25h (32-bit sector, CX=FFFFh) exists since
    Compaq DOS 3.31 - the release that introduced >32 MB partitions -
    not just 4.0. Reject strictly below 3.31: }
  if (Lo(DosVersion) < 3) or
     ((Lo(DosVersion) = 3) and (Hi(DosVersion) < 31)) then Exit;

  { Read the boot sector and pull the BPB apart }
  if not AbsDiskRead(DriveNum - 1, 0, Seg(EstBuf), Ofs(EstBuf)) then Exit;

  BytesPerSec := EstBuf[11] or (Word(EstBuf[12]) shl 8);
  SecPerClus  := EstBuf[13];
  ResvSecs    := EstBuf[14] or (Word(EstBuf[15]) shl 8);
  NumFATs     := EstBuf[16];
  RootEnt     := EstBuf[17] or (Word(EstBuf[18]) shl 8);
  TotSecs     := EstBuf[19] or (Word(EstBuf[20]) shl 8);
  SecPerFAT   := EstBuf[22] or (Word(EstBuf[23]) shl 8);
  if TotSecs = 0 then  { large partition: 32-bit total at offset 32 }
    TotSecs := LongInt(EstBuf[32]) or (LongInt(EstBuf[33]) shl 8) or
               (LongInt(EstBuf[34]) shl 16) or (LongInt(EstBuf[35]) shl 24);

  { Sanity checks - bail out to the exact path on anything unusual }
  if (BytesPerSec <> 512) and (BytesPerSec <> 1024) then Exit;
  if (SecPerClus = 0) or (NumFATs = 0) or (SecPerFAT = 0) then Exit;
  if TotSecs <= 0 then Exit;

  RootDirSecs := (LongInt(RootEnt) * 32 + BytesPerSec - 1) div BytesPerSec;
  DataStart   := LongInt(ResvSecs) + LongInt(NumFATs) * SecPerFAT + RootDirSecs;
  TotalClus   := (TotSecs - DataStart) div SecPerClus;

  { FAT16 only: FAT12 FATs are tiny (exact scan is already fast) and
    FAT32 is served exactly by Int 21h AX=7303h on DOS 7.10+ }
  if (TotalClus < 4085) or (TotalClus >= 65525) then Exit;
  MaxCluster := TotalClus + 1;

  EPS := BytesPerSec div 2;
  if SecPerFAT <= EST_SAMPLES then
  begin
    SampCount := SecPerFAT;   { Small FAT: read it all -> exact count }
    Step := 1;
    Exact := True;
  end
  else
  begin
    SampCount := EST_SAMPLES; { Sample sectors spread across the FAT }
    Step := SecPerFAT div EST_SAMPLES;
  end;

  Sampled := 0;
  FreeCnt := 0;
  for K := 0 to SampCount - 1 do
  begin
    SecIdx := LongInt(K) * Step;
    if not AbsDiskRead(DriveNum - 1, LongInt(ResvSecs) + SecIdx,
                       Seg(EstBuf), Ofs(EstBuf)) then Exit;
    for I := 0 to EPS - 1 do
    begin
      GIdx := SecIdx * EPS + I;
      if (GIdx >= 2) and (GIdx <= MaxCluster) then
      begin
        Inc(Sampled);
        if (EstBuf[I * 2] = 0) and (EstBuf[I * 2 + 1] = 0) then
          Inc(FreeCnt);
      end;
    end;
  end;
  if Sampled = 0 then Exit;

  if Exact then
    FreeClusters := FreeCnt
  else
    FreeClusters := TotalClus * FreeCnt div Sampled;  { extrapolate }

  FreeBytes := FreeClusters;
  FreeBytes := FreeBytes * SecPerClus;
  FreeBytes := FreeBytes * BytesPerSec;
  EstimateFreeSpace := True;
end;

{ Retrieves and prints disk free space, smartly handling FAT32 drives }
procedure PrintFreeSpace(DriveLetter: Char);
var
  Regs         : Registers;
  DriveNum     : Byte;
  RootStr      : string[4];
  FAT32Data    : TFAT32FreeSpace;
  BytesFree    : LongInt;
  ClustersFree : LongInt;
  ClusterBytes : LongInt;
  DosVer       : Word;
  Success      : Boolean;
  EstBytes     : Big;
  EstExact     : Boolean;
  FreeBig      : Big;
begin
  if OptBare then Exit;

  { Skip calculation if fast mode is requested }
  if OptSkipFree then
  begin
    PrintLine(PadLeft(FormatNumber(TotalDirs), 16) +
              ' Dir(s)   [Free space scan bypassed]');
    Exit;
  end;

  DriveLetter := UpCase(DriveLetter);
  DriveNum := Ord(DriveLetter) - Ord('A') + 1;
  { AX=7303h requires the ROOT path of the drive, ASCIIZ: "C:\",0 }
  RootStr := DriveLetter + ':\' + #0;
  Success := False;
  BytesFree := 0;

  { Determine DOS Version to safely call FAT32 functions.
    TP's DosVersion returns major in the LOW byte, minor in the HIGH byte. }
  DosVer := DosVersion;

  { Probe for FAT32 ExtGetFreeSpace on any DOS 5+. Gating on version
    7.10 misses environments that support the call but report an older
    version (DOSBox-X defaults to 5.0, FreeDOS setups, SETVER) - their
    own DIR uses the FAT32 API internally, so we must try it too.
    The probe is safe on kernels without it: CF is preset, and old DOS
    returns AL=0 for unknown 73h functions, making AX exactly $7300. }
  if Lo(DosVer) >= 5 then
  begin
    FillChar(FAT32Data, SizeOf(FAT32Data), 0);
    FAT32Data.StructureSize := SizeOf(FAT32Data);

    { Regs MUST be zeroed: TP's Intr loads CPU flags from the record,
      and garbage direction/trap flag bits make DOS calls fail randomly }
    FillChar(Regs, SizeOf(Regs), 0);
    Regs.AX := $7303; { ExtGetFreeSpace }
    Regs.DS := Seg(RootStr[1]);
    Regs.DX := Ofs(RootStr[1]);
    Regs.ES := Seg(FAT32Data);
    Regs.DI := Ofs(FAT32Data);
    Regs.CX := SizeOf(FAT32Data);
    Regs.Flags := FCarry; { Preset CF: unsupported call leaves it set }
    Intr($21, Regs);

    if ((Regs.Flags and FCarry) = 0) and (Regs.AX <> $7300) and
       { Sanity-check the returned structure before trusting it }
       (FAT32Data.SectorsPerCluster > 0) and
       (FAT32Data.SectorsPerCluster <= 128) and
       (FAT32Data.BytesPerSector >= 128) and
       (FAT32Data.BytesPerSector <= 4096) and
       (FAT32Data.AvailableClusters >= 0) and
       (FAT32Data.AvailableClusters <= FAT32Data.TotalClusters) then
    begin
      ClusterBytes := FAT32Data.SectorsPerCluster * FAT32Data.BytesPerSector;
      if ClusterBytes > 0 then
      begin
        { 64-bit math: large FAT32 volumes exceed LongInt range, and
          real DIR prints the exact byte count - so do we }
        FreeBig := FAT32Data.AvailableClusters;
        FreeBig := FreeBig * ClusterBytes;
        PrintLine(PadLeft(FormatNumber(TotalDirs), 16) + ' Dir(s) ' +
                  FmtSize17(FreeBig) + ' free');
        Exit;
      end;
    end;
  end;

  { /QA: sampled FAT estimate - only reached when the fast FAT32 call
    didn't apply (i.e. FAT16 under DOS 4.x-6.x, the slow case) }
  if (not Success) and OptEstimate then
  begin
    if EstimateFreeSpace(DriveNum, EstBytes, EstExact) then
    begin
      if EstExact then
        PrintLine(PadLeft(FormatNumber(TotalDirs), 16) + ' Dir(s) ' +
                  FmtSize17(EstBytes) + ' free')
      else if OptHuman then
        PrintLine(PadLeft(FormatNumber(TotalDirs), 16) + ' Dir(s) ' +
                  PadLeft('~' + HumanBig(EstBytes), 17) + ' free (est.)')
      else
        PrintLine(PadLeft(FormatNumber(TotalDirs), 16) + ' Dir(s) ' +
                  PadLeft('~' + FormatBig(EstBytes), 17) +
                  ' bytes free (est.)');
      Exit;
    end;
    { Estimate not possible on this drive/DOS - fall through to exact }
  end;

  { Fallback to legacy DOS Int 21h AH=36h (Get Free Space) }
  if not Success then
  begin
    FillChar(Regs, SizeOf(Regs), 0);
    Regs.AH := $36;
    Regs.DL := DriveNum;
    Intr($21, Regs);

    if Regs.AX <> $FFFF then
    begin
      ClustersFree := LongInt(Regs.BX);
      ClusterBytes := LongInt(Regs.AX) * LongInt(Regs.CX);
      if (ClusterBytes > 0) and (ClustersFree < ($7FFFFFFF div ClusterBytes)) then
      begin
        BytesFree := ClustersFree * ClusterBytes;
        Success := True;
      end;
    end;
  end;

  { Final output generation }
  if Success then
  begin
    { Under Windows NT/2000/XP the DOS box (NTVDM) caps AH=36h results,
      so the figure is a floor, not the real free space - say so }
    FreeBig := BytesFree;
    if GetEnv('OS') = 'Windows_NT' then
      PrintLine(PadLeft(FormatNumber(TotalDirs), 16) + ' Dir(s) ' +
                FmtSize17(FreeBig) + ' free (NT cap)')
    else
      PrintLine(PadLeft(FormatNumber(TotalDirs), 16) + ' Dir(s) ' +
                FmtSize17(FreeBig) + ' free');
  end
  else
    PrintLine(PadLeft(FormatNumber(TotalDirs), 16) +
              ' Dir(s)   [Free space unavailable]');
end;

{ =========================================================================== }
{ SORTING ENGINE                                                              }
{ =========================================================================== }

{ Compares two LongInts as UNSIGNED 32-bit values. DOS packed timestamps
  use bit 31 for years >= 2044, so a signed comparison would sort such
  files (common on flash cards written with unset RTCs) before 1980.
  LongRec casts read the halves directly - 'shr 16' would cost a 16-step
  shift loop per call on the 8088, in the sort's hottest path. }
function CmpUnsigned(A, B: LongInt): Integer;
begin
  if LongRec(A).Hi < LongRec(B).Hi then CmpUnsigned := -1
  else if LongRec(A).Hi > LongRec(B).Hi then CmpUnsigned := 1
  else if LongRec(A).Lo < LongRec(B).Lo then CmpUnsigned := -1
  else if LongRec(A).Lo > LongRec(B).Lo then CmpUnsigned := 1
  else CmpUnsigned := 0;
end;

{ Compares two file entries based on the currently selected SortKey }
function CompareEntries(E1, E2: PFileEntry): Integer;
var
  ResultVal  : Integer;
begin
  ResultVal := 0;

  { Priority 1: Handle Directory Grouping if requested }
  if OptGroupDirs and
     ((E1^.Attr and ATTR_DIRECTORY) <> (E2^.Attr and ATTR_DIRECTORY)) then
  begin
    if (E1^.Attr and ATTR_DIRECTORY) <> 0 then
      ResultVal := -1
    else
      ResultVal := 1;
  end
  else
  begin
    { Priority 2: Primary Sort Logic }
    case SortKey of
      SORT_NAME:
        begin
          if E1^.Name < E2^.Name then ResultVal := -1
          else if E1^.Name > E2^.Name then ResultVal := 1;
        end;

      SORT_EXT:
        begin
          { Extensions were extracted ONCE at insert time; the old code
            re-ran Pos+Copy on both entries for every comparison, i.e.
            O(n log n) times during the quicksort. }
          if E1^.Ext < E2^.Ext then ResultVal := -1
          else if E1^.Ext > E2^.Ext then ResultVal := 1
          else if E1^.Name < E2^.Name then ResultVal := -1
          else if E1^.Name > E2^.Name then ResultVal := 1;
        end;

      SORT_SIZE:
        begin
          if E1^.Size < E2^.Size then ResultVal := -1
          else if E1^.Size > E2^.Size then ResultVal := 1
          else if E1^.Name < E2^.Name then ResultVal := -1
          else if E1^.Name > E2^.Name then ResultVal := 1;
        end;

      SORT_DATE:
        begin
          ResultVal := CmpUnsigned(E1^.Time, E2^.Time);
          if ResultVal = 0 then
          begin
            if E1^.Name < E2^.Name then ResultVal := -1
            else if E1^.Name > E2^.Name then ResultVal := 1;
          end;
        end;
    end;

    { Handle order reversal if negative switch was used }
    if SortReverse then
      ResultVal := -ResultVal;
  end;

  CompareEntries := ResultVal;
end;

{ Recursively sorts the file list using Heap-based Quicksort }
procedure QuickSortEntries(var List: TFileArray; L, R: Integer);
var
  I, J: Integer;
  Pivot, Temp: PFileEntry;
begin
  I := L;
  J := R;
  Pivot := List[(L + R) div 2];

  repeat
    while CompareEntries(List[I], Pivot) < 0 do Inc(I);
    while CompareEntries(List[J], Pivot) > 0 do Dec(J);

    if I <= J then
    begin
      Temp := List[I];
      List[I] := List[J];
      List[J] := Temp;
      Inc(I);
      Dec(J);
    end;
  until I > J;

  if L < J then QuickSortEntries(List, L, J);
  if I < R then QuickSortEntries(List, I, R);
end;

{ =========================================================================== }
{ LONG FILENAME (LFN) API SUPPORT - Int 21h 71xxh (experimental /LFN)         }
{ Available under Win9x DOS, DOSLFN on plain DOS, and Windows NT/XP NTVDM.    }
{ SI=1 requests DOS-format timestamps so no FILETIME conversion is needed.    }
{ =========================================================================== }

{ Opens an LFN search. Detection is triple-layered because real DOS
  returns AL=0 for unknown 71h functions with the CARRY FLAG UNDEFINED:
  (1) AX=$7100 means "unsupported" regardless of carry state,
  (2) the find buffer is sentinel-filled first and genuine success must
      have overwritten it (a real attribute dword never reads FFFFFFFFh),
  (3) carry set with any other code is an ordinary empty-search error. }
function LfnFindFirst(const Mask: string; var Handle: Word): Boolean;
var
  Regs : Registers;
  Spec : string[96];
begin
  LfnFindFirst := False;
  Spec := Mask + #0;
  FillChar(LfnFindBuf, SizeOf(LfnFindBuf), $FF);  { sentinel }
  FillChar(Regs, SizeOf(Regs), 0);
  Regs.AX := $714E;              { LFN FindFirst }
  Regs.CX := ATTR_ANYFILE;       { CL=allowable attrs, CH=required=0 }
  Regs.SI := 1;                  { Return DOS date/time format }
  Regs.DS := Seg(Spec[1]);
  Regs.DX := Ofs(Spec[1]);
  Regs.ES := Seg(LfnFindBuf);
  Regs.DI := Ofs(LfnFindBuf);
  Regs.Flags := FCarry;
  Intr($21, Regs);

  { Unsupported kernel: AX=$7100 in ANY flag state, or the buffer was
    never written despite an apparent success }
  if (Regs.AX = $7100) or
     (((Regs.Flags and FCarry) = 0) and
      (LfnFindBuf[0] = $FF) and (LfnFindBuf[1] = $FF) and
      (LfnFindBuf[2] = $FF) and (LfnFindBuf[3] = $FF)) then
  begin
    LfnActive := False;
    if not LfnWarned then
    begin
      PrintLine(' [LFN API not available - showing 8.3 names]');
      LfnWarned := True;
    end;
    Exit;
  end;

  if (Regs.Flags and FCarry) = 0 then
  begin
    Handle := Regs.AX;
    LfnFindFirst := True;
  end;
  { Carry set with another code: ordinary empty search - stay quiet }
end;

function LfnFindNext(Handle: Word): Boolean;
var
  Regs: Registers;
begin
  FillChar(LfnFindBuf, SizeOf(LfnFindBuf), $FF);  { sentinel }
  FillChar(Regs, SizeOf(Regs), 0);
  Regs.AX := $714F;
  Regs.BX := Handle;
  Regs.SI := 1;
  Regs.ES := Seg(LfnFindBuf);
  Regs.DI := Ofs(LfnFindBuf);
  Regs.Flags := FCarry;
  Intr($21, Regs);
  { Success requires: carry clear, not the "unsupported" code, and the
    kernel really wrote the buffer - all three guard against real DOS
    leaving carry undefined on unknown functions }
  LfnFindNext := ((Regs.Flags and FCarry) = 0) and
                 (Regs.AX <> $7100) and
                 not ((LfnFindBuf[0] = $FF) and (LfnFindBuf[1] = $FF) and
                      (LfnFindBuf[2] = $FF) and (LfnFindBuf[3] = $FF));
end;

{ LFN search handles are a finite kernel resource - always close them }
procedure LfnFindClose(Handle: Word);
var
  Regs: Registers;
begin
  FillChar(Regs, SizeOf(Regs), 0);
  Regs.AX := $71A1;
  Regs.BX := Handle;
  Intr($21, Regs);
end;

{ Unpacks the 714Eh find buffer: attribute dword at 00h, DOS-format
  last-write time dword at 14h, size dword at 20h, long name ASCIIZ at
  2Ch, alternate 8.3 name ASCIIZ at 130h (empty when the long name IS
  already a valid 8.3 name). }
procedure LfnExtract(var E: TFileEntry; var LongName: string);
var
  I  : Integer;
  SN : string[13];
begin
  E.Attr := LfnFindBuf[0];
  Move(LfnFindBuf[$14], E.Time, 4);
  Move(LfnFindBuf[$20], E.Size, 4);
  E.LOfs := 0;
  E.LLen := 0;

  I := 0;
  while (I < 255) and (LfnFindBuf[$2C + I] <> 0) do
  begin
    LongName[I + 1] := Chr(LfnFindBuf[$2C + I]);
    Inc(I);
  end;
  LongName[0] := Chr(I);

  I := 0;
  while (I < 12) and (LfnFindBuf[$130 + I] <> 0) do
  begin
    SN[I + 1] := Chr(LfnFindBuf[$130 + I]);
    Inc(I);
  end;
  SN[0] := Chr(I);

  if SN <> '' then
    E.Name := SN
  else
    E.Name := ToUpperStr(Copy(LongName, 1, 12));
end;

{ =========================================================================== }
{ DIRECTORY PROCESSING                                                        }
{ =========================================================================== }

{ Picks the display attribute for an entry: directories yellow, then a
  packed-integer lookup in the extension color table (executables,
  archives, documents, media, source, junk - first match wins). The 8.3
  name's extension is packed once into a LongInt and compared against
  the table with plain integer compares - no string operations. }
function EntryAttr(const Entry: TFileEntry): Byte;
var
  Key      : LongInt;
  C2, C3   : Byte;
  DotPos   : Integer;
  L, I     : Integer;
begin
  if not ColorActive then
  begin
    EntryAttr := CLR_NORMAL;
    Exit;
  end;

  if (Entry.Attr and ATTR_DIRECTORY) <> 0 then
  begin
    EntryAttr := CLR_DIR;
    Exit;
  end;

  { DOS returns names uppercase, so no case folding is needed }
  DotPos := Pos('.', Entry.Name);
  if (DotPos = 0) or (DotPos = Length(Entry.Name)) then
  begin
    EntryAttr := CLR_NORMAL;
    Exit;
  end;

  L := Length(Entry.Name) - DotPos;   { extension length, 1..3 }
  C2 := 0;
  C3 := 0;
  if L >= 2 then C2 := Ord(Entry.Name[DotPos + 2]);
  if L >= 3 then C3 := Ord(Entry.Name[DotPos + 3]);
  Key := PackExt(Ord(Entry.Name[DotPos + 1]), C2, C3);

  for I := 1 to ExtCount do
    if ExtTable[I].Key = Key then
    begin
      EntryAttr := ExtTable[I].Attr;
      Exit;
    end;

  EntryAttr := CLR_NORMAL;
end;

{ Formats and prints a single file entry according to flags (/W, /B, /L, /C) }
procedure DisplayEntry(const Entry: TFileEntry; const CurrentPath: string);
var
  DisplayStr       : string;
  BaseName, ExtName: string[8];
  DotPos           : Integer;
  DateStr, TimeStr : string;
  OutName          : string[12];
  A                : Byte;
begin
  OutName := Entry.Name;
  A := EntryAttr(Entry);

  { Lowercase conversion if requested }
  if OptLower then
    OutName := ToLowerStr(OutName);

  { Bare mode: Only print the filename, ignoring stats. With /LFN the
    full long name is printed (case preserved, no /L lowering). }
  if OptBare then
  begin
    if (Entry.Name <> '.') and (Entry.Name <> '..') then
    begin
      if OptLFN and (CurLfn <> '') then
      begin
        if OptSubDir then
          PrintLineC(CurrentPath + CurLfn, A)
        else
          PrintLineC(CurLfn, A);
      end
      else if OptSubDir then
        PrintLineC(CurrentPath + OutName, A)
      else
        PrintLineC(OutName, A);
    end;
    Exit;
  end;

  { DR-DOS style /2: two detail columns separated by a box-draw bar.
    Each half is exactly 38 chars; 38 + 3 (separator) + 38 = 79 cols. }
  if Opt2Col then
  begin
    DotPos := Pos('.', OutName);
    if (OutName = '.') or (OutName = '..') then
    begin
      BaseName := OutName;
      ExtName := '';
    end
    else if DotPos > 0 then
    begin
      BaseName := Copy(OutName, 1, DotPos - 1);
      ExtName  := Copy(OutName, DotPos + 1, 3);
    end
    else
    begin
      BaseName := OutName;
      ExtName  := '';
    end;

    if (Entry.Attr and ATTR_DIRECTORY) <> 0 then
      DisplayStr := PadLeft('<DIR>', 10)
    else if OptHuman then
      DisplayStr := PadLeft(HumanSize(Entry.Size), 10)  { max 9 chars }
    else
    begin
      DisplayStr := FormatNumber(Entry.Size);
      if Length(DisplayStr) > 10 then
        Str(Entry.Size, DisplayStr); { > 99 MB: drop commas, keep column }
      DisplayStr := PadLeft(DisplayStr, 10);
    end;

    FormatDateTime(Entry.Time, DateStr, TimeStr);
    DisplayStr := PadRight(BaseName, 8) + ' ' + PadRight(ExtName, 3) +
                  DisplayStr + ' ' + DateStr + ' ' + TimeStr;

    if ColIndex = 0 then
    begin
      OutStr(DisplayStr, A);
      OutStr(' '#179' ', CLR_NORMAL);  { CP437 179 = single vertical bar }
      ColIndex := 1;
    end
    else
    begin
      OutLn(DisplayStr, A);
      HandlePaging;
      ColIndex := 0;
    end;
    Exit;
  end;

  { Wide mode: Pack entries horizontally into columns. With /LFN active,
    3 wider columns (26 chars) replace the classic 5x15 so long names
    fit; names over the cap are truncated with a '>>' marker (CP437 175). }
  if OptWide then
  begin
    if LfnActive and (CurLfn <> '') then
      DisplayStr := CurLfn
    else
      DisplayStr := OutName;

    if (Entry.Attr and ATTR_DIRECTORY) <> 0 then
      DisplayStr := '[' + DisplayStr + ']';

    if LfnActive then
    begin
      if Length(DisplayStr) >= LFN_WIDE_WIDTH then
      begin
        DisplayStr[0] := Chr(LFN_WIDE_WIDTH - 1);   { hard cap }
        DisplayStr[LFN_WIDE_WIDTH - 1] := #175;     { truncation marker }
      end;
      OutStr(PadRight(DisplayStr, LFN_WIDE_WIDTH), A);
      Inc(ColIndex);
      if ColIndex >= LFN_WIDE_COLS then
      begin
        OutLn('', CLR_NORMAL);
        HandlePaging;
        ColIndex := 0;
      end;
    end
    else
    begin
      OutStr(PadRight(DisplayStr, 15), A);
      Inc(ColIndex);
      if ColIndex >= WIDE_COLS then
      begin
        OutLn('', CLR_NORMAL);
        HandlePaging;
        ColIndex := 0;
      end;
    end;
    Exit;
  end;

  { Standard Details mode }
  DotPos := Pos('.', OutName);

  { Split name and extension for tabular alignment }
  if (OutName = '.') or (OutName = '..') then
  begin
    BaseName := OutName;
    ExtName := '';
  end
  else if DotPos > 0 then
  begin
    BaseName := Copy(OutName, 1, DotPos - 1);
    ExtName  := Copy(OutName, DotPos + 1, 3);
  end
  else
  begin
    BaseName := OutName;
    ExtName  := '';
  end;

  DisplayStr := PadRight(BaseName, 8) + ' ' + PadRight(ExtName, 3) + ' ';

  { Directories get a <DIR> marker in the size column; files get the byte
    count. Both fields are exactly 14 chars + 1 space so the date/time
    columns always line up. }
  if (Entry.Attr and ATTR_DIRECTORY) <> 0 then
    DisplayStr := DisplayStr + PadRight('   <DIR>', 14) + ' '
  else if OptHuman then
    DisplayStr := DisplayStr + PadLeft(HumanSize(Entry.Size), 14) + ' '
  else
    DisplayStr := DisplayStr + PadLeft(FormatNumber(Entry.Size), 14) + ' ';

  { Append Dates and Times }
  FormatDateTime(Entry.Time, DateStr, TimeStr);
  DisplayStr := DisplayStr + DateStr + '  ' + TimeStr;

  { /LFN: append the long name after the time column (Win9x DIR style),
    truncated to the 79-column line. Comparison is case-sensitive, so a
    name differing only in case (e.g. 'Command.com') is still shown -
    preserved case is the point - while an identical uppercase 8.3 name
    is suppressed as redundant. }
  if OptLFN and (CurLfn <> '') and (CurLfn <> Entry.Name) then
  begin
    DisplayStr := DisplayStr + ' ';
    DotPos := 79 - Length(DisplayStr);  { reuse: remaining columns }
    if DotPos > 0 then
      DisplayStr := DisplayStr + Copy(CurLfn, 1, DotPos);
  end;

  PrintLineC(DisplayStr, A);
end;

{ Recursively or linearly searches through paths and triggers output.
  NOTE: Path/FilePattern use short string types deliberately - every local
  byte here is multiplied by the /S recursion depth on the stack. }
procedure ProcessDirectory(Path: PathStr79; FilePattern: PathStr12);
var
  SearchObj       : SearchRec;
  Count           : Integer;
  FileList        : PFileArray;
  EntryPool       : PFilePool;    { One block holds all TFileEntry slots }
  I               : Integer;
  DirFiles        : LongInt;
  DirBytes        : Big;
  FullPathPattern : string[95];
  SubDirList      : PSubDirList;  { HEAP-allocated: was a 3.3 KB stack array }
  SubDirCount     : Integer;
  Truncated       : Boolean;
  Streaming       : Boolean;
  OnePassDirs     : Boolean;
  TempEntry       : TFileEntry;
  DotPos          : Integer;
  DispPath        : PathStr79;
  LHandle         : Word;
  LName           : string;

  { Shared per-entry logic for both the classic (FindFirst) and LFN
    (714Eh) enumeration loops: /S collection, filtering, statistics,
    and streaming display or storage. ELong is '' in classic mode. }
  procedure ProcessEntry(const EName: string; EAttr: Byte;
                         ETime, ESize: LongInt; const ELong: string);
  var
    L: Integer;
  begin
    { Collect subdirectories for /S recursion - independent of the
      display filter, and always via the SHORT name so recursion paths
      stay within DOS path limits and open on any kernel }
    if OnePassDirs and
       ((EAttr and ATTR_DIRECTORY) <> 0) and
       ((EAttr and (ATTR_HIDDEN or ATTR_SYSTEM)) = 0) and
       (EName <> '.') and (EName <> '..') and
       (SubDirCount < MAX_SUBDIRS) then
    begin
      Inc(SubDirCount);
      SubDirList^[SubDirCount] := EName;
    end;

    { Validate Attributes before keeping the entry }
    if ((EAttr and ATTR_VOLUME) = 0) and
       ((EAttr and AttrRequire) = AttrRequire) and
       ((EAttr and AttrExclude) = 0) then
    begin
      if (EAttr and ATTR_DIRECTORY) <> 0 then
      begin
        Inc(TotalDirs);
      end
      else
      begin
        Inc(DirFiles);
        DirBytes := DirBytes + ESize;
        Inc(TotalFiles);
        TotalBytes := TotalBytes + ESize;
      end;

      if Streaming then
      begin
        TempEntry.Name := EName;
        TempEntry.Attr := EAttr;
        TempEntry.Time := ETime;
        TempEntry.Size := ESize;
        CurLfn := ELong;
        DisplayEntry(TempEntry, Path);
      end
      else if Count < MAX_ENTRIES then
      begin
        Inc(Count);
        FileList^[Count] := @EntryPool^[Count];  { pool slot, no New() }
        FileList^[Count]^.Name := EName;
        FileList^[Count]^.Attr := EAttr;
        FileList^[Count]^.Time := ETime;
        FileList^[Count]^.Size := ESize;
        FileList^[Count]^.LOfs := 0;
        FileList^[Count]^.LLen := 0;

        { Bump-allocate the long name into the pool (display-capped);
          if the pool fills, remaining entries just show 8.3 }
        if OptLFN and (ELong <> '') and (LfnPool <> nil) then
        begin
          L := Length(ELong);
          if L > LFN_MAXSTORE then L := LFN_MAXSTORE;
          if LongInt(PoolTop) + L <= LFN_POOLSIZE then
          begin
            Move(ELong[1], LfnPool^[PoolTop], L);
            FileList^[Count]^.LOfs := PoolTop;
            FileList^[Count]^.LLen := L;
            Inc(PoolTop, L);
          end;
        end;

        { Precompute the extension once for /O:E so the quicksort
          comparator doesn't repeat Pos+Copy on every comparison }
        if SortKey = SORT_EXT then
        begin
          DotPos := Pos('.', EName);
          if DotPos > 0 then
            FileList^[Count]^.Ext := Copy(EName, DotPos, 4)
          else
            FileList^[Count]^.Ext := '';
        end
        else
          FileList^[Count]^.Ext := '';
      end
      else
        Truncated := True;
    end;
  end;

begin
  { Ensure trailing backslash on path }
  if Path[Length(Path)] <> '\' then
    Path := Path + '\';

  FullPathPattern := Path + FilePattern;
  Count := 0;
  DirFiles := 0;
  DirBytes := 0;
  SubDirCount := 0;
  ColIndex := 0;
  Truncated := False;

  { STREAMING MODE: with no sort requested, entries are printed the moment
    DOS returns them - exactly like real DIR. No heap storage, no display
    pass, no MAX_ENTRIES limit, and the first line appears instantly
    instead of after the whole directory has been read. }
  Streaming := (SortKey = SORT_NONE);

  { ONE-PASS /S: when the search pattern already matches everything, the
    subdirectory names can be collected during the main enumeration,
    saving a complete second directory read from disk at every level.
    With a narrower pattern (e.g. *.TXT) directories may not match it,
    so the classic second scan is still required. }
  OnePassDirs := OptSubDir and (FilePattern = '*.*');

  SubDirList := nil;
  if OptSubDir then
    New(SubDirList);

  if not OptBare then
  begin
    { Real DIR prints the first 'Directory of' line directly under the
      volume header; only subsequent directories (/S) get a separating
      blank line }
    if FirstHeader then
      FirstHeader := False
    else
      PrintLine('');

    { Real DIR shows the path without a trailing backslash - except the
      root itself ('C:\'), which keeps it }
    DispPath := Path;
    if (Length(DispPath) > 3) and (DispPath[Length(DispPath)] = '\') then
      Delete(DispPath, Length(DispPath), 1);

    PrintLine(' Directory of ' + DispPath);
    PrintLine('');
  end;

  { Allocate the pointer array AND one contiguous entry pool: a single
    pair of allocations instead of 2048 individual New() calls (which
    fragment the heap and walk free lists per file) }
  FileList := nil;
  EntryPool := nil;
  if not Streaming then
  begin
    New(FileList);
    New(EntryPool);
  end;

  PoolTop := 0;  { Long-name pool resets per directory }

  { --- LFN enumeration (714Eh) --- }
  if LfnActive then
  begin
    if LfnFindFirst(FullPathPattern, LHandle) then
    begin
      repeat
        LfnExtract(TempEntry, LName);
        { Safety net: an entry with neither a short nor a long name can
          only come from a kernel feeding us garbage - stop immediately
          rather than scroll blanks forever }
        if (TempEntry.Name = '') and (LName = '') then Break;
        ProcessEntry(TempEntry.Name, TempEntry.Attr,
                     TempEntry.Time, TempEntry.Size, LName);
      until not LfnFindNext(LHandle);
      LfnFindClose(LHandle);
    end;
    { If the API turned out to be absent, LfnActive is now False and
      the classic loop below takes over seamlessly }
  end;

  { --- Classic enumeration (FindFirst/FindNext) --- }
  if not LfnActive then
  begin
    FindFirst(FullPathPattern, ATTR_ANYFILE, SearchObj);
    while DosError = 0 do
    begin
      ProcessEntry(SearchObj.Name, SearchObj.Attr,
                   SearchObj.Time, SearchObj.Size, '');
      FindNext(SearchObj);
    end;
{$IFDEF FPC}
    FindClose(SearchObj);
{$ENDIF}
  end;

  if not Streaming then
  begin
    { Sort entries if needed }
    if Count > 1 then
      QuickSortEntries(FileList^, 1, Count);

    { Display the sorted entries; both blocks freed once afterwards }
    for I := 1 to Count do
    begin
      CurLfn := '';
      if OptLFN and (FileList^[I]^.LLen > 0) and (LfnPool <> nil) then
      begin
        CurLfn[0] := Chr(FileList^[I]^.LLen);
        Move(LfnPool^[FileList^[I]^.LOfs], CurLfn[1], FileList^[I]^.LLen);
      end;
      DisplayEntry(FileList^[I]^, Path);
    end;
    Dispose(FileList);
    Dispose(EntryPool);
  end;

  { Flush uncompleted wide / two-column rows }
  if (OptWide or Opt2Col) and (ColIndex > 0) then
  begin
    OutLn('', CLR_NORMAL);
    HandlePaging;
  end;

  if Truncated and not OptBare then
    PrintLine(' *** Warning: more than ' + FormatNumber(MAX_ENTRIES) +
              ' entries - sorted listing truncated (omit /O to list all) ***');

  { Print local directory summary }
  if not OptBare then
  begin
    PrintLine(PadLeft(FormatNumber(DirFiles), 16) + ' File(s) ' +
              FmtSize17(DirBytes));
  end;

  { Handle /S Subdirectory recursion mode }
  if OptSubDir then
  begin
    { Second directory scan only if the main pattern couldn't cover it }
    if not OnePassDirs then
    begin
      FindFirst(Path + '*.*', ATTR_DIRECTORY, SearchObj);
      while DosError = 0 do
      begin
        if ((SearchObj.Attr and ATTR_DIRECTORY) <> 0) and
           (SearchObj.Name <> '.') and (SearchObj.Name <> '..') then
        begin
          if SubDirCount < MAX_SUBDIRS then
          begin
            Inc(SubDirCount);
            SubDirList^[SubDirCount] := SearchObj.Name;
          end;
        end;
        FindNext(SearchObj);
      end;
{$IFDEF FPC}
      FindClose(SearchObj);
{$ENDIF}
    end;

    { Recursively traverse collected paths }
    for I := 1 to SubDirCount do
      ProcessDirectory(Path + SubDirList^[I], FilePattern);

    Dispose(SubDirList);
  end;
end;

{ =========================================================================== }
{ COMMAND LINE INTERFACE & ARGUMENT PARSING                                   }
{ =========================================================================== }

procedure ShowHelp;
begin
  WriteLn('FASTDIR v' + PROG_VERSION + ' - Fast DIR for MS-DOS & Slow PCs');
  WriteLn('Usage: FASTDIR [drive:][path][filename] [/W] [/P] [/B] [/L] [/S] [/Q] [/O:ord] [/A:att]');
  WriteLn;
  WriteLn('  /W          Wide format (5 columns across)');
  WriteLn('  /2          Two-column detail format (DR-DOS style)');
  WriteLn('  /P          Pauses after each full screen of information');
  WriteLn('  /B          Bare format (no headers, bare filenames only)');
  WriteLn('  /L          Displays file names in lowercase');
  WriteLn('  /S          Recursively searches all subdirectories');
  WriteLn('  /C          Color by type: dirs, exec, archives, docs, media, source');
  WriteLn('  /LFN        Experimental: long filenames (Win9x DOS/DOSLFN/NTVDM)');
  WriteLn('  /H          Human-readable sizes (KB, MB, GB)');
  WriteLn('  /T          Toggle 12/24-hour time (inverts the COUNTRY= default)');
  WriteLn('  /Q or /-F   Quick mode: bypasses slow free-space calculation');
  WriteLn('  /QA         Quick approx. free space (samples the FAT, FAT16/DOS4+)');
  WriteLn('  /O:order    Sort order: N(name), E(ext), S(size), D(date), G(group dirs)');
  WriteLn('              Use "-" prefix to reverse order (e.g. /O:-S)');
  WriteLn('  /A:attrib   Filter: D(dirs), R(read-only), H(hidden), S(system), A(archive)');
  WriteLn('              Use "-" prefix to exclude (e.g. /A:-H-S)');
  WriteLn;
  WriteLn('Switches may be run together, e.g. FASTDIR /C/Q/W');
  WriteLn('Defaults can be set in the environment:  SET DIRCMD=/C/Q');
  Halt(0);
end;

{ Processes an individual flag switch block }
procedure ParseSwitch(OptStr: string);
var
  J: Integer;
  SwitchChar: Char;
  Negate: Boolean;
begin
  OptStr := ToUpperStr(OptStr);
  if OptStr = '' then Exit;

  if (OptStr = 'W') then OptWide := True
  else if (OptStr = '2') then Opt2Col := True
  else if (OptStr = 'P') then OptPage := True
  else if (OptStr = 'B') then OptBare := True
  else if (OptStr = 'L') then OptLower := True
  else if (OptStr = 'S') then OptSubDir := True
  else if (OptStr = 'C') then OptColor := True
  else if (OptStr = 'H') then OptHuman := True
  else if (OptStr = 'LFN') then OptLFN := True
  else if (OptStr = 'T') then OptAmPm := not OptAmPm  { invert country default }
  else if (OptStr = 'Q') or (OptStr = '-F') then OptSkipFree := True
  else if (OptStr = 'QA') then OptEstimate := True
  else if (OptStr = '?') then ShowHelp
  else if OptStr[1] = 'O' then
  begin
    { Setup Ordering Rules }
    J := 2;
    if (Length(OptStr) >= 2) and (OptStr[2] = ':') then Inc(J);
    while J <= Length(OptStr) do
    begin
      SwitchChar := OptStr[J];
      if SwitchChar = '-' then SortReverse := True
      else if SwitchChar = 'N' then SortKey := SORT_NAME
      else if SwitchChar = 'E' then SortKey := SORT_EXT
      else if SwitchChar = 'S' then SortKey := SORT_SIZE
      else if SwitchChar = 'D' then SortKey := SORT_DATE
      else if SwitchChar = 'G' then OptGroupDirs := True;
      Inc(J);
    end;
    if SortKey = SORT_NONE then SortKey := SORT_NAME;
  end
  else if OptStr[1] = 'A' then
  begin
    { Setup Attribute Filters }
    J := 2;
    if (Length(OptStr) >= 2) and (OptStr[2] = ':') then Inc(J);

    if J > Length(OptStr) then
    begin
      { Bare /A means "show everything, including hidden/system" }
      AttrExclude := 0;
      AttrRequire := 0;
    end
    else
    begin
      Negate := False;
      while J <= Length(OptStr) do
      begin
        SwitchChar := OptStr[J];
        if SwitchChar = '-' then
          Negate := True
        else
        begin
          case SwitchChar of
            'D': if Negate then AttrExclude := AttrExclude or ATTR_DIRECTORY else AttrRequire := AttrRequire or ATTR_DIRECTORY;
            'H': if Negate then AttrExclude := AttrExclude or ATTR_HIDDEN    else AttrRequire := AttrRequire or ATTR_HIDDEN;
            'S': if Negate then AttrExclude := AttrExclude or ATTR_SYSTEM    else AttrRequire := AttrRequire or ATTR_SYSTEM;
            'R': if Negate then AttrExclude := AttrExclude or ATTR_READONLY  else AttrRequire := AttrRequire or ATTR_READONLY;
            'A': if Negate then AttrExclude := AttrExclude or ATTR_ARCHIVE   else AttrRequire := AttrRequire or ATTR_ARCHIVE;
          end;
          Negate := False;
        end;
        Inc(J);
      end;
    end;
  end;
end;

{ Splits a run-together switch block at each '/' and feeds the pieces to
  ParseSwitch. Input is the text AFTER the leading '/' or '-'.
  Examples:  'C/Q'      -> C, Q
             'C/O:-S/W' -> C, O:-S, W
             '-F/C'     -> -F, C          }
procedure ParseSwitchBlock(const Raw: string);
var
  Start, I: Integer;
begin
  Start := 1;
  for I := 1 to Length(Raw) do
    if Raw[I] = '/' then
    begin
      ParseSwitch(Copy(Raw, Start, I - Start));
      Start := I + 1;
    end;
  ParseSwitch(Copy(Raw, Start, 255));
end;

{ Aggregates switches from DIRCMD environment variable and argv }
procedure ParseArguments;
var
  I, J    : Integer;
  Param   : string;
  EnvCmd  : string;
  Token   : string;
  CheckSR : SearchRec;
begin
  { Initialize Default State }
  OptWide       := False;
  Opt2Col       := False;
  OptPage       := False;
  OptBare       := False;
  OptLower      := False;
  OptSubDir     := False;
  OptSkipFree   := False;
  OptEstimate   := False;
  OptGroupDirs  := False;
  OptColor      := False;
  OptHuman      := False;
  OptLFN        := False;
  { OptAmPm deliberately NOT reset here: InitCountry (which runs first)
    set its default from the COUNTRY= time format; /T overrides it }
  ColorActive   := False;
  SortKey       := SORT_NONE;
  SortReverse   := False;
  AttrRequire   := 0;
  AttrExclude   := ATTR_HIDDEN or ATTR_SYSTEM;
  TargetMask    := '';
  TargetDir     := '';
  FirstHeader   := True;

  { Auto-detect BIOS text mode lines via BIOS data area (40:84 = rows-1) }
  LinesOnScreen := Mem[$0040:$0084] + 1;
  if (LinesOnScreen < 20) or (LinesOnScreen > 60) then
    LinesOnScreen := 25;

  { Parse DIRCMD Environment Variable (MS-DOS standard) }
  EnvCmd := GetEnv('DIRCMD');
  if EnvCmd <> '' then
  begin
    I := 1;
    while I <= Length(EnvCmd) do
    begin
      while (I <= Length(EnvCmd)) and (EnvCmd[I] = ' ') do Inc(I);
      if I <= Length(EnvCmd) then
      begin
        Token := '';
        while (I <= Length(EnvCmd)) and (EnvCmd[I] <> ' ') do
        begin
          Token := Token + EnvCmd[I];
          Inc(I);
        end;
        if (Token[1] = '/') or (Token[1] = '-') then
          ParseSwitchBlock(Copy(Token, 2, 255));
      end;
    end;
  end;

  { Parse Standard Arguments }
  for I := 1 to ParamCount do
  begin
    Param := ParamStr(I);
    if (Param[1] = '/') or (Param[1] = '-') then
      ParseSwitchBlock(Copy(Param, 2, 255))
    else
      TargetMask := Param;
  end;

  { Identify default behaviors based on what path the user supplied }
  if TargetMask = '' then
    TargetMask := '*.*'
  else
  begin
    if TargetMask[Length(TargetMask)] in ['\', ':'] then
      TargetMask := TargetMask + '*.*'
    else if (Pos('*', TargetMask) = 0) and (Pos('?', TargetMask) = 0) then
    begin
      { A LITERAL argument naming an existing directory lists its
        contents. This check must never run on wildcard masks: with
        'T*', FindFirst would match some T-something directory and
        wrongly rewrite the mask to 'T*\*.*' (zero matches). }
      FindFirst(TargetMask, ATTR_DIRECTORY, CheckSR);
      if (DosError = 0) and ((CheckSR.Attr and ATTR_DIRECTORY) <> 0) then
        TargetMask := TargetMask + '\*.*';
{$IFDEF FPC}
      FindClose(CheckSR);
{$ENDIF}
    end;
  end;

  { Split the evaluated string back down into Directory and Mask }
  J := Length(TargetMask);
  while (J > 0) and (not (TargetMask[J] in ['\', ':'])) do Dec(J);

  if J = 0 then
  begin
    TargetDir := '.';
  end
  else if (J = 2) and (TargetMask[2] = ':') then
  begin
    TargetDir := Copy(TargetMask, 1, 2);
    TargetMask := Copy(TargetMask, 3, 255);
  end
  else
  begin
    TargetDir := Copy(TargetMask, 1, J);
    Delete(TargetMask, 1, J);
  end;

  if TargetMask = '' then TargetMask := '*.*';

  { DIR semantics: a mask with no extension matches ANY extension.
    Kernel FindFirst treats 'T*' as "T-anything with a BLANK extension"
    (the same 8.3 rule behind the classic 'del *' vs 'del *.*' gotcha),
    so like real DIR we append '.*' - 'T*' -> 'T*.*', 'COMMAND' ->
    'COMMAND.*'. Extensionless names still match, since a blank
    extension satisfies '*'. }
  if Pos('.', TargetMask) = 0 then
    TargetMask := TargetMask + '.*';
end;

{ =========================================================================== }
{ MAIN EXECUTION BLOCK                                                        }
{ =========================================================================== }

var
  DriveChar : Char;
  CurPath   : string;
begin
  { Install 4 KB output buffer BEFORE anything is written. Reduces DOS
    Int 21h write calls ~32x versus the default 128-byte buffer. }
  SetTextBuf(Output, OutBuf);

  { Pick up COUNTRY= formatting (thousands separator, date order) so
    output matches real DIR on non-US configurations }
  InitCountry;

  TotalFiles  := 0;
  TotalDirs   := 0;
  TotalBytes  := 0;
  CurrentLine := 0;

  { Boot process }
  ParseArguments;

  { Color only when /C was given AND output goes to a real console;
    redirected output (files, pipes) stays plain automatically }
  ColorActive := OptColor and StdOutIsConsole;
  MonoMode := ColorActive and (Mem[$0040:$0049] = 7);
  ExtCount := 0;
  VidInited := False;
  VisOfs := 0;
  if ColorActive then
  begin
    InitExtColors;  { Extension color table only needed with /C }
    { Crash-safe screen restore: the CRTC start address and hardware
      cursor are put back even on Halt or a runtime error }
    ExitSave := ExitProc;
    ExitProc := @VideoExitProc;
  end;

  { /LFN: activate the LFN path (self-disables on the first call if the
    API is absent) and allocate the long-name pool }
  LfnActive := OptLFN;
  LfnWarned := False;
  LfnPool   := nil;
  PoolTop   := 0;
  CurLfn    := '';
  if OptLFN then
    GetMem(LfnPool, LFN_POOLSIZE);

  { Determine Target Drive for Status Checks }
  if (Length(TargetDir) >= 2) and (TargetDir[2] = ':') then
    DriveChar := TargetDir[1]
  else
  begin
    GetDir(0, CurPath);
    DriveChar := CurPath[1];
  end;

  { Resolve absolute starting directory }
  if (TargetDir = '') or (TargetDir = '.') then
    GetDir(0, TargetDir)
  else if (Length(TargetDir) = 2) and (TargetDir[2] = ':') then
    GetDir(Ord(UpCase(TargetDir[1])) - Ord('A') + 1, TargetDir);

  { 1. Print Header }
  PrintVolumeHeader(DriveChar);

  { 2. Process Files & Directories }
  ProcessDirectory(TargetDir, TargetMask);

  { 3. Print SubDir Trailer }
  if OptSubDir and not OptBare then
  begin
    PrintLine('');
    PrintLine('     Total Files Listed:');
    PrintLine(PadLeft(FormatNumber(TotalFiles), 16) + ' File(s) ' +
              FmtSize17(TotalBytes));
  end;

  { 4. Print Footer }
  PrintFreeSpace(DriveChar);
end.