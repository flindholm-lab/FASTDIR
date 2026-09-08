{ =========================================================================== }
{ FASTDIR.PAS - High-Performance DIR Utility for MS-DOS & PC-DOS              }
{ Compatible with Turbo Pascal 6.0, 7.0, and Free Pascal (go32v2 target)      }
{                                                                             }
{ Designed for slow PCs (8088/8086, 286, 386, XT-IDE, CF cards, large disks): }
{   - Safe DOS 7.10+ FAT32 check (prevents interrupt lockups on older DOS)    }
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
  PROG_VERSION   = '2.40-TP';
  MAX_ENTRIES    = 2048; { Maximum number of files processed per directory }
  MAX_SUBDIRS    = 256;  { Maximum subdirectories tracked per level for /S }
  WIDE_COLS      = 5;    { Number of columns for Wide (/W) display format }

  { /C mode jump-scroll distance in lines. 1 = smoothest (line-by-line,
    like DOS), higher = fewer/cheaper scroll operations = less stutter
    on slow machines. 4 is a good balance on XT-class hardware. }
  SCROLL_STEP    = 4;

  { /QA: number of FAT sectors sampled for the free-space estimate }
  EST_SAMPLES    = 8;

  { Text attributes for /C color mode (foreground on black) }
  CLR_NORMAL     = $07;  { Light gray - ordinary files & framework text }
  CLR_DIR        = $0E;  { Yellow     - directories }
  CLR_EXEC       = $0A;  { Light green- .COM / .EXE / .BAT }

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

  { Represents a single file or directory entry }
  PFileEntry = ^TFileEntry;
  TFileEntry = record
    Name : string[12];
    Ext  : string[4];  { Precomputed at insert time when sorting by /O:E }
    Attr : Byte;
    Time : LongInt;
    Size : LongInt;
  end;

  { Heap-allocated array to avoid hitting DSEG limitations in real mode }
  TFileArray = array[1..MAX_ENTRIES] of PFileEntry;
  PFileArray = ^TFileArray;

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
  OptPage        : Boolean;  { /P switch }
  OptBare        : Boolean;  { /B switch }
  OptLower       : Boolean;  { /L switch }
  OptSubDir      : Boolean;  { /S switch }
  OptSkipFree    : Boolean;  { /Q or /-F switch }
  OptEstimate    : Boolean;  { /QA switch: sampled free-space estimate }
  OptGroupDirs   : Boolean;  { /O:G switch (group directories first) }
  OptColor       : Boolean;  { /C switch }
  OptAmPm        : Boolean;  { /T switch: 12-hour am/pm time (default 24h) }
  ColorActive    : Boolean;  { /C requested AND stdout is a real console }

  SortKey        : Byte;     { Active sorting mechanism }
  SortReverse    : Boolean;  { Reverse sorting order flag }

  AttrRequire    : Byte;     { Mask of attributes that MUST be present }
  AttrExclude    : Byte;     { Mask of attributes that MUST NOT be present }

  LinesOnScreen  : Word;     { Detected rows on terminal }
  CurrentLine    : Word;     { Tracks output lines for /P pagination }
  ColIndex       : Word;     { Tracks current column for /W wide format }

  TargetMask     : string;   { File wildcard to search for }
  TargetDir      : string;   { Base directory to search }

  TotalFiles     : LongInt;  { Global statistics counters }
  TotalDirs      : LongInt;
  TotalBytes     : Big;      { 64-bit: /S over a large tree exceeds 2 GB }

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

{ Inserts thousands separators into a raw digit string }
function CommaFy(const Raw: string): string;
var
  ResultStr: string;
  Len, I, PosCount: Integer;
begin
  Len := Length(Raw);
  ResultStr := '';
  PosCount := 0;

  for I := Len downto 1 do
  begin
    ResultStr := Raw[I] + ResultStr;
    Inc(PosCount);
    { Add comma every 3 digits, never directly after a minus sign }
    if (PosCount mod 3 = 0) and (I > 1) and (Raw[I - 1] <> '-') then
      ResultStr := ',' + ResultStr;
  end;
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

  DateStr := MoStr + '-' + DStr + '-' + YStr;

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

    TimeStr := HStr + ':' + MStr + AmPm;
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
    TimeStr := HStr + ':' + MStr + ' ';
  end;
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
procedure OutStr(const S: string; Attr: Byte);
var
  Regs     : Registers;
  I        : Integer;
  Row, Col : Byte;
  Cols     : Word;
  Rows     : Byte;
  VSeg     : Word;
  POfs     : Word;
  Page     : Byte;
{$IFNDEF FPC}
  W, Base  : Word;
  Blank    : Word;
{$ENDIF}
begin
  if not ColorActive then
  begin
    Write(S);
    Exit;
  end;

  Cols := MemW[$0040:$004A];        { BIOS: columns per row }
  Rows := Byte(LinesOnScreen);
  Page := Mem[$0040:$0062];         { BIOS: active display page }
  POfs := MemW[$0040:$004E];        { BIOS: byte offset of active page }
  if Mem[$0040:$0049] = 7 then      { Video mode 7 = MDA/Hercules mono }
    VSeg := $B000
  else
    VSeg := $B800;

  { Fetch current cursor position once per string }
  Regs.AH := $03;
  Regs.BH := Page;
  Intr($10, Regs);
  Row := Regs.DH;
  Col := Regs.DL;

  for I := 1 to Length(S) do
  begin
    case S[I] of
      #13: Col := 0;
      #10: Inc(Row);
    else
      begin
        MemW[VSeg : POfs + (Word(Row) * Cols + Col) * 2] :=
          Word(Ord(S[I])) or (Word(Attr) shl 8);
        Inc(Col);
        if Col >= Cols then
        begin
          Col := 0;
          Inc(Row);
        end;
      end;
    end;

    if Row >= Rows then
    begin
{$IFDEF FPC}
      { Protected mode: no flat pointer to video RAM here, so scroll
        via BIOS - but SCROLL_STEP lines at once to reduce call count }
      Regs.AH := $06;
      Regs.AL := SCROLL_STEP;
      Regs.BH := CLR_NORMAL;
      Regs.CH := 0;
      Regs.CL := 0;
      Regs.DH := Rows - 1;
      Regs.DL := Cols - 1;
      Intr($10, Regs);
{$ELSE}
      { Jump scroll: ONE block move of the whole screen up SCROLL_STEP
        lines plus a blank fill, instead of a BIOS scroll per line. The
        next SCROLL_STEP-1 lines then print with no scrolling at all -
        this removes nearly all the scroll stutter on slow machines. }
      Move(Ptr(VSeg, POfs + Word(SCROLL_STEP) * Cols * 2)^,
           Ptr(VSeg, POfs)^,
           Word(Rows - SCROLL_STEP) * Cols * 2);

      Blank := Word(Ord(' ')) or (Word(CLR_NORMAL) shl 8);
      Base  := POfs + Word(Rows - SCROLL_STEP) * Cols * 2;
      for W := 0 to Word(SCROLL_STEP) * Cols - 1 do
        MemW[VSeg : Base + W * 2] := Blank;
{$ENDIF}
      Row := Rows - SCROLL_STEP;
    end;
  end;

  { Park the BIOS cursor where output ended }
  Regs.AH := $02;
  Regs.BH := Page;
  Regs.DH := Row;
  Regs.DL := Col;
  Intr($10, Regs);
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

  { Packet-method Int 25h needs DOS 4.0+ }
  if Lo(DosVersion) < 4 then Exit;

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

  { DOS 7.10+ supports FAT32 ExtGetFreeSpace }
  if (Lo(DosVer) > 7) or ((Lo(DosVer) = 7) and (Hi(DosVer) >= 10)) then
  begin
    FillChar(FAT32Data, SizeOf(FAT32Data), 0);
    FAT32Data.StructureSize := SizeOf(FAT32Data);

    Regs.AX := $7303; { ExtGetFreeSpace }
    Regs.DS := Seg(RootStr[1]);
    Regs.DX := Ofs(RootStr[1]);
    Regs.ES := Seg(FAT32Data);
    Regs.DI := Ofs(FAT32Data);
    Regs.CX := SizeOf(FAT32Data);
    Regs.Flags := Regs.Flags or FCarry; { Defensive: preset CF }
    Intr($21, Regs);

    if ((Regs.Flags and FCarry) = 0) and (Regs.AX <> $7300) then
    begin
      ClustersFree := FAT32Data.AvailableClusters;
      ClusterBytes := FAT32Data.SectorsPerCluster * FAT32Data.BytesPerSector;

      { Check for LongInt overflow on extremely large partitions }
      if (ClusterBytes > 0) and (ClustersFree < ($7FFFFFFF div ClusterBytes)) then
      begin
        BytesFree := ClustersFree * ClusterBytes;
        Success := True;
      end
      else if ClusterBytes >= 1024 then
      begin
        { Byte count would overflow LongInt - report in KB instead }
        PrintLine(PadLeft(FormatNumber(TotalDirs), 16) + ' Dir(s) ' +
                  PadLeft(FormatNumber(ClustersFree * (ClusterBytes div 1024)), 14) +
                  ' KB free');
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
                  PadLeft(FormatBig(EstBytes), 17) + ' bytes free')
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
    PrintLine(PadLeft(FormatNumber(TotalDirs), 16) + ' Dir(s) ' +
              PadLeft(FormatNumber(BytesFree), 17) + ' bytes free')
  else
    PrintLine(PadLeft(FormatNumber(TotalDirs), 16) +
              ' Dir(s)   [Free space unavailable]');
end;

{ =========================================================================== }
{ SORTING ENGINE                                                              }
{ =========================================================================== }

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
          if E1^.Time < E2^.Time then ResultVal := -1
          else if E1^.Time > E2^.Time then ResultVal := 1
          else if E1^.Name < E2^.Name then ResultVal := -1
          else if E1^.Name > E2^.Name then ResultVal := 1;
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
{ DIRECTORY PROCESSING                                                        }
{ =========================================================================== }

{ Picks the display attribute for an entry: directories yellow,
  executables (.COM/.EXE/.BAT) green, everything else normal }
function EntryAttr(const Entry: TFileEntry): Byte;
var
  E      : string[3];
  DotPos : Integer;
begin
  if not ColorActive then
    EntryAttr := CLR_NORMAL
  else if (Entry.Attr and ATTR_DIRECTORY) <> 0 then
    EntryAttr := CLR_DIR
  else
  begin
    { DOS returns names uppercase, so plain comparison suffices }
    DotPos := Pos('.', Entry.Name);
    if DotPos > 0 then
      E := Copy(Entry.Name, DotPos + 1, 3)
    else
      E := '';
    if (E = 'COM') or (E = 'EXE') or (E = 'BAT') then
      EntryAttr := CLR_EXEC
    else
      EntryAttr := CLR_NORMAL;
  end;
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

  { Bare mode: Only print the filename, ignoring stats }
  if OptBare then
  begin
    if (Entry.Name <> '.') and (Entry.Name <> '..') then
    begin
      if OptSubDir then
        PrintLineC(CurrentPath + OutName, A)
      else
        PrintLineC(OutName, A);
    end;
    Exit;
  end;

  { Wide mode: Pack entries horizontally into columns }
  if OptWide then
  begin
    if (Entry.Attr and ATTR_DIRECTORY) <> 0 then
      DisplayStr := '[' + OutName + ']'
    else
      DisplayStr := OutName;

    OutStr(PadRight(DisplayStr, 15), A);
    Inc(ColIndex);
    if ColIndex >= WIDE_COLS then
    begin
      OutLn('', CLR_NORMAL);
      HandlePaging;
      ColIndex := 0;
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
  else
    DisplayStr := DisplayStr + PadLeft(FormatNumber(Entry.Size), 14) + ' ';

  { Append Dates and Times }
  FormatDateTime(Entry.Time, DateStr, TimeStr);
  DisplayStr := DisplayStr + DateStr + '  ' + TimeStr;

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
    PrintLine('');
    PrintLine(' Directory of ' + Path);
    PrintLine('');
  end;

  { Allocate file pointer array on the heap (sorted modes only) }
  FileList := nil;
  if not Streaming then
    New(FileList);

  FindFirst(FullPathPattern, ATTR_ANYFILE, SearchObj);
  while DosError = 0 do
  begin
    { Collect subdirectories for /S recursion. This is deliberately
      independent of the display filter (/A) - matching the behavior of
      the old separate scan, which skipped hidden/system directories. }
    if OnePassDirs and
       ((SearchObj.Attr and ATTR_DIRECTORY) <> 0) and
       ((SearchObj.Attr and (ATTR_HIDDEN or ATTR_SYSTEM)) = 0) and
       (SearchObj.Name <> '.') and (SearchObj.Name <> '..') and
       (SubDirCount < MAX_SUBDIRS) then
    begin
      Inc(SubDirCount);
      SubDirList^[SubDirCount] := SearchObj.Name;
    end;

    { Validate Attributes before keeping the entry }
    if ((SearchObj.Attr and ATTR_VOLUME) = 0) and
       ((SearchObj.Attr and AttrRequire) = AttrRequire) and
       ((SearchObj.Attr and AttrExclude) = 0) then
    begin
      { Update statistics }
      if (SearchObj.Attr and ATTR_DIRECTORY) <> 0 then
      begin
        Inc(TotalDirs);
      end
      else
      begin
        Inc(DirFiles);
        DirBytes := DirBytes + SearchObj.Size;
        Inc(TotalFiles);
        TotalBytes := TotalBytes + SearchObj.Size;
      end;

      if Streaming then
      begin
        { Print immediately - no storage, no entry limit }
        TempEntry.Name := SearchObj.Name;
        TempEntry.Attr := SearchObj.Attr;
        TempEntry.Time := SearchObj.Time;
        TempEntry.Size := SearchObj.Size;
        DisplayEntry(TempEntry, Path);
      end
      else if Count < MAX_ENTRIES then
      begin
        Inc(Count);
        New(FileList^[Count]);
        FileList^[Count]^.Name := SearchObj.Name;
        FileList^[Count]^.Attr := SearchObj.Attr;
        FileList^[Count]^.Time := SearchObj.Time;
        FileList^[Count]^.Size := SearchObj.Size;

        { Precompute the extension once for /O:E so the quicksort
          comparator doesn't repeat Pos+Copy on every comparison }
        if SortKey = SORT_EXT then
        begin
          DotPos := Pos('.', SearchObj.Name);
          if DotPos > 0 then
            FileList^[Count]^.Ext := Copy(SearchObj.Name, DotPos, 4)
          else
            FileList^[Count]^.Ext := '';
        end
        else
          FileList^[Count]^.Ext := '';
      end
      else
        Truncated := True;
    end;
    FindNext(SearchObj);
  end;
{$IFDEF FPC}
  FindClose(SearchObj);
{$ENDIF}

  if not Streaming then
  begin
    { Sort entries if needed }
    if Count > 1 then
      QuickSortEntries(FileList^, 1, Count);

    { Display the sorted entries & clean up memory }
    for I := 1 to Count do
    begin
      DisplayEntry(FileList^[I]^, Path);
      Dispose(FileList^[I]);
    end;
    Dispose(FileList);
  end;

  { Flush uncompleted wide columns }
  if OptWide and (ColIndex > 0) then
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
              PadLeft(FormatBig(DirBytes), 17) + ' bytes');
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
  WriteLn('  /P          Pauses after each full screen of information');
  WriteLn('  /B          Bare format (no headers, bare filenames only)');
  WriteLn('  /L          Displays file names in lowercase');
  WriteLn('  /S          Recursively searches all subdirectories');
  WriteLn('  /C          Color: directories yellow, .COM/.EXE/.BAT green');
  WriteLn('  /T          12-hour am/pm time display (default is 24-hour)');
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
  else if (OptStr = 'P') then OptPage := True
  else if (OptStr = 'B') then OptBare := True
  else if (OptStr = 'L') then OptLower := True
  else if (OptStr = 'S') then OptSubDir := True
  else if (OptStr = 'C') then OptColor := True
  else if (OptStr = 'T') then OptAmPm := True
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
  OptPage       := False;
  OptBare       := False;
  OptLower      := False;
  OptSubDir     := False;
  OptSkipFree   := False;
  OptEstimate   := False;
  OptGroupDirs  := False;
  OptColor      := False;
  OptAmPm       := False;
  ColorActive   := False;
  SortKey       := SORT_NONE;
  SortReverse   := False;
  AttrRequire   := 0;
  AttrExclude   := ATTR_HIDDEN or ATTR_SYSTEM;
  TargetMask    := '';
  TargetDir     := '';

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
    else
    begin
      { If the argument names an existing directory, list its contents }
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

  TotalFiles  := 0;
  TotalDirs   := 0;
  TotalBytes  := 0;
  CurrentLine := 0;

  { Boot process }
  ParseArguments;

  { Color only when /C was given AND output goes to a real console;
    redirected output (files, pipes) stays plain automatically }
  ColorActive := OptColor and StdOutIsConsole;

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
              PadLeft(FormatBig(TotalBytes), 17) + ' bytes');
  end;

  { 4. Print Footer }
  PrintFreeSpace(DriveChar);
end.