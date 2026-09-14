{===========================================================================}
{   FAST COMMANDER - DOS File Manager with ZIP VFS                         }
{   Built for Turbo Pascal 7.0 (DOS Real Mode)                              }
{   Zero CRT Dependencies - Direct VRAM & BIOS Int 10h / Int 16h            }
{===========================================================================}
{$M 16384, 0, 32768}  { Stack: 16KB, MinHeap: 0, MaxHeap: 32KB (Leaves RAM for Exec) }
{$R-,S-,I-,V-,A-}     { Enforce packed binary records for ZIP headers }
{ I/O checking stays OFF for the whole program: DOS failures must surface as }
{ IOResult so they can be reported, never as a fatal runtime error. Never    }
{ re-enable it, or a failed Rename/Erase/MkDir aborts with a runtime error.  }

program FastCommander;

uses
  Dos;

const
  { Norton Commander Classic Color Palette }
  ATTR_NORMAL     = $1F;  { White on Blue }
  ATTR_SELECTED   = $30;  { Black on Cyan (Cursor bar) }
  ATTR_TAGGED     = $1E;  { Yellow on Blue (Multi-selected file) }
  ATTR_TAGGED_SEL = $3E;  { Yellow on Cyan (Cursor on selected file) }
  ATTR_BORDER     = $1B;  { Light Cyan on Blue (Active panel border) }
  ATTR_BORDER_INA = $13;  { Dark Cyan on Blue (Inactive panel border) }
  ATTR_HEADER     = $1E;  { Yellow on Blue }
  ATTR_KEY_NUM    = $30;  { Black on Cyan }
  ATTR_KEY_LBL    = $07;  { Light Gray on Black }
  ATTR_DIALOG_BG  = $70;  { Black on Light Gray }
  ATTR_DIALOG_BD  = $7F;  { White on Light Gray }
  ATTR_DIALOG_HL  = $74;  { Red on Light Gray }

  { Extended BIOS Key Codes (Int 16h, AH Register) }
  KEY_UP          = $48;
  KEY_DOWN        = $50;
  KEY_LEFT        = $4B;
  KEY_RIGHT       = $4D;
  KEY_PAGEUP      = $49;
  KEY_PAGEDOWN    = $51;
  KEY_HOME        = $47;
  KEY_END         = $4F;
  KEY_INSERT      = $52;
  KEY_F1          = $3B;
  KEY_F2          = $3C;  { Setup / Config (FC.CFG) }
  KEY_F3          = $3D;  { View Image -> CfgViewImg }
  KEY_F4          = $3E;  { View/Edit -> CfgEditor }
  KEY_F5          = $3F;  { Copy }
  KEY_F6          = $40;  { Rename/Move }
  KEY_F7          = $41;  { Mkdir }
  KEY_F8          = $42;  { Delete }
  KEY_F9          = $43;  { New File }
  KEY_F10         = $44;  { Quit }

  { Alt + Function Keys }
  KEY_ALT_F1      = $68;  { Change Left Panel Drive }
  KEY_ALT_F2      = $69;  { Change Right Panel Drive }

  MAX_FILES       = 200;
  PANEL_ROWS      = 18;
  WIDE_COLS       = 5;

  ATTR_ALL_FILES  = ReadOnly or Hidden or SysFile or Directory or Archive;

  { Wide mode column geometry - needed outside the full-panel renderer }
  WideColX: array[0..4] of Integer = (1, 17, 33, 49, 65);
  WideColW: array[0..4] of Integer = (15, 15, 15, 15, 14);
  WideSepX: array[0..3] of Integer = (16, 32, 48, 64);

type
  { Bounded path string - keeps recursive tree walkers off the stack.       }
  { A plain 'string' param costs 256 bytes per recursion level.             }
  TPathStr = string[80];

  TSortCol = (scName, scSize, scDate, scTime);
  TSortDir = (sdAsc, sdDesc);

  TScreenCell = record
    Ch: Char;
    Attr: Byte;
  end;
  TScreen = array[0..24, 0..79] of TScreenCell;

  TFileEntry = record
    Name: string[12];
    ZipFullName: string[48]; { Internal archive path (e.g. DOCS/README.TXT) }
    Size: LongInt;
    Attr: Byte;
    IsDir: Boolean;
    Time: LongInt;
    Tagged: Boolean;
  end;

  TPanel = record
    Path: string[80];
    Files: array[1..MAX_FILES] of TFileEntry;
    Count: Integer;
    Selected: Integer;
    TopIndex: Integer;
    StartX: Integer;
    SortCol: TSortCol;
    SortDir: TSortDir;

    { ZIP Virtual File System State }
    InsideZip: Boolean;
    ZipPath: string[80];     { Absolute path to host .ZIP file }
    SubPath: string[60];     { Virtual folder path inside ZIP }

    { Incremental redraw tracking - what is currently on screen }
    DrawnSel: Integer;
    DrawnTop: Integer;
    Dirty: Boolean;          { Row contents changed without the cursor moving }
  end;

  PPanel = ^TPanel;

  TBtnDef = record
    Num: string[2];
    Lbl: string[10];
    Width: Byte;
  end;

  { ZIP File Format Structures }
  TZipEOCD = record
    Sig: LongInt;              { $06054B50 }
    DiskNum: Word;
    StartDisk: Word;
    EntriesOnDisk: Word;
    TotalEntries: Word;
    CentralDirSize: LongInt;
    CentralDirOffset: LongInt;
    CommentLen: Word;
  end;

  TZipCDH = record
    Sig: LongInt;              { $02014B50 }
    MadeBy: Word;
    VerNeeded: Word;
    Flags: Word;
    Method: Word;
    DosTime: LongInt;
    CRC32: LongInt;
    CompSize: LongInt;
    UncompSize: LongInt;
    NameLen: Word;
    ExtraLen: Word;
    CommentLen: Word;
    DiskStart: Word;
    IntAttr: Word;
    ExtAttr: LongInt;
    LocalHdrOffset: LongInt;
  end;

const
  { Function key bar. Widths must total 80; hit-testing reads this too. }
  BarButtons: array[1..10] of TBtnDef = (
    (Num: '1';  Lbl: 'Help';      Width: 6),
    (Num: '2';  Lbl: 'Setup';     Width: 7),
    (Num: '3';  Lbl: 'ViewImage';   Width: 11),
    (Num: '4';  Lbl: 'View/Edit'; Width: 11),
    (Num: '5';  Lbl: 'Copy';      Width: 6),
    (Num: '6';  Lbl: 'Ren/Mov';    Width: 9),
    (Num: '7';  Lbl: 'Mkdir';     Width: 7),
    (Num: '8';  Lbl: 'Delete';    Width: 8),
    (Num: '9';  Lbl: 'NewFile';    Width: 9),
    (Num: '10'; Lbl: 'Quit';      Width: 10)
  );

var
  VRAM: TScreen absolute $B800:0000;
  { Same memory seen as character+attribute words: one 16-bit store per cell }
  VRAMW: array[0..1999] of Word absolute $B800:0000;
  NeedFull: Boolean;         { Next refresh must repaint everything }
  MouseAvailable: Boolean;   { An INT 33h driver answered at startup }
  MouseShown: Boolean;       { Driver cursor currently displayed }
  LeftPanel, RightPanel: TPanel;
  ActivePanel: PPanel;
  Running: Boolean;
  WideMode: Boolean;
  QuickSearchStr: string[12];
  OldInt24: Pointer;

  { Persistent Configuration }
  CfgViewImg: string[80];
  CfgEditor: string[80];
  CfgUnzip:  string[80];
  CfgWeightBySize: Boolean;   { Progress bar: weight by bytes instead of item count }
  CfgIsoDateTime: Boolean;    { 24-hour clock and YY-MM-DD dates }
  CfgConfirmOps: Boolean;     { Ask before replacing or deleting files }

{ Forward Declarations }
procedure RedrawScreen; forward;
procedure ReadDirectory(var Panel: TPanel); forward;
procedure ReadZipDirectory(var Panel: TPanel); forward;
procedure SortDirectory(var Panel: TPanel); forward;

{===========================================================================}
{   CONFIGURATION FILE HANDLING (FC.CFG)                                    }
{===========================================================================}

procedure LoadConfig;
var
  T: Text;
  Flag: string[10];
begin
  CfgViewImg := 'VIEW.EXE';
  CfgEditor := 'FLED.EXE';
  CfgUnzip  := 'UNZIP.EXE';
  CfgWeightBySize := False;
  CfgIsoDateTime := True;
  CfgConfirmOps := True;

  Assign(T, 'FC.CFG');
  Reset(T);
  if IOResult = 0 then
  begin
    if not Eof(T) then Readln(T, CfgViewImg);
    if not Eof(T) then Readln(T, CfgEditor);
    if not Eof(T) then Readln(T, CfgUnzip);
    if not Eof(T) then
    begin
      Readln(T, Flag);
      CfgWeightBySize := (Flag = '1');
    end;
    if not Eof(T) then
    begin
      Readln(T, Flag);
      CfgIsoDateTime := (Flag <> '0');   { absent or malformed means on }
    end;
    if not Eof(T) then
    begin
      Readln(T, Flag);
      CfgConfirmOps := (Flag <> '0');
    end;
    Close(T);
  end;

  if CfgViewImg = '' then CfgViewImg := 'VIEW.EXE';
  if CfgEditor = '' then CfgEditor := 'FLED.EXE';
  if CfgUnzip  = '' then CfgUnzip  := 'UNZIP.EXE';
end;

procedure SaveConfig;
var
  T: Text;
begin
  Assign(T, 'FC.CFG');
  Rewrite(T);
  if IOResult = 0 then
  begin
    Writeln(T, CfgViewImg);
    Writeln(T, CfgEditor);
    Writeln(T, CfgUnzip);
    if CfgWeightBySize then Writeln(T, '1') else Writeln(T, '0');
    if CfgIsoDateTime then Writeln(T, '1') else Writeln(T, '0');
    if CfgConfirmOps then Writeln(T, '1') else Writeln(T, '0');
    Close(T);
  end;
end;

{===========================================================================}
{   CRITICAL ERROR HANDLER                                                  }
{===========================================================================}

procedure CriticalErrorHandler(Flags, CS, IP, AX, BX, CX, DX, SI, DI, DS, ES, BP: Word);
  interrupt;
begin
  AX := (AX and $FF00) or 3;
end;

{===========================================================================}
{   LOW-LEVEL HARDWARE & BIOS SERVICES (ZERO CRT)                           }
{===========================================================================}

procedure SetCursor(X, Y: Byte);
var
  Regs: Registers;
begin
  Regs.AH := $02;
  Regs.BH := 0;
  Regs.DH := Y;
  Regs.DL := X;
  Intr($10, Regs);
end;

procedure HideCursor;
var
  Regs: Registers;
begin
  Regs.AH := $01;
  Regs.CH := $20;
  Regs.CL := 0;
  Intr($10, Regs);
end;

procedure ShowCursor;
var
  Regs: Registers;
begin
  Regs.AH := $01;
  Regs.CH := 6;
  Regs.CL := 7;
  Intr($10, Regs);
end;

function ReadKeyBIOS(var ScanCode: Byte): Char;
var
  Regs: Registers;
begin
  Regs.AH := $00;
  Intr($16, Regs);
  ScanCode := Regs.AH;
  ReadKeyBIOS := Chr(Regs.AL);
end;

{ True when a keystroke is waiting, without consuming it (Int 16h AH=01). }
{ ZF clear means a key is available.                                       }
function KeyWaiting: Boolean;
var
  Regs: Registers;
begin
  Regs.AH := $01;
  Intr($16, Regs);
  KeyWaiting := (Regs.Flags and $40) = 0;
end;

{ Tick count via Int 1Ah. Safer than reading the BIOS data area directly:  }
{ it works regardless of how the BDA is mapped and cannot be cached.       }
function GetTicks: LongInt;
var
  Regs: Registers;
begin
  Regs.AH := $00;
  Intr($1A, Regs);
  GetTicks := (LongInt(Regs.CX) shl 16) or LongInt(Regs.DX);
end;

{===========================================================================}
{   MOUSE SUPPORT (INT 33h) - entirely optional                             }
{===========================================================================}

{ Calling INT 33h with no driver loaded would execute whatever sits at the }
{ unset vector, so probe it before touching the interrupt at all.          }
function MouseDriverPresent: Boolean;
var
  P: Pointer;
  Stub: ^Byte;
begin
  MouseDriverPresent := False;
  GetIntVec($33, P);
  if P = nil then Exit;           { vector never set }
  Stub := P;
  if Stub^ = $CF then Exit;   { bare IRET: vector exists but does nothing }
  MouseDriverPresent := True;
end;

{ Resets the driver. True when a mouse actually answers. }
function MouseInit: Boolean;
var
  Regs: Registers;
begin
  MouseInit := False;
  if not MouseDriverPresent then Exit;
  Regs.AX := $0000;
  Intr($33, Regs);
  MouseInit := Regs.AX = $FFFF;
end;

procedure MouseShow;
var
  Regs: Registers;
begin
  if not MouseAvailable then Exit;
  if MouseShown then Exit;
  Regs.AX := $0001;
  Intr($33, Regs);
  MouseShown := True;
end;

{ The driver restores cells by reading them back, so it must be hidden      }
{ before anything writes to video memory directly.                          }
procedure MouseHide;
var
  Regs: Registers;
begin
  if not MouseAvailable then Exit;
  if not MouseShown then Exit;
  Regs.AX := $0002;
  Intr($33, Regs);
  MouseShown := False;
end;

{ Press counter since the last call, plus where the last press happened.   }
{ Button 0 = left, 1 = right. Driver reports virtual pixels: 8 per cell.   }
function MousePress(Button: Integer; var Col, Row: Integer): Boolean;
var
  Regs: Registers;
begin
  MousePress := False;
  if not MouseAvailable then Exit;
  Regs.AX := $0005;
  Regs.BX := Button;
  Intr($33, Regs);
  Col := Regs.CX div 8;
  Row := Regs.DX div 8;
  MousePress := Regs.BX > 0;
end;

procedure WriteCell(X, Y: Integer; C: Char; Attr: Byte);
begin
  if (X >= 0) and (X <= 79) and (Y >= 0) and (Y <= 24) then
    VRAMW[Y * 80 + X] := (Word(Attr) shl 8) or Ord(C);
end;

{ Clips once up front, then stores one word per cell with no test in the loop }
procedure WriteStr(X, Y: Integer; const S: string; Attr: Byte);
var
  I, First, Last, Ofs: Integer;
  Hi: Word;
begin
  if (Y < 0) or (Y > 24) or (X > 79) then Exit;
  First := 1;
  Last := Length(S);
  if X < 0 then
  begin
    First := 1 - X;
    X := 0;
  end;
  if First > Last then Exit;
  if X + (Last - First + 1) > 80 then Last := First + (79 - X);
  Hi := Word(Attr) shl 8;
  Ofs := Y * 80 + X;
  for I := First to Last do
  begin
    VRAMW[Ofs] := Hi or Ord(S[I]);
    Inc(Ofs);
  end;
end;

procedure FillBox(X1, Y1, X2, Y2: Integer; C: Char; Attr: Byte);
var
  X, Y, Ofs: Integer;
  Cell: Word;
begin
  if X1 < 0 then X1 := 0;
  if Y1 < 0 then Y1 := 0;
  if X2 > 79 then X2 := 79;
  if Y2 > 24 then Y2 := 24;
  Cell := (Word(Attr) shl 8) or Ord(C);
  for Y := Y1 to Y2 do
  begin
    Ofs := Y * 80 + X1;
    for X := X1 to X2 do
    begin
      VRAMW[Ofs] := Cell;
      Inc(Ofs);
    end;
  end;
end;

function AltScanToChar(Scan: Byte): Char;
begin
  case Scan of
    $1E: AltScanToChar := 'A';  $30: AltScanToChar := 'B';
    $2E: AltScanToChar := 'C';  $20: AltScanToChar := 'D';
    $12: AltScanToChar := 'E';  $21: AltScanToChar := 'F';
    $22: AltScanToChar := 'G';  $23: AltScanToChar := 'H';
    $17: AltScanToChar := 'I';  $24: AltScanToChar := 'J';
    $25: AltScanToChar := 'K';  $26: AltScanToChar := 'L';
    $32: AltScanToChar := 'M';  $31: AltScanToChar := 'N';
    $18: AltScanToChar := 'O';  $19: AltScanToChar := 'P';
    $10: AltScanToChar := 'Q';  $13: AltScanToChar := 'R';
    $1F: AltScanToChar := 'S';  $14: AltScanToChar := 'T';
    $16: AltScanToChar := 'U';  $2F: AltScanToChar := 'V';
    $11: AltScanToChar := 'W';  $2D: AltScanToChar := 'X';
    $15: AltScanToChar := 'Y';  $2C: AltScanToChar := 'Z';
  else
    AltScanToChar := #0;
  end;
end;

{===========================================================================}
{   STRING & FORMATTING UTILITIES                                           }
{===========================================================================}

function IntToStr(V: LongInt): string;
var
  S: string;
begin
  Str(V, S);
  IntToStr := S;
end;

function UpCaseStr(const S: string): string;
var
  I: Integer;
  Res: string;
begin
  Res := S;
  for I := 1 to Length(Res) do
    Res[I] := UpCase(Res[I]);
  UpCaseStr := Res;
end;

{ True for the image types VIEW.EXE handles. A DOS 8.3 name truncates }
{ .JPEG to .JPE, so both spellings are accepted.                      }
function IsImageExt(const FName: string): Boolean;
var
  DotPos: Integer;
  Ext: string;
begin
  DotPos := Pos('.', FName);
  if DotPos = 0 then
  begin
    IsImageExt := False;
    Exit;
  end;
  Ext := UpCaseStr(Copy(FName, DotPos + 1, 3));
  IsImageExt := (Ext = 'BMP') or (Ext = 'JPG') or
                (Ext = 'JPE') or (Ext = 'GIF');
end;

function PadR(const S: string; Len: Byte): string;
var
  Res: string;
begin
  Res := S;
  while Length(Res) < Len do Res := Res + ' ';
  if Length(Res) > Len then Res := Copy(Res, 1, Len);
  PadR := Res;
end;

function PadL(const S: string; Len: Byte): string;
var
  Res: string;
begin
  Res := S;
  while Length(Res) < Len do Res := ' ' + Res;
  if Length(Res) > Len then Res := Copy(Res, Length(Res) - Len + 1, Len);
  PadL := Res;
end;

function PadZero(const S: string; Len: Byte): string;
var
  Res: string;
begin
  Res := S;
  while Length(Res) < Len do Res := '0' + Res;
  PadZero := Res;
end;

function FormatNCName(const RawName: string; IsDir: Boolean): string;
var
  DotPos: Integer;
  Base, Ext: string;
begin
  if RawName = '..' then
  begin
    FormatNCName := '..          ';
    Exit;
  end;
  DotPos := Pos('.', RawName);
  if DotPos > 0 then
  begin
    Base := Copy(RawName, 1, DotPos - 1);
    Ext := Copy(RawName, DotPos + 1, Length(RawName));
  end
  else
  begin
    Base := RawName;
    Ext := '';
  end;
  FormatNCName := PadR(Base, 8) + ' ' + PadR(Ext, 3);
end;

function FormatDate(TimeVal: LongInt): string;
var
  DT: DateTime;
begin
  if TimeVal = 0 then
  begin
    FormatDate := '';   { no timestamp, e.g. the [..] entry }
    Exit;
  end;
  UnpackTime(TimeVal, DT);
  if CfgIsoDateTime then
    FormatDate := PadZero(IntToStr(DT.Year mod 100), 2) + '-' +
                  PadZero(IntToStr(DT.Month), 2) + '-' +
                  PadZero(IntToStr(DT.Day), 2)
  else
    FormatDate := PadL(IntToStr(DT.Month), 2) + '-' +
                  PadZero(IntToStr(DT.Day), 2) + '-' +
                  PadZero(IntToStr(DT.Year mod 100), 2);
end;

function FormatTime(TimeVal: LongInt): string;
var
  DT: DateTime;
  Hour: Word;
  AmPm: Char;
begin
  if TimeVal = 0 then
  begin
    FormatTime := '';
    Exit;
  end;
  UnpackTime(TimeVal, DT);

  if CfgIsoDateTime then
  begin
    FormatTime := PadZero(IntToStr(DT.Hour), 2) + ':' +
                  PadZero(IntToStr(DT.Min), 2);
    Exit;
  end;

  Hour := DT.Hour;
  if Hour >= 12 then
  begin
    AmPm := 'p';
    if Hour > 12 then Dec(Hour, 12);
  end
  else
  begin
    AmPm := 'a';
    if Hour = 0 then Hour := 12;
  end;
  FormatTime := PadL(IntToStr(Hour), 2) + ':' + PadZero(IntToStr(DT.Min), 2) + AmPm;
end;

function GetDateVal(TVal: LongInt): LongInt;
var
  DT: DateTime;
begin
  if TVal = 0 then begin GetDateVal := 0; Exit; end;
  UnpackTime(TVal, DT);
  GetDateVal := (LongInt(DT.Year) * 10000) + (LongInt(DT.Month) * 100) + LongInt(DT.Day);
end;

function GetTimeVal(TVal: LongInt): LongInt;
var
  DT: DateTime;
begin
  if TVal = 0 then begin GetTimeVal := 0; Exit; end;
  UnpackTime(TVal, DT);
  GetTimeVal := (LongInt(DT.Hour) * 3600) + (LongInt(DT.Min) * 60) + LongInt(DT.Sec);
end;

function MatchMask(Pattern, Target: string): Boolean;
begin
  Pattern := UpCaseStr(Pattern);
  Target := UpCaseStr(Target);

  if (Pattern = '*') or (Pattern = '*.*') then
  begin
    MatchMask := True;
    Exit;
  end;

  while (Length(Pattern) > 0) and (Length(Target) > 0) do
  begin
    if Pattern[1] = '*' then
    begin
      Delete(Pattern, 1, 1);
      if Pattern = '' then begin MatchMask := True; Exit; end;
      while Length(Target) > 0 do
      begin
        if MatchMask(Pattern, Target) then begin MatchMask := True; Exit; end;
        Delete(Target, 1, 1);
      end;
      MatchMask := False;
      Exit;
    end
    else if (Pattern[1] = '?') or (Pattern[1] = Target[1]) then
    begin
      Delete(Pattern, 1, 1);
      Delete(Target, 1, 1);
    end
    else
    begin
      MatchMask := False;
      Exit;
    end;
  end;

  while (Length(Pattern) > 0) and (Pattern[1] = '*') do
    Delete(Pattern, 1, 1);

  MatchMask := (Pattern = '') and (Target = '');
end;

{===========================================================================}
{   TAGGING & QUICK SEARCH HELPERS                                          }
{===========================================================================}

function HasTagged(const Panel: TPanel): Boolean;
var
  I: Integer;
begin
  HasTagged := False;
  for I := 1 to Panel.Count do
    if Panel.Files[I].Tagged then begin HasTagged := True; Exit; end;
end;

function TaggedCount(const Panel: TPanel): Integer;
var
  I, C: Integer;
begin
  C := 0;
  for I := 1 to Panel.Count do
    if Panel.Files[I].Tagged then Inc(C);
  TaggedCount := C;
end;

function TaggedBytes(const Panel: TPanel): LongInt;
var
  I: Integer;
  B: LongInt;
begin
  B := 0;
  for I := 1 to Panel.Count do
    if Panel.Files[I].Tagged and not Panel.Files[I].IsDir then
      Inc(B, Panel.Files[I].Size);
  TaggedBytes := B;
end;

procedure DoQuickSearch(var Panel: TPanel; const S: string);
var
  I: Integer;
  UpperS, UpperName: string;
begin
  if (Panel.Count = 0) or (S = '') then Exit;
  UpperS := UpCaseStr(S);
  for I := 1 to Panel.Count do
  begin
    if Panel.Files[I].Name <> '..' then
    begin
      UpperName := UpCaseStr(Panel.Files[I].Name);
      if Pos(UpperS, UpperName) = 1 then
      begin
        Panel.Selected := I;
        Exit;
      end;
    end;
  end;
end;

{===========================================================================}
{   PATH & DRIVE NAVIGATION HELPERS                                         }
{===========================================================================}

function DriveExists(DriveLetter: Char): Boolean;
var
  Regs: Registers;
begin
  Regs.AH := $44;
  Regs.AL := $09;
  Regs.BL := Ord(UpCase(DriveLetter)) - Ord('A') + 1;
  Intr($21, Regs);
  DriveExists := (Regs.Flags and $01 = 0);
end;

function IsDirExists(P: string): Boolean;
var
  SR: SearchRec;
begin
  if (Length(P) > 3) and (P[Length(P)] = '\') then Dec(P[0]);
  if Length(P) = 2 then P := P + '\';
  if Length(P) = 3 then
  begin
    IsDirExists := DriveExists(P[1]);
    Exit;
  end;
  FindFirst(P, Directory, SR);
  IsDirExists := (DosError = 0) and ((SR.Attr and Directory) <> 0);
end;

function PathExists(const P: string): Boolean;
var
  SR: SearchRec;
begin
  FindFirst(P, ATTR_ALL_FILES, SR);
  PathExists := DosError = 0;
end;

{ Size of a single entry, 0 if it cannot be read }
function EntrySize(const P: string): LongInt;
var
  SR: SearchRec;
begin
  FindFirst(P, ATTR_ALL_FILES, SR);
  if DosError = 0 then EntrySize := SR.Size
  else EntrySize := 0;
end;

procedure NavigateUp(var Path: string);
begin
  if Length(Path) <= 3 then Exit;
  if Path[Length(Path)] = '\' then Dec(Path[0]);
  while (Length(Path) > 3) and (Path[Length(Path)] <> '\') do Dec(Path[0]);
  if Path[Length(Path)] <> '\' then Path := Path + '\';
end;

procedure NavigateDown(var Path: string; const SubDir: string);
begin
  if Path[Length(Path)] <> '\' then Path := Path + '\';
  Path := Path + SubDir + '\';
end;

{===========================================================================}
{   EXTERNAL PROCESS EXECUTION                                              }
{===========================================================================}

function LocateBinary(const ExeName: string): string;
var
  P: string;
begin
  P := FSearch(ExeName, '.;' + GetEnv('PATH'));
  if P = '' then P := ExeName;
  LocateBinary := P;
end;

procedure LaunchProgram(const BinaryPath, CmdLine: string; WaitKey: Boolean);
var
  DummyScan: Byte;
begin
  FillBox(0, 0, 79, 24, ' ', $07);
  SetCursor(0, 0);
  ShowCursor;

  MouseHide;

  SwapVectors;
  Exec(BinaryPath, CmdLine);
  SwapVectors;

  { The child may have reset or reprogrammed the driver }
  if MouseAvailable then
  begin
    MouseShown := False;
    MouseAvailable := MouseInit;
  end;

  HideCursor;

  if DosError <> 0 then
  begin
    WriteStr(0, 24, 'Exec Error [' + IntToStr(DosError) + '] launching: ' + BinaryPath, $4F);
    ReadKeyBIOS(DummyScan);
  end
  else if WaitKey then
  begin
    WriteStr(0, 24, 'Press any key to return to Commander...', $07);
    ReadKeyBIOS(DummyScan);
  end;

  RedrawScreen;
end;

{ Build the UNZIP.EXE command line: overwrite, junk paths, extract to DestDir }
function UnzipCmd(const ZipFile, Member, DestDir: string): string;
begin
  UnzipCmd := '-o -j ' + ZipFile + ' ' + Member + ' -d ' + DestDir;
end;

{===========================================================================}
{   ZIP ARCHIVE VIRTUAL DIRECTORY PARSER                                    }
{===========================================================================}

procedure AddZipEntry(var Panel: TPanel; const FullEntryName: string;
                      UncompSize, DosDateTime: LongInt; IsDirEntry: Boolean);
var
  S, ItemName, UpItem: string;
  SlashPos, J: Integer;
  AlreadyExists: Boolean;
begin
  S := FullEntryName;
  if Panel.SubPath <> '' then
  begin
    if Pos(UpCaseStr(Panel.SubPath), UpCaseStr(S)) <> 1 then Exit;
    Delete(S, 1, Length(Panel.SubPath));
  end;

  if (S = '') or (S = '/') then Exit;

  SlashPos := Pos('/', S);
  if SlashPos > 0 then
  begin
    ItemName := Copy(S, 1, SlashPos - 1);
    if ItemName = '' then Exit;

    AlreadyExists := False;
    UpItem := UpCaseStr(ItemName);
    for J := 1 to Panel.Count do
    begin
      if Panel.Files[J].IsDir and (UpCaseStr(Panel.Files[J].Name) = UpItem) then
      begin
        AlreadyExists := True;
        Break;
      end;
    end;

    if not AlreadyExists and (Panel.Count < MAX_FILES) then
    begin
      Inc(Panel.Count);
      Panel.Files[Panel.Count].Name := Copy(ItemName, 1, 12);
      Panel.Files[Panel.Count].ZipFullName :=
        Copy(FullEntryName, 1, Pos(ItemName, FullEntryName) + Length(ItemName) - 1);
      Panel.Files[Panel.Count].IsDir := True;
      Panel.Files[Panel.Count].Size := 0;
      Panel.Files[Panel.Count].Time := DosDateTime;
      Panel.Files[Panel.Count].Tagged := False;
    end;
  end
  else
  begin
    if S[Length(S)] = '/' then Dec(S[0]);
    if S = '' then Exit;

    AlreadyExists := False;
    UpItem := UpCaseStr(S);
    for J := 1 to Panel.Count do
    begin
      if UpCaseStr(Panel.Files[J].Name) = UpItem then
      begin
        AlreadyExists := True;
        Break;
      end;
    end;

    if not AlreadyExists and (Panel.Count < MAX_FILES) then
    begin
      Inc(Panel.Count);
      Panel.Files[Panel.Count].Name := Copy(S, 1, 12);
      Panel.Files[Panel.Count].ZipFullName := Copy(FullEntryName, 1, 48);
      Panel.Files[Panel.Count].IsDir := IsDirEntry;
      Panel.Files[Panel.Count].Size := UncompSize;
      Panel.Files[Panel.Count].Time := DosDateTime;
      Panel.Files[Panel.Count].Tagged := False;
    end;
  end;
end;

procedure ReadZipDirectory(var Panel: TPanel);
var
  F: file;
  FSize: LongInt;
  EOCD: TZipEOCD;
  CDH: TZipCDH;
  SearchBuf: array[0..1024] of Byte;
  SearchLen, ReadBytes: Word;
  I, J: Integer;
  EOCDPos: LongInt;
  FullName: string;
  IsDirEntry: Boolean;
begin
  Panel.Count := 0;
  Panel.Selected := 1;
  Panel.TopIndex := 1;
  Panel.Dirty := True;

  { [..] to ascend virtual zip directories or unmount }
  Inc(Panel.Count);
  Panel.Files[Panel.Count].Name := '..';
  Panel.Files[Panel.Count].ZipFullName := '..';
  Panel.Files[Panel.Count].IsDir := True;
  Panel.Files[Panel.Count].Size := 0;
  Panel.Files[Panel.Count].Time := 0;
  Panel.Files[Panel.Count].Tagged := False;

  Assign(F, Panel.ZipPath);
  Reset(F, 1);
  if IOResult <> 0 then Exit;

  FSize := FileSize(F);
  if FSize < 22 then
  begin
    Close(F);
    Exit;
  end;

  SearchLen := 1024;
  if SearchLen > FSize then SearchLen := FSize;
  Seek(F, FSize - SearchLen);
  BlockRead(F, SearchBuf, SearchLen, ReadBytes);

  EOCDPos := -1;
  for I := ReadBytes - 22 downto 0 do
  begin
    if (SearchBuf[I] = $50) and (SearchBuf[I+1] = $4B) and
       (SearchBuf[I+2] = $05) and (SearchBuf[I+3] = $06) then
    begin
      EOCDPos := (FSize - SearchLen) + I;
      Break;
    end;
  end;

  if EOCDPos < 0 then
  begin
    Close(F);
    Exit;
  end;

  Seek(F, EOCDPos);
  BlockRead(F, EOCD, SizeOf(EOCD));

  Seek(F, EOCD.CentralDirOffset);

  for I := 1 to EOCD.TotalEntries do
  begin
    if Panel.Count >= MAX_FILES then Break;
    BlockRead(F, CDH, SizeOf(CDH));
    if CDH.Sig <> $02014B50 then Break;

    FullName := '';
    if CDH.NameLen > 79 then CDH.NameLen := 79;
    FullName[0] := Chr(CDH.NameLen);
    BlockRead(F, FullName[1], CDH.NameLen);

    Seek(F, FilePos(F) + CDH.ExtraLen + CDH.CommentLen);

    for J := 1 to Length(FullName) do
      if FullName[J] = '\' then FullName[J] := '/';

    IsDirEntry := ((CDH.ExtAttr and $10) <> 0) or (FullName[Length(FullName)] = '/');
    AddZipEntry(Panel, FullName, CDH.UncompSize, CDH.DosTime, IsDirEntry);
  end;

  Close(F);
  if Panel.Count > 1 then
    SortDirectory(Panel);
end;

{===========================================================================}
{   FILE SYSTEM & SORTING ENGINE                                            }
{===========================================================================}

function IsLess(const A, B: TFileEntry; Col: TSortCol): Boolean;
var
  D1, D2, T1, T2: LongInt;
begin
  case Col of
    scName:
      IsLess := A.Name < B.Name;
    scSize:
      if A.Size <> B.Size then IsLess := A.Size < B.Size
      else IsLess := A.Name < B.Name;
    scDate:
      begin
        D1 := GetDateVal(A.Time);
        D2 := GetDateVal(B.Time);
        if D1 <> D2 then IsLess := D1 < D2
        else IsLess := A.Name < B.Name;
      end;
    scTime:
      begin
        T1 := GetTimeVal(A.Time);
        T2 := GetTimeVal(B.Time);
        if T1 <> T2 then IsLess := T1 < T2
        else IsLess := A.Name < B.Name;
      end;
  end;
end;

function ShouldPrecede(const A, B: TFileEntry; Col: TSortCol; Dir: TSortDir): Boolean;
begin
  if A.Name = '..' then begin ShouldPrecede := True; Exit; end;
  if B.Name = '..' then begin ShouldPrecede := False; Exit; end;
  if A.IsDir and not B.IsDir then begin ShouldPrecede := True; Exit; end;
  if not A.IsDir and B.IsDir then begin ShouldPrecede := False; Exit; end;

  if Dir = sdAsc then
    ShouldPrecede := IsLess(A, B, Col)
  else
    ShouldPrecede := IsLess(B, A, Col);
end;

procedure SortDirectory(var Panel: TPanel);
var
  I, J: Integer;
  Temp: TFileEntry;
begin
  for I := 2 to Panel.Count do
  begin
    Temp := Panel.Files[I];
    J := I - 1;
    while (J >= 1) and ShouldPrecede(Temp, Panel.Files[J], Panel.SortCol, Panel.SortDir) do
    begin
      if Panel.Files[J].Name = '..' then Break;
      Panel.Files[J + 1] := Panel.Files[J];
      Dec(J);
    end;
    Panel.Files[J + 1] := Temp;
  end;
end;

procedure ApplySort(var Panel: TPanel; NewCol: TSortCol);
var
  CurFileName: string[12];
  I: Integer;
begin
  if Panel.Count = 0 then Exit;

  if (Panel.Selected >= 1) and (Panel.Selected <= Panel.Count) then
    CurFileName := Panel.Files[Panel.Selected].Name
  else
    CurFileName := '';

  if Panel.SortCol = NewCol then
  begin
    if Panel.SortDir = sdAsc then Panel.SortDir := sdDesc
    else Panel.SortDir := sdAsc;
  end
  else
  begin
    Panel.SortCol := NewCol;
    Panel.SortDir := sdAsc;
  end;

  SortDirectory(Panel);

  if CurFileName <> '' then
  begin
    for I := 1 to Panel.Count do
    begin
      if Panel.Files[I].Name = CurFileName then
      begin
        Panel.Selected := I;
        Break;
      end;
    end;
  end;
end;

procedure ReadDirectory(var Panel: TPanel);
var
  SR: SearchRec;
begin
  if Panel.InsideZip then
  begin
    ReadZipDirectory(Panel);
    Exit;
  end;

  Panel.Count := 0;
  Panel.Selected := 1;
  Panel.TopIndex := 1;
  Panel.Dirty := True;

  FindFirst(Panel.Path + '*.*', Directory or Archive or ReadOnly, SR);
  if (DosError <> 0) and (Length(Panel.Path) > 3) then
  begin
    NavigateUp(Panel.Path);
    ReadDirectory(Panel);
    Exit;
  end;

  if Length(Panel.Path) > 3 then
  begin
    Inc(Panel.Count);
    Panel.Files[Panel.Count].Name := '..';
    Panel.Files[Panel.Count].ZipFullName := '';
    Panel.Files[Panel.Count].IsDir := True;
    Panel.Files[Panel.Count].Size := 0;
    Panel.Files[Panel.Count].Time := 0;
    Panel.Files[Panel.Count].Attr := Directory;
    Panel.Files[Panel.Count].Tagged := False;
  end;

  FindFirst(Panel.Path + '*.*', Directory or Archive or ReadOnly, SR);
  while (DosError = 0) and (Panel.Count < MAX_FILES) do
  begin
    if (SR.Name <> '.') and (SR.Name <> '..') then
    begin
      Inc(Panel.Count);
      Panel.Files[Panel.Count].Name := SR.Name;
      Panel.Files[Panel.Count].ZipFullName := '';
      Panel.Files[Panel.Count].IsDir := (SR.Attr and Directory) <> 0;
      Panel.Files[Panel.Count].Size := SR.Size;
      Panel.Files[Panel.Count].Time := SR.Time;
      Panel.Files[Panel.Count].Attr := SR.Attr;
      Panel.Files[Panel.Count].Tagged := False;
    end;
    FindNext(SR);
  end;

  if Panel.Count > 1 then
    SortDirectory(Panel);
end;

{ Last path component, e.g. C:\WORK\TOOLS -> TOOLS, or A.ZIP from a full path }
function LastComponent(P: string): string;
var
  I: Integer;
begin
  if (Length(P) > 0) and (P[Length(P)] = '\') then Dec(P[0]);
  I := Length(P);
  while (I > 0) and (P[I] <> '\') do Dec(I);
  LastComponent := Copy(P, I + 1, Length(P) - I);
end;

{ Puts the cursor on a named entry and scrolls it roughly into the middle }
procedure SelectByName(var Panel: TPanel; const N: string);
var
  I: Integer;
begin
  if N = '' then Exit;
  for I := 1 to Panel.Count do
  begin
    if Panel.Files[I].Name = N then
    begin
      Panel.Selected := I;
      Panel.TopIndex := I - (PANEL_ROWS div 2);
      if Panel.TopIndex < 1 then Panel.TopIndex := 1;
      Panel.Dirty := True;
      Exit;
    end;
  end;
end;

{ Re-reads the listing but keeps the cursor where the user left it.        }
{ Used after any operation that changes the contents of a panel; plain    }
{ ReadDirectory is for navigation, where starting at the top is correct.  }
procedure RefreshDirectory(var Panel: TPanel);
var
  KeepName: string[12];
  KeepSel, KeepTop, I: Integer;
  Found: Boolean;
begin
  KeepName := '';
  if (Panel.Selected >= 1) and (Panel.Selected <= Panel.Count) then
    KeepName := Panel.Files[Panel.Selected].Name;
  KeepSel := Panel.Selected;
  KeepTop := Panel.TopIndex;

  ReadDirectory(Panel);

  Found := False;
  if KeepName <> '' then
  begin
    for I := 1 to Panel.Count do
    begin
      if Panel.Files[I].Name = KeepName then
      begin
        Panel.Selected := I;
        Found := True;
        Break;
      end;
    end;
  end;

  { The entry is gone - deleted or moved away - so hold the same position }
  if not Found then
  begin
    Panel.Selected := KeepSel;
    if Panel.Selected > Panel.Count then Panel.Selected := Panel.Count;
    if Panel.Selected < 1 then Panel.Selected := 1;
  end;

  { Keep the old scroll offset where it still makes sense, so the list }
  { does not jump under the cursor }
  if (KeepTop >= 1) and (KeepTop <= Panel.Count) then
    Panel.TopIndex := KeepTop
  else
    Panel.TopIndex := 1;

  Panel.Dirty := True;
end;

{===========================================================================}
{   MODAL DIALOG INPUT - clickable hot zones                                }
{===========================================================================}

const
  MAX_ZONES = 16;

type
  TZone = record
    X1, Y1, X2, Y2: Integer;
    Id: Integer;
  end;

var
  Zones: array[1..MAX_ZONES] of TZone;
  ZoneCount: Integer;

procedure ZonesClear;
begin
  ZoneCount := 0;
end;

procedure ZoneAdd(X1, Y1, X2, Y2, Id: Integer);
begin
  if ZoneCount >= MAX_ZONES then Exit;
  Inc(ZoneCount);
  Zones[ZoneCount].X1 := X1;
  Zones[ZoneCount].Y1 := Y1;
  Zones[ZoneCount].X2 := X2;
  Zones[ZoneCount].Y2 := Y2;
  Zones[ZoneCount].Id := Id;
end;

{ Id of the zone under a point, or -1 }
function ZoneAt(Col, Row: Integer): Integer;
var
  I: Integer;
begin
  ZoneAt := -1;
  for I := 1 to ZoneCount do
  begin
    if (Col >= Zones[I].X1) and (Col <= Zones[I].X2) and
       (Row >= Zones[I].Y1) and (Row <= Zones[I].Y2) then
    begin
      ZoneAt := Zones[I].Id;
      Exit;
    end;
  end;
end;

{ Discards clicks that happened before a dialog opened }
procedure MouseFlush;
var
  Col, Row: Integer;
begin
  if not MouseAvailable then Exit;
  MousePress(0, Col, Row);
  MousePress(1, Col, Row);
end;

{ Blocks until a key is pressed or a registered zone is clicked.           }
{ True means a zone was hit and ZoneId holds its id; False means a key.    }
{ The pointer is shown only while waiting, never while the dialog paints.  }
function DialogEvent(var Ch: Char; var Scan: Byte; var ZoneId: Integer): Boolean;
var
  Col, Row: Integer;
begin
  ZoneId := -1;
  if not MouseAvailable then
  begin
    Ch := ReadKeyBIOS(Scan);
    DialogEvent := False;
    Exit;
  end;

  MouseShow;
  repeat
    if MousePress(0, Col, Row) then
    begin
      ZoneId := ZoneAt(Col, Row);
      if ZoneId >= 0 then
      begin
        MouseHide;
        DialogEvent := True;
        Exit;
      end;
    end;
    if KeyWaiting then
    begin
      MouseHide;
      Ch := ReadKeyBIOS(Scan);
      DialogEvent := False;
      Exit;
    end;
  until False;
end;

{===========================================================================}
{   DIALOG BOXES & PROMPTS                                                  }
{===========================================================================}

procedure DrawDialogFrame(X1, Y1, X2, Y2: Integer; const Title: string);
var
  X, Y: Integer;
begin
  MouseHide;   { the next full refresh brings the pointer back }
  MouseFlush;  { ignore clicks made before this dialog appeared }
  for Y := Y1 + 1 to Y2 + 1 do
    for X := X2 + 1 to X2 + 2 do
      if (X < 80) and (Y < 25) then
        VRAM[Y, X].Attr := $07;
  for X := X1 + 2 to X2 + 2 do
    if (X < 80) and (Y2 + 1 < 25) then
      VRAM[Y2 + 1, X].Attr := $07;

  FillBox(X1, Y1, X2, Y2, ' ', ATTR_DIALOG_BG);

  for X := X1 + 1 to X2 - 1 do
  begin
    WriteCell(X, Y1, #205, ATTR_DIALOG_BD);
    WriteCell(X, Y2, #205, ATTR_DIALOG_BD);
  end;
  for Y := Y1 + 1 to Y2 - 1 do
  begin
    WriteCell(X1, Y, #186, ATTR_DIALOG_BD);
    WriteCell(X2, Y, #186, ATTR_DIALOG_BD);
  end;
  WriteCell(X1, Y1, #201, ATTR_DIALOG_BD);
  WriteCell(X2, Y1, #187, ATTR_DIALOG_BD);
  WriteCell(X1, Y2, #200, ATTR_DIALOG_BD);
  WriteCell(X2, Y2, #188, ATTR_DIALOG_BD);

  WriteStr(X1 + ((X2 - X1 - Length(Title)) div 2), Y1, ' ' + Title + ' ', ATTR_DIALOG_HL);
end;

function DialogPrompt(const Title, Prompt: string; var InStr: string): Boolean;
var
  Ch: Char;
  Scan: Byte;
  Zone: Integer;
begin
  DrawDialogFrame(15, 8, 65, 14, Title);
  WriteStr(18, 10, Prompt, ATTR_DIALOG_BG);
  FillBox(18, 12, 62, 12, ' ', $1F);
  WriteStr(18, 12, InStr, $1F);
  WriteStr(28, 13, '[  OK  ]', ATTR_DIALOG_BG);
  WriteStr(42, 13, '[ Cancel ]', ATTR_DIALOG_BG);

  ZonesClear;
  ZoneAdd(28, 13, 35, 13, 1);
  ZoneAdd(42, 13, 51, 13, 0);

  ShowCursor;
  while True do
  begin
    SetCursor(18 + Length(InStr), 12);
    if DialogEvent(Ch, Scan, Zone) then
    begin
      DialogPrompt := Zone = 1;
      Break;
    end;
    if Ch = #13 then begin DialogPrompt := True; Break; end
    else if Ch = #27 then begin DialogPrompt := False; Break; end
    else if Ch = #8 then
    begin
      if Length(InStr) > 0 then
      begin
        Dec(InStr[0]);
        FillBox(18, 12, 62, 12, ' ', $1F);
        WriteStr(18, 12, InStr, $1F);
      end;
    end
    else if (Ch in [#32..#126]) and (Length(InStr) < 40) then
    begin
      InStr := InStr + Ch;
      WriteStr(18, 12, InStr, $1F);
    end;
  end;
  HideCursor;
end;

function DialogConfirm(const Title, Prompt: string): Boolean;
var
  Ch: Char;
  Scan: Byte;
  Zone: Integer;
  SelYes: Boolean;
  AttrYes, AttrNo: Byte;
begin
  DrawDialogFrame(12, 9, 68, 14, Title);
  WriteStr(15, 11, PadR(Copy(Prompt, 1, 51), 51), ATTR_DIALOG_BG);

  SelYes := True;
  ZonesClear;
  ZoneAdd(24, 13, 32, 13, 1);
  ZoneAdd(44, 13, 52, 13, 0);

  while True do
  begin
    if SelYes then begin AttrYes := ATTR_SELECTED; AttrNo := ATTR_DIALOG_BG; end
    else begin AttrYes := ATTR_DIALOG_BG; AttrNo := ATTR_SELECTED; end;

    WriteStr(24, 13, '[  Yes  ]', AttrYes);
    WriteStr(44, 13, '[  No   ]', AttrNo);

    if DialogEvent(Ch, Scan, Zone) then
    begin
      DialogConfirm := Zone = 1;
      Exit;
    end;

    if Ch = #0 then
    begin
      case Scan of
        KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN: SelYes := not SelYes;
      end;
    end
    else
    begin
      case Ch of
        #9: SelYes := not SelYes;
        #13: begin DialogConfirm := SelYes; Exit; end;
        #27: begin DialogConfirm := False; Exit; end;
        'y', 'Y': begin DialogConfirm := True; Exit; end;
        'n', 'N': begin DialogConfirm := False; Exit; end;
      end;
    end;
  end;
end;

procedure DialogInfo(const Title, Msg: string);
var
  Ch: Char;
  Scan: Byte;
  Zone: Integer;
begin
  DrawDialogFrame(12, 9, 68, 14, Title);
  WriteStr(15, 11, PadR(Copy(Msg, 1, 51), 51), ATTR_DIALOG_BG);
  WriteStr(34, 13, '[  OK  ]', ATTR_SELECTED);
  ZonesClear;
  ZoneAdd(34, 13, 41, 13, 0);
  DialogEvent(Ch, Scan, Zone);   { any key, or the OK button }
end;

{===========================================================================}
{   OPERATION CONFIRMATION & FAILURE TRACKING                               }
{===========================================================================}

const
  RP_YES    = 0;
  RP_NO     = 1;
  RP_ALL    = 2;
  RP_CANCEL = 3;

var
  OpFailCount: Integer;
  OpFailFirst: string[12];
  OpReplaceAll: Boolean;   { user answered All to a replace prompt }
  OpCancelled: Boolean;    { user answered Cancel; unwind the operation }
  OpLastSkipped: Boolean;  { last copy was declined, not failed }

procedure ResetOperation;
begin
  OpFailCount := 0;
  OpFailFirst := '';
  OpReplaceAll := False;
  OpCancelled := False;
  OpLastSkipped := False;
end;

procedure NoteFailure(const ItemName: string);
begin
  Inc(OpFailCount);
  if OpFailCount = 1 then OpFailFirst := Copy(ItemName, 1, 12);
end;

{ Pops up only when something actually went wrong }
procedure ReportFailures(const Title, Verb: string);
begin
  if OpFailCount = 0 then Exit;
  if OpFailCount = 1 then
    DialogInfo(Title, 'Could not ' + Verb + ' ' + OpFailFirst + '.')
  else
    DialogInfo(Title, 'Could not ' + Verb + ' ' + IntToStr(OpFailCount) +
               ' items. First: ' + OpFailFirst + '.');
end;

{ Delete/overwrite prompts obey the configuration checkbox }
function ConfirmOp(const Title, Prompt: string): Boolean;
begin
  if not CfgConfirmOps then ConfirmOp := True
  else ConfirmOp := DialogConfirm(Title, Prompt);
end;

{ Four-way prompt so a batch does not need one answer per file }
function DialogReplace(const ItemName: string): Integer;
var
  Ch: Char;
  Scan: Byte;
  Zone, Sel, I: Integer;
  Attr: array[0..3] of Byte;
  Labels: array[0..3] of string[10];
  Xs: array[0..3] of Integer;
begin
  Labels[0] := '[  Yes  ]';
  Labels[1] := '[  No   ]';
  Labels[2] := '[  All  ]';
  Labels[3] := '[Cancel ]';
  Xs[0] := 14; Xs[1] := 27; Xs[2] := 40; Xs[3] := 53;
  Sel := 0;

  DrawDialogFrame(10, 9, 70, 16, 'Replace?');
  WriteStr(13, 11, 'File already exists:', ATTR_DIALOG_BG);
  WriteStr(13, 12, PadR(Copy(ItemName, 1, 44), 44), ATTR_DIALOG_HL);

  ZonesClear;
  for I := 0 to 3 do
    ZoneAdd(Xs[I], 14, Xs[I] + 8, 14, I);

  while True do
  begin
    for I := 0 to 3 do
      if I = Sel then Attr[I] := ATTR_SELECTED else Attr[I] := ATTR_DIALOG_BG;
    for I := 0 to 3 do
      WriteStr(Xs[I], 14, Labels[I], Attr[I]);

    if DialogEvent(Ch, Scan, Zone) then
    begin
      DialogReplace := Zone;
      Exit;
    end;

    if Ch = #0 then
    begin
      case Scan of
        KEY_LEFT:  if Sel > 0 then Dec(Sel) else Sel := 3;
        KEY_RIGHT: if Sel < 3 then Inc(Sel) else Sel := 0;
      end;
    end
    else
    begin
      case Ch of
        #9: Sel := (Sel + 1) mod 4;
        #13: begin DialogReplace := Sel; Exit; end;
        #27: begin DialogReplace := RP_CANCEL; Exit; end;
        'y', 'Y': begin DialogReplace := RP_YES; Exit; end;
        'n', 'N': begin DialogReplace := RP_NO; Exit; end;
        'a', 'A': begin DialogReplace := RP_ALL; Exit; end;
        'c', 'C': begin DialogReplace := RP_CANCEL; Exit; end;
      end;
    end;
  end;
end;

{===========================================================================}
{   PROGRESS BAR (COPY / DELETE)                                            }
{   Weight = 1 per item by default, or bytes when CfgWeightBySize is set.   }
{===========================================================================}

const
  PROG_X1       = 14;   { Frame left  }
  PROG_X2       = 66;   { Frame right }
  PROG_Y1       = 8;    { Frame top   }
  PROG_Y2       = 15;   { Frame bottom }
  PROG_BAR_X    = 16;
  PROG_BAR_W    = 49;
  PROG_BAR_Y    = 14;
  ATTR_PROG_BAR = $70;  { Black on Light Gray }
  PROG_MIN_TICKS = 7;   { ~0.4s minimum visibility (18.2 ticks/sec) }
  PROG_MAX_SPINS = 30000;  { Ceiling in case the tick count never advances }
  DBLCLICK_TICKS = 9;      { ~0.5s between clicks counts as a double click }

var
  ProgTotal, ProgDone: LongInt;
  ProgLastPct: Integer;
  ProgOpenTick: LongInt;
  ProgActive: Boolean;
  { Kept so the dialog can be restored after a prompt draws over it }
  ProgTitle: string[20];
  ProgVerb: string[40];
  ProgSrc, ProgDst: string[60];

{ Returns how much one item contributes to the progress total }
function ProgressWeight(Size: LongInt): LongInt;
begin
  if CfgWeightBySize then ProgressWeight := Size
  else ProgressWeight := 1;
end;

{ Clears one interior line and writes S centred inside the frame }
procedure ProgressLine(Y: Integer; const S: string);
var
  Disp: string;
  L: Integer;
begin
  Disp := S;
  if Length(Disp) > 49 then
    Disp := Copy(Disp, Length(Disp) - 48, 49);
  FillBox(PROG_X1 + 1, Y, PROG_X2 - 1, Y, ' ', ATTR_DIALOG_BG);
  L := PROG_X1 + 1 + ((PROG_X2 - PROG_X1 - 1 - Length(Disp)) div 2);
  WriteStr(L, Y, Disp, ATTR_DIALOG_BG);
end;

procedure ProgressDrawBar;
var
  Pct, Filled, X: Integer;
begin
  if ProgTotal > 1000000 then
    Pct := ProgDone div (ProgTotal div 100)
  else
    Pct := (ProgDone * 100) div ProgTotal;
  if Pct > 100 then Pct := 100;
  if Pct < 0 then Pct := 0;

  if Pct = ProgLastPct then Exit;
  ProgLastPct := Pct;

  Filled := (Pct * PROG_BAR_W) div 100;
  for X := 0 to PROG_BAR_W - 1 do
  begin
    if X < Filled then WriteCell(PROG_BAR_X + X, PROG_BAR_Y, #219, ATTR_PROG_BAR)
    else WriteCell(PROG_BAR_X + X, PROG_BAR_Y, #176, ATTR_PROG_BAR);
  end;
end;

{ Title e.g. 'Copy'; Verb e.g. 'Copying the file or directory' }
procedure ProgressOpen(const Title, Verb: string; Total: LongInt);
begin
  ProgTotal := Total;
  if ProgTotal < 1 then ProgTotal := 1;
  ProgDone := 0;
  ProgLastPct := -1;
  ProgOpenTick := GetTicks;
  ProgActive := True;

  ProgTitle := Copy(Title, 1, 20);
  ProgVerb := Copy(Verb, 1, 40);
  ProgSrc := '';
  ProgDst := '';

  DrawDialogFrame(PROG_X1, PROG_Y1, PROG_X2, PROG_Y2, Title);
  ProgressLine(PROG_Y1 + 1, Verb);
  ProgressDrawBar;
end;

{ Shows the current source name and, when given, the 'to' destination }
procedure ProgressNames(const Src, Dest: string);
begin
  if not ProgActive then Exit;
  ProgSrc := Copy(Src, 1, 60);
  ProgDst := Copy(Dest, 1, 60);
  ProgressLine(PROG_Y1 + 2, Src);
  if Dest <> '' then
  begin
    ProgressLine(PROG_Y1 + 3, 'to');
    ProgressLine(PROG_Y1 + 4, Dest);
  end
  else
  begin
    ProgressLine(PROG_Y1 + 3, '');
    ProgressLine(PROG_Y1 + 4, '');
  end;
end;

{ Redraws the whole dialog after another window has covered it }
procedure ProgressRepaint;
begin
  if not ProgActive then Exit;
  DrawDialogFrame(PROG_X1, PROG_Y1, PROG_X2, PROG_Y2, ProgTitle);
  ProgressLine(PROG_Y1 + 1, ProgVerb);
  ProgressLine(PROG_Y1 + 2, ProgSrc);
  if ProgDst <> '' then
  begin
    ProgressLine(PROG_Y1 + 3, 'to');
    ProgressLine(PROG_Y1 + 4, ProgDst);
  end;
  ProgLastPct := -1;   { force the bar to redraw }
  ProgressDrawBar;
end;

procedure ProgressAdd(Amount: LongInt);
begin
  if not ProgActive then Exit;
  Inc(ProgDone, Amount);
  if ProgDone > ProgTotal then ProgDone := ProgTotal;
  ProgressDrawBar;
end;

{ Fills the bar and holds it briefly so fast operations remain visible }
procedure ProgressClose;
var
  Target: LongInt;
  Spins: LongInt;
begin
  if not ProgActive then Exit;
  ProgDone := ProgTotal;
  ProgressDrawBar;

  { Hold the finished bar briefly so fast operations stay visible.          }
  { Three independent exits, so this can never wedge the program: the timer }
  { advancing, any keystroke, or the spin ceiling.                          }
  Target := GetTicks + PROG_MIN_TICKS;
  Spins := 0;
  while (GetTicks < Target) and (Spins < PROG_MAX_SPINS) do
  begin
    Inc(Spins);
    if KeyWaiting then Break;
  end;

  ProgActive := False;
end;

procedure DialogFilter(var Panel: TPanel);
var
  Mask: string[30];
  SelFiles, SelDirs, RevSel: Boolean;
  CurField: Integer;
  Ch: Char;
  Scan: Byte;
  I: Integer;
  Zone: Integer;
  AttrMask, AttrFBox, AttrDBox, AttrRBox, AttrOk, AttrCan: Byte;

  { Applies the mask to the panel; shared by Enter and the OK button }
  procedure ApplySelection;
  var
    J: Integer;
  begin
    for J := 1 to Panel.Count do
    begin
      if Panel.Files[J].Name = '..' then Continue;
      if not ((Panel.Files[J].IsDir and SelDirs) or
              ((not Panel.Files[J].IsDir) and SelFiles)) then Continue;

      if RevSel then
      begin
        if (Mask = '*.*') or (Mask = '*') then
          Panel.Files[J].Tagged := not Panel.Files[J].Tagged
        else if not MatchMask(Mask, Panel.Files[J].Name) then
          Panel.Files[J].Tagged := True
        else
          Panel.Files[J].Tagged := False;
      end
      else if MatchMask(Mask, Panel.Files[J].Name) then
        Panel.Files[J].Tagged := True;
    end;
  end;

begin
  Mask := '*.*';
  SelFiles := True;
  SelDirs := True;
  RevSel := False;
  CurField := 0;

  DrawDialogFrame(16, 5, 64, 18, 'Select / Filter');
  WriteStr(20, 7, 'File Mask:', ATTR_DIALOG_BG);

  ZonesClear;
  ZoneAdd(20,  8, 60,  8, 0);
  ZoneAdd(22, 10, 44, 10, 1);
  ZoneAdd(22, 11, 44, 11, 2);
  ZoneAdd(22, 12, 44, 12, 3);
  ZoneAdd(25, 15, 32, 15, 4);
  ZoneAdd(41, 15, 50, 15, 5);

  while True do
  begin
    if CurField = 0 then AttrMask := $1F else AttrMask := $7F;
    if CurField = 1 then AttrFBox := ATTR_SELECTED else AttrFBox := ATTR_DIALOG_BG;
    if CurField = 2 then AttrDBox := ATTR_SELECTED else AttrDBox := ATTR_DIALOG_BG;
    if CurField = 3 then AttrRBox := ATTR_SELECTED else AttrRBox := ATTR_DIALOG_BG;
    if CurField = 4 then AttrOk   := ATTR_SELECTED else AttrOk   := ATTR_DIALOG_BG;
    if CurField = 5 then AttrCan  := ATTR_SELECTED else AttrCan  := ATTR_DIALOG_BG;

    FillBox(20, 8, 60, 8, ' ', AttrMask);
    WriteStr(20, 8, Mask, AttrMask);

    if SelFiles then WriteStr(22, 10, '[X] Files', AttrFBox)
    else WriteStr(22, 10, '[ ] Files', AttrFBox);

    if SelDirs then WriteStr(22, 11, '[X] Directories', AttrDBox)
    else WriteStr(22, 11, '[ ] Directories', AttrDBox);

    if RevSel then WriteStr(22, 12, '[X] Reverse selection', AttrRBox)
    else WriteStr(22, 12, '[ ] Reverse selection', AttrRBox);

    WriteStr(25, 15, '[  OK  ]', AttrOk);
    WriteStr(41, 15, '[ Cancel ]', AttrCan);

    if CurField = 0 then
    begin
      ShowCursor;
      SetCursor(20 + Length(Mask), 8);
    end
    else
      HideCursor;

    if DialogEvent(Ch, Scan, Zone) then
    begin
      CurField := Zone;
      case Zone of
        1: SelFiles := not SelFiles;
        2: SelDirs := not SelDirs;
        3: RevSel := not RevSel;
        4: begin ApplySelection; Break; end;
        5: Break;
      end;
      Continue;
    end;

    if Ch = #0 then
    begin
      case Scan of
        KEY_UP:
          begin
            if CurField = 0 then CurField := 4
            else if CurField in [1..3] then Dec(CurField)
            else if CurField in [4, 5] then CurField := 3;
          end;
        KEY_DOWN:
          begin
            if CurField < 4 then Inc(CurField)
            else CurField := 0;
          end;
        KEY_LEFT, KEY_RIGHT:
          begin
            if CurField = 4 then CurField := 5
            else if CurField = 5 then CurField := 4;
          end;
      end;
    end
    else
    begin
      case Ch of
        #9: CurField := (CurField + 1) mod 6;
        ' ':
          begin
            if CurField = 1 then SelFiles := not SelFiles
            else if CurField = 2 then SelDirs := not SelDirs
            else if CurField = 3 then RevSel := not RevSel
            else if (CurField = 0) and (Length(Mask) < 25) then
              Mask := Mask + ' ';
          end;
        #13:
          begin
            if CurField = 5 then Break;
            ApplySelection;
            Break;
          end;
        #27: Break;
        #8:
          begin
            if (CurField = 0) and (Length(Mask) > 0) then Dec(Mask[0]);
          end;
        #32..#126:
          begin
            if (CurField = 0) and (Length(Mask) < 25) then Mask := Mask + Ch;
          end;
      end;
    end;
  end;
  HideCursor;
end;

{===========================================================================}
{   SETTINGS DIALOG (F2 - VIEWER, EDITOR, UNZIP, DISPLAY OPTIONS)          }
{===========================================================================}

procedure DialogSettings;
var
  TPath, EPath, UPath: string[60];
  WeightSize, IsoFmt, ConfirmOps: Boolean;
  { 0-2 paths, 3 weight, 4 date/time, 5 confirm, 6 Save, 7 Cancel }
  CurField: Integer;
  Ch: Char;
  Scan: Byte;
  Zone: Integer;
  AttrTel, AttrEd, AttrUnz: Byte;
  AttrChk, AttrIso, AttrCnf, AttrSave, AttrCancel: Byte;
begin
  TPath := CfgViewImg;
  EPath := CfgEditor;
  UPath := CfgUnzip;
  WeightSize := CfgWeightBySize;
  IsoFmt := CfgIsoDateTime;
  ConfirmOps := CfgConfirmOps;
  CurField := 0;

  { Clickable: the three path fields, three checkboxes, Save and Cancel }
  ZonesClear;
  ZoneAdd(11,  7, 69,  7, 0);
  ZoneAdd(11, 10, 69, 10, 1);
  ZoneAdd(11, 13, 69, 13, 2);
  ZoneAdd(11, 15, 46, 15, 3);
  ZoneAdd(11, 16, 46, 16, 4);
  ZoneAdd(11, 17, 46, 17, 5);
  ZoneAdd(24, 19, 33, 19, 6);
  ZoneAdd(44, 19, 53, 19, 7);

  DrawDialogFrame(8, 4, 72, 21, 'Configuration');
  WriteStr(11,  6, 'Image Viewer Executable:', ATTR_DIALOG_BG);
  WriteStr(11,  9, 'Editor / Viewer Executable:', ATTR_DIALOG_BG);
  WriteStr(11, 12, 'Unzip Utility Executable:', ATTR_DIALOG_BG);

  while True do
  begin
    if CurField = 0 then AttrTel := $1F else AttrTel := $7F;
    if CurField = 1 then AttrEd  := $1F else AttrEd  := $7F;
    if CurField = 2 then AttrUnz := $1F else AttrUnz := $7F;

    if CurField = 3 then AttrChk := ATTR_SELECTED else AttrChk := ATTR_DIALOG_BG;
    if CurField = 4 then AttrIso := ATTR_SELECTED else AttrIso := ATTR_DIALOG_BG;
    if CurField = 5 then AttrCnf := ATTR_SELECTED else AttrCnf := ATTR_DIALOG_BG;
    if CurField = 6 then AttrSave := ATTR_SELECTED else AttrSave := ATTR_DIALOG_BG;
    if CurField = 7 then AttrCancel := ATTR_SELECTED else AttrCancel := ATTR_DIALOG_BG;

    FillBox(11,  7, 69,  7, ' ', AttrTel);
    WriteStr(11,  7, TPath, AttrTel);

    FillBox(11, 10, 69, 10, ' ', AttrEd);
    WriteStr(11, 10, EPath, AttrEd);

    FillBox(11, 13, 69, 13, ' ', AttrUnz);
    WriteStr(11, 13, UPath, AttrUnz);

    if WeightSize then
      WriteStr(11, 15, '[X] Weight progress bar by file size', AttrChk)
    else
      WriteStr(11, 15, '[ ] Weight progress bar by file size', AttrChk);

    if IsoFmt then
      WriteStr(11, 16, '[X] 24-hour time and YY-MM-DD dates ', AttrIso)
    else
      WriteStr(11, 16, '[ ] 24-hour time and YY-MM-DD dates ', AttrIso);

    if ConfirmOps then
      WriteStr(11, 17, '[X] Ask before replacing or deleting', AttrCnf)
    else
      WriteStr(11, 17, '[ ] Ask before replacing or deleting', AttrCnf);

    WriteStr(24, 19, '[  Save  ]', AttrSave);
    WriteStr(44, 19, '[ Cancel ]', AttrCancel);

    if CurField = 0 then
    begin
      ShowCursor;
      SetCursor(11 + Length(TPath), 7);
    end
    else if CurField = 1 then
    begin
      ShowCursor;
      SetCursor(11 + Length(EPath), 10);
    end
    else if CurField = 2 then
    begin
      ShowCursor;
      SetCursor(11 + Length(UPath), 13);
    end
    else
      HideCursor;

    if DialogEvent(Ch, Scan, Zone) then
    begin
      CurField := Zone;
      case Zone of
        3: WeightSize := not WeightSize;
        4: IsoFmt := not IsoFmt;
        5: ConfirmOps := not ConfirmOps;
        6: begin
             if TPath <> '' then CfgViewImg := TPath;
             if EPath <> '' then CfgEditor := EPath;
             if UPath <> '' then CfgUnzip  := UPath;
             CfgWeightBySize := WeightSize;
             CfgIsoDateTime := IsoFmt;
             CfgConfirmOps := ConfirmOps;
             SaveConfig;
             Break;
           end;
        7: Break;
      end;
      Continue;
    end;

    if Ch = #0 then
    begin
      case Scan of
        KEY_UP:
          begin
            if CurField = 0 then CurField := 6
            else if CurField in [1..5] then Dec(CurField)
            else CurField := 5;
          end;
        KEY_DOWN:
          begin
            if CurField < 6 then Inc(CurField)
            else CurField := 0;
          end;
        KEY_LEFT, KEY_RIGHT:
          begin
            if CurField = 6 then CurField := 7
            else if CurField = 7 then CurField := 6;
          end;
      end;
    end
    else
    begin
      case Ch of
        #9: CurField := (CurField + 1) mod 8;
        #13:
          begin
            if CurField in [0..2] then Inc(CurField)
            else if CurField = 3 then WeightSize := not WeightSize
            else if CurField = 4 then IsoFmt := not IsoFmt
            else if CurField = 5 then ConfirmOps := not ConfirmOps
            else if CurField = 6 then
            begin
              if TPath <> '' then CfgViewImg := TPath;
              if EPath <> '' then CfgEditor := EPath;
              if UPath <> '' then CfgUnzip  := UPath;
              CfgWeightBySize := WeightSize;
              CfgIsoDateTime := IsoFmt;
              CfgConfirmOps := ConfirmOps;
              SaveConfig;
              Break;
            end
            else if CurField = 7 then Break;
          end;
        #27: Break;
        #8:
          begin
            if (CurField = 0) and (Length(TPath) > 0) then Dec(TPath[0])
            else if (CurField = 1) and (Length(EPath) > 0) then Dec(EPath[0])
            else if (CurField = 2) and (Length(UPath) > 0) then Dec(UPath[0]);
          end;
        #32..#126:
          begin
            if (Ch = ' ') and (CurField = 3) then WeightSize := not WeightSize
            else if (Ch = ' ') and (CurField = 4) then IsoFmt := not IsoFmt
            else if (Ch = ' ') and (CurField = 5) then
              ConfirmOps := not ConfirmOps
            else if (CurField = 0) and (Length(TPath) < 56) then TPath := TPath + Ch
            else if (CurField = 1) and (Length(EPath) < 56) then EPath := EPath + Ch
            else if (CurField = 2) and (Length(UPath) < 56) then UPath := UPath + Ch;
          end;
      end;
    end;
  end;
  HideCursor;
end;

procedure DialogHelp;
var
  Ch: Char;
  Scan: Byte;
  Zone: Integer;
begin
  DrawDialogFrame(14, 2, 66, 23, 'Help / Key Reference');
  WriteStr(17,  3, 'Ins           Select / Tag Item', ATTR_DIALOG_BG);
  WriteStr(17,  4, 'F             Filter / Match Select', ATTR_DIALOG_BG);
  WriteStr(17,  5, 'W             Toggle Wide / Dual Mode', ATTR_DIALOG_BG);
  WriteStr(17,  6, 'Alt+A..Z      Quick Search / Jump', ATTR_DIALOG_BG);
  WriteStr(17,  7, 'N / S / D / T Sort: Name/Size/Date/Time', ATTR_DIALOG_BG);
  WriteStr(17,  8, 'Alt+F1/F2     Change Left/Right Drive', ATTR_DIALOG_BG);
  WriteStr(17,  9, 'TAB           Switch Active Panel', ATTR_DIALOG_BG);
  WriteStr(17, 10, 'ENTER         Enter Subdir / Mount ZIP', ATTR_DIALOG_BG);
  WriteStr(17, 11, 'F1            Help Menu', ATTR_DIALOG_BG);
  WriteStr(17, 12, 'F2            Setup Paths (FC.CFG)', ATTR_DIALOG_BG);
  WriteStr(17, 13, 'F3            View Image (BMP/JPG/GIF)', ATTR_DIALOG_BG);
  WriteStr(17, 14, 'F4            View/Edit File (or from ZIP)', ATTR_DIALOG_BG);
  WriteStr(17, 15, 'F5            Copy File / Dir Tree / ZIP', ATTR_DIALOG_BG);
  WriteStr(17, 16, 'F6            Rename / Move [Popup]', ATTR_DIALOG_BG);
  WriteStr(17, 17, 'F7            Make Directory', ATTR_DIALOG_BG);
  WriteStr(17, 18, 'F8            Delete File(s) / Dir(s)', ATTR_DIALOG_BG);
  WriteStr(17, 19, 'F9            Create New File', ATTR_DIALOG_BG);
  WriteStr(17, 20, 'F10 / ESC     Quit Commander', ATTR_DIALOG_BG);
  WriteStr(17, 21, 'Mouse  Click, x2 Open, Right Tag,', ATTR_DIALOG_BG);
  WriteStr(17, 22, '       Header Sorts Column', ATTR_DIALOG_BG);
  ZonesClear;
  ZoneAdd(14, 2, 66, 23, 0);     { click anywhere in the window to close }
  DialogEvent(Ch, Scan, Zone);
end;

procedure SelectDrive(var Panel: TPanel);
var
  Drives: array[1..26] of Char;
  DriveCount, I, SelIndex: Integer;
  X1, Y1, X2, Y2, BoxWidth, BoxHeight: Integer;
  Ch, ChUpper: Char;
  Scan: Byte;
  Zone: Integer;
  NewPath: string;
  Chosen: Boolean;
begin
  DriveCount := 0;
  for Ch := 'A' to 'Z' do
  begin
    if DriveExists(Ch) then
    begin
      Inc(DriveCount);
      Drives[DriveCount] := Ch;
    end;
  end;

  if DriveCount = 0 then Exit;

  SelIndex := 1;
  for I := 1 to DriveCount do
    if UpCase(Panel.Path[1]) = Drives[I] then SelIndex := I;

  BoxWidth := 14;
  BoxHeight := DriveCount + 2;
  X1 := Panel.StartX + 5;
  Y1 := 3;
  X2 := X1 + BoxWidth;
  Y2 := Y1 + BoxHeight;
  Chosen := False;

  while True do
  begin
    DrawDialogFrame(X1, Y1, X2, Y2, 'Drive');
    ZonesClear;
    for I := 1 to DriveCount do
    begin
      if I = SelIndex then WriteStr(X1 + 4, Y1 + I, '[-' + Drives[I] + '-]', ATTR_SELECTED)
      else WriteStr(X1 + 4, Y1 + I, '[-' + Drives[I] + '-]', ATTR_DIALOG_BG);
      ZoneAdd(X1 + 4, Y1 + I, X1 + 8, Y1 + I, I);
    end;

    if DialogEvent(Ch, Scan, Zone) then
    begin
      SelIndex := Zone;
      Chosen := True;
      Break;
    end;

    if Ch = #0 then
    begin
      case Scan of
        KEY_UP: if SelIndex > 1 then Dec(SelIndex) else SelIndex := DriveCount;
        KEY_DOWN: if SelIndex < DriveCount then Inc(SelIndex) else SelIndex := 1;
      end;
    end
    else
    begin
      if Ch = #13 then begin Chosen := True; Break; end
      else if Ch = #27 then begin Chosen := False; Break; end
      else
      begin
        ChUpper := UpCase(Ch);
        for I := 1 to DriveCount do
        begin
          if Drives[I] = ChUpper then begin SelIndex := I; Chosen := True; Break; end;
        end;
        if Chosen then Break;
      end;
    end;
  end;

  if Chosen then
  begin
    Panel.InsideZip := False;
    Panel.ZipPath := '';
    Panel.SubPath := '';
    GetDir(Ord(Drives[SelIndex]) - Ord('A') + 1, NewPath);
    if (IOResult <> 0) or (Length(NewPath) < 2) then
      NewPath := Drives[SelIndex] + ':\'
    else if NewPath[Length(NewPath)] <> '\' then
      NewPath := NewPath + '\';

    Panel.Path := NewPath;
    ReadDirectory(Panel);
  end;
end;

{===========================================================================}
{   PANEL RENDERING ENGINE: DUAL MODE (NORMAL)                              }
{===========================================================================}

procedure DrawNormalPanelBorder(var Panel: TPanel; IsActive: Boolean);
var
  X, Y: Integer;
  BorderAttr, SepAttr: Byte;
  DriveId: string[3];
  NameHdr, SizeHdr, DateHdr, TimeHdr: string[12];
  ArrowCh: Char;
begin
  if IsActive then
  begin
    BorderAttr := ATTR_BORDER;
    SepAttr    := ATTR_BORDER;
  end
  else
  begin
    BorderAttr := ATTR_BORDER_INA;
    SepAttr    := ATTR_BORDER_INA;
  end;

  for X := Panel.StartX + 1 to Panel.StartX + 38 do
  begin
    WriteCell(X, 0, #205, BorderAttr);
    WriteCell(X, 23, #205, BorderAttr);
    WriteCell(X, 2, #196, SepAttr);
    WriteCell(X, 21, #196, SepAttr);
  end;

  for Y := 1 to 22 do
  begin
    WriteCell(Panel.StartX, Y, #186, BorderAttr);
    WriteCell(Panel.StartX + 39, Y, #186, BorderAttr);
  end;

  WriteCell(Panel.StartX, 0, #201, BorderAttr);
  WriteCell(Panel.StartX + 39, 0, #187, BorderAttr);
  WriteCell(Panel.StartX, 23, #200, BorderAttr);
  WriteCell(Panel.StartX + 39, 23, #188, BorderAttr);

  WriteCell(Panel.StartX, 2, #199, BorderAttr);
  WriteCell(Panel.StartX + 39, 2, #182, BorderAttr);
  WriteCell(Panel.StartX, 21, #199, BorderAttr);
  WriteCell(Panel.StartX + 39, 21, #182, BorderAttr);

  WriteCell(Panel.StartX + 13, 2, #197, SepAttr);
  WriteCell(Panel.StartX + 23, 2, #197, SepAttr);
  WriteCell(Panel.StartX + 32, 2, #197, SepAttr);

  WriteCell(Panel.StartX + 13, 21, #193, SepAttr);
  WriteCell(Panel.StartX + 23, 21, #193, SepAttr);
  WriteCell(Panel.StartX + 32, 21, #193, SepAttr);

  for Y := 3 to 20 do
  begin
    WriteCell(Panel.StartX + 13, Y, #179, SepAttr);
    WriteCell(Panel.StartX + 23, Y, #179, SepAttr);
    WriteCell(Panel.StartX + 32, Y, #179, SepAttr);
  end;

  WriteStr(Panel.StartX + 2, 0, ' ' + Panel.Path + ' ', ATTR_HEADER);

  if Panel.SortDir = sdAsc then ArrowCh := #25 else ArrowCh := #24;
  DriveId := UpCase(Panel.Path[1]) + ':';

  if Panel.SortCol = scName then NameHdr := DriveId + ArrowCh + ' Name     '
  else NameHdr := DriveId + '  Name     ';

  if Panel.SortCol = scSize then SizeHdr := '  ' + ArrowCh + ' Size  '
  else SizeHdr := '   Size   ';

  if Panel.SortCol = scDate then DateHdr := ' ' + ArrowCh + ' Date  '
  else DateHdr := '  Date   ';

  if Panel.SortCol = scTime then TimeHdr := ArrowCh + ' Time'
  else TimeHdr := ' Time ';

  FillBox(Panel.StartX + 1, 1, Panel.StartX + 38, 1, ' ', BorderAttr);

  WriteCell(Panel.StartX + 13, 1, #179, SepAttr);
  WriteCell(Panel.StartX + 23, 1, #179, SepAttr);
  WriteCell(Panel.StartX + 32, 1, #179, SepAttr);

  WriteStr(Panel.StartX + 1, 1, NameHdr, BorderAttr);
  WriteStr(Panel.StartX + 14, 1, SizeHdr, BorderAttr);
  WriteStr(Panel.StartX + 24, 1, DateHdr, BorderAttr);
  WriteStr(Panel.StartX + 33, 1, TimeHdr, BorderAttr);
end;

{ Keeps the selected entry inside the visible window }
procedure ClampNormalView(var Panel: TPanel);
begin
  if Panel.Selected < Panel.TopIndex then
    Panel.TopIndex := Panel.Selected;
  if Panel.Selected >= Panel.TopIndex + PANEL_ROWS then
    Panel.TopIndex := Panel.Selected - PANEL_ROWS + 1;
  if Panel.TopIndex < 1 then Panel.TopIndex := 1;
end;

{ Paints one file row as four padded runs - 38 cells, no fill-then-overwrite. }
{ Columns 13, 23 and 32 are left alone so the border separators survive.      }
procedure RenderNormalRow(var Panel: TPanel; Idx: Integer; IsActive: Boolean);
var
  ScrY, X: Integer;
  RowAttr: Byte;
  NameStr, SizeStr, DateStr, TimeStr: string;
begin
  ScrY := 3 + (Idx - Panel.TopIndex);
  if (ScrY < 3) or (ScrY > 20) then Exit;
  X := Panel.StartX + 1;

  if (Idx = Panel.Selected) and IsActive then
  begin
    if (Idx <= Panel.Count) and Panel.Files[Idx].Tagged then
      RowAttr := ATTR_TAGGED_SEL
    else
      RowAttr := ATTR_SELECTED;
  end
  else
  begin
    if (Idx <= Panel.Count) and Panel.Files[Idx].Tagged then
      RowAttr := ATTR_TAGGED
    else
      RowAttr := ATTR_NORMAL;
  end;

  if (Idx >= 1) and (Idx <= Panel.Count) then
  begin
    NameStr := FormatNCName(Panel.Files[Idx].Name, Panel.Files[Idx].IsDir);

    if Panel.Files[Idx].IsDir then
    begin
      if Panel.Files[Idx].Name = '..' then SizeStr := #16 + 'UP--DIR' + #17
      else SizeStr := #16 + 'SUB-DIR' + #17;
    end
    else
      SizeStr := PadL(IntToStr(Panel.Files[Idx].Size), 9);

    DateStr := FormatDate(Panel.Files[Idx].Time);
    TimeStr := FormatTime(Panel.Files[Idx].Time);
  end
  else
  begin
    NameStr := '';
    SizeStr := '';
    DateStr := '';
    TimeStr := '';
  end;

  WriteStr(X,      ScrY, PadR(NameStr, 12), RowAttr);
  WriteStr(X + 13, ScrY, PadR(SizeStr, 9),  RowAttr);
  WriteStr(X + 23, ScrY, PadR(DateStr, 8),  RowAttr);
  WriteStr(X + 32, ScrY, PadR(TimeStr, 6),  RowAttr);
end;

procedure RenderNormalRows(var Panel: TPanel; IsActive: Boolean);
var
  I: Integer;
begin
  for I := 0 to PANEL_ROWS - 1 do
    RenderNormalRow(Panel, Panel.TopIndex + I, IsActive);
end;

procedure RenderNormalStatus(var Panel: TPanel; IsActive: Boolean);
var
  Info: string;
begin
  if IsActive and (QuickSearchStr <> '') then
    Info := 'Search: ' + QuickSearchStr
  else if HasTagged(Panel) then
    Info := IntToStr(TaggedCount(Panel)) + ' selected  ' +
            IntToStr(TaggedBytes(Panel)) + ' Bytes'
  else if (Panel.Selected >= 1) and (Panel.Selected <= Panel.Count) then
  begin
    Info := Panel.Files[Panel.Selected].Name;
    if Panel.Files[Panel.Selected].IsDir then
      Info := Info + '  <DIR>'
    else
      Info := Info + '  ' + IntToStr(Panel.Files[Panel.Selected].Size) + ' Bytes';
  end
  else
    Info := '';

  if IsActive and (QuickSearchStr <> '') then
    WriteStr(Panel.StartX + 2, 22, PadR(Info, 36), ATTR_HEADER)
  else if HasTagged(Panel) then
    WriteStr(Panel.StartX + 2, 22, PadR(Info, 36), ATTR_TAGGED)
  else
    WriteStr(Panel.StartX + 2, 22, PadR(Info, 36), ATTR_NORMAL);

  WriteCell(Panel.StartX + 1, 22, ' ', ATTR_NORMAL);
  WriteCell(Panel.StartX + 38, 22, ' ', ATTR_NORMAL);
end;

{ Full repaint of one panel }
procedure RenderNormalPanel(var Panel: TPanel; IsActive: Boolean);
begin
  ClampNormalView(Panel);
  DrawNormalPanelBorder(Panel, IsActive);
  RenderNormalRows(Panel, IsActive);
  RenderNormalStatus(Panel, IsActive);
  Panel.DrawnSel := Panel.Selected;
  Panel.DrawnTop := Panel.TopIndex;
  Panel.Dirty := False;
end;

{ Cheap repaint: only the rows that actually changed }
procedure UpdateNormalPanel(var Panel: TPanel; IsActive: Boolean);
begin
  ClampNormalView(Panel);

  if (Panel.DrawnTop = Panel.TopIndex) and
     (Panel.DrawnSel = Panel.Selected) and not Panel.Dirty then Exit;

  if Panel.DrawnTop <> Panel.TopIndex then
    RenderNormalRows(Panel, IsActive)   { the window scrolled }
  else
  begin
    RenderNormalRow(Panel, Panel.DrawnSel, IsActive);
    if Panel.Selected <> Panel.DrawnSel then
      RenderNormalRow(Panel, Panel.Selected, IsActive);
  end;

  RenderNormalStatus(Panel, IsActive);
  Panel.DrawnSel := Panel.Selected;
  Panel.DrawnTop := Panel.TopIndex;
  Panel.Dirty := False;
end;

{===========================================================================}
{   PANEL RENDERING ENGINE: WIDE MODE (5 FILENAME COLUMNS)                  }
{===========================================================================}

{ Keeps the selection inside the visible five-column page }
procedure ClampWideView(var Panel: TPanel);
begin
  Panel.StartX := 0;
  if Panel.Selected < Panel.TopIndex then
  begin
    while (Panel.Selected < Panel.TopIndex) and (Panel.TopIndex > 1) do
      Dec(Panel.TopIndex, PANEL_ROWS);
    if Panel.TopIndex < 1 then Panel.TopIndex := 1;
  end;
  if Panel.Selected >= Panel.TopIndex + (WIDE_COLS * PANEL_ROWS) then
  begin
    while Panel.Selected >= Panel.TopIndex + (WIDE_COLS * PANEL_ROWS) do
      Inc(Panel.TopIndex, PANEL_ROWS);
  end;
end;

{ Paints a single name cell of the wide grid }
procedure RenderWideCell(var Panel: TPanel; Idx: Integer);
var
  Rel, C, R: Integer;
  RowAttr: Byte;
  DispName: string;
begin
  Rel := Idx - Panel.TopIndex;
  if (Rel < 0) or (Rel >= WIDE_COLS * PANEL_ROWS) then Exit;
  C := Rel div PANEL_ROWS;
  R := Rel mod PANEL_ROWS;

  if Idx = Panel.Selected then
  begin
    if (Idx <= Panel.Count) and Panel.Files[Idx].Tagged then
      RowAttr := ATTR_TAGGED_SEL
    else
      RowAttr := ATTR_SELECTED;
  end
  else
  begin
    if (Idx <= Panel.Count) and Panel.Files[Idx].Tagged then
      RowAttr := ATTR_TAGGED
    else
      RowAttr := ATTR_NORMAL;
  end;

  if (Idx >= 1) and (Idx <= Panel.Count) then
  begin
    if Panel.Files[Idx].IsDir then
    begin
      if Panel.Files[Idx].Name = '..' then DispName := '[..]'
      else DispName := '[' + Panel.Files[Idx].Name + ']';
    end
    else
      DispName := Panel.Files[Idx].Name;

    if Length(DispName) > WideColW[C] then
      DispName := Copy(DispName, 1, WideColW[C]);
  end
  else
    DispName := '';

  WriteStr(WideColX[C], 3 + R, PadR(DispName, WideColW[C]), RowAttr);
end;

procedure RenderWideCells(var Panel: TPanel);
var
  I: Integer;
begin
  for I := 0 to (WIDE_COLS * PANEL_ROWS) - 1 do
    RenderWideCell(Panel, Panel.TopIndex + I);
end;

procedure RenderWideStatus(var Panel: TPanel);
var
  Info: string;
  Attr: Byte;
begin
  Attr := ATTR_NORMAL;
  if QuickSearchStr <> '' then
  begin
    Info := 'Search: ' + QuickSearchStr;
    Attr := ATTR_HEADER;
  end
  else if HasTagged(Panel) then
  begin
    Info := IntToStr(TaggedCount(Panel)) + ' selected  ' +
            IntToStr(TaggedBytes(Panel)) + ' Bytes';
    Attr := ATTR_TAGGED;
  end
  else if (Panel.Selected >= 1) and (Panel.Selected <= Panel.Count) then
  begin
    if Panel.Files[Panel.Selected].IsDir then
    begin
      if Panel.Files[Panel.Selected].Name = '..' then
        Info := '[..]             <UP-DIR>       '
      else
        Info := PadR('[' + Panel.Files[Panel.Selected].Name + ']', 17) +
                '<SUB-DIR>      ';

      Info := Info + FormatDate(Panel.Files[Panel.Selected].Time) + '   ' +
              FormatTime(Panel.Files[Panel.Selected].Time);
    end
    else
    begin
      Info := PadR(Panel.Files[Panel.Selected].Name, 17) +
              PadL(IntToStr(Panel.Files[Panel.Selected].Size), 10) + ' Bytes   ' +
              FormatDate(Panel.Files[Panel.Selected].Time) + '   ' +
              FormatTime(Panel.Files[Panel.Selected].Time);
    end;
  end
  else
    Info := '';

  WriteStr(2, 22, PadR(Info, 76), Attr);
  WriteCell(1, 22, ' ', ATTR_NORMAL);
  WriteCell(78, 22, ' ', ATTR_NORMAL);
end;

{ Border, header row and sort indicator - only needed on a full repaint }
procedure DrawWideFrame(var Panel: TPanel);
var
  X, Y, C: Integer;
  ArrowCh: Char;
  SortLabel: string[20];
begin
  for X := 1 to 78 do
  begin
    WriteCell(X, 0, #205, ATTR_BORDER);
    WriteCell(X, 23, #205, ATTR_BORDER);
    WriteCell(X, 2, #196, ATTR_BORDER);
    WriteCell(X, 21, #196, ATTR_BORDER);
  end;

  for Y := 1 to 22 do
  begin
    WriteCell(0, Y, #186, ATTR_BORDER);
    WriteCell(79, Y, #186, ATTR_BORDER);
  end;

  WriteCell(0, 0, #201, ATTR_BORDER);
  WriteCell(79, 0, #187, ATTR_BORDER);
  WriteCell(0, 23, #200, ATTR_BORDER);
  WriteCell(79, 23, #188, ATTR_BORDER);

  WriteCell(0, 2, #199, ATTR_BORDER);
  WriteCell(79, 2, #182, ATTR_BORDER);
  WriteCell(0, 21, #199, ATTR_BORDER);
  WriteCell(79, 21, #182, ATTR_BORDER);

  for C := 0 to 3 do
  begin
    WriteCell(WideSepX[C], 1, #179, ATTR_BORDER);
    WriteCell(WideSepX[C], 2, #197, ATTR_BORDER);
    WriteCell(WideSepX[C], 21, #193, ATTR_BORDER);
    for Y := 3 to 20 do
      WriteCell(WideSepX[C], Y, #179, ATTR_BORDER);
  end;

  WriteStr(2, 0, ' ' + Panel.Path + ' ', ATTR_HEADER);

  if Panel.SortDir = sdAsc then ArrowCh := #25 else ArrowCh := #24;
  case Panel.SortCol of
    scName: SortLabel := 'Name';
    scSize: SortLabel := 'Size';
    scDate: SortLabel := 'Date';
    scTime: SortLabel := 'Time';
  end;
  WriteStr(56, 0, ' [Sort: ' + SortLabel + ' ' + ArrowCh + '] ', ATTR_HEADER);

  FillBox(1, 1, 78, 1, ' ', ATTR_BORDER);
  for C := 0 to 3 do WriteCell(WideSepX[C], 1, #179, ATTR_BORDER);
  WriteStr(1, 1, PadR(' ' + UpCase(Panel.Path[1]) + ': Name', 15), ATTR_BORDER);
  WriteStr(17, 1, PadR(' Name', 15), ATTR_BORDER);
  WriteStr(33, 1, PadR(' Name', 15), ATTR_BORDER);
  WriteStr(49, 1, PadR(' Name', 15), ATTR_BORDER);
  WriteStr(65, 1, PadR(' Name', 14), ATTR_BORDER);
end;

procedure RenderWidePanel(var Panel: TPanel);
begin
  ClampWideView(Panel);
  DrawWideFrame(Panel);
  RenderWideCells(Panel);
  RenderWideStatus(Panel);
  Panel.DrawnSel := Panel.Selected;
  Panel.DrawnTop := Panel.TopIndex;
  Panel.Dirty := False;
end;

procedure UpdateWidePanel(var Panel: TPanel);
begin
  ClampWideView(Panel);

  if (Panel.DrawnTop = Panel.TopIndex) and
     (Panel.DrawnSel = Panel.Selected) and not Panel.Dirty then Exit;

  if Panel.DrawnTop <> Panel.TopIndex then
    RenderWideCells(Panel)
  else
  begin
    RenderWideCell(Panel, Panel.DrawnSel);
    if Panel.Selected <> Panel.DrawnSel then
      RenderWideCell(Panel, Panel.Selected);
  end;

  RenderWideStatus(Panel);
  Panel.DrawnSel := Panel.Selected;
  Panel.DrawnTop := Panel.TopIndex;
  Panel.Dirty := False;
end;

procedure DrawBottomBar;
var
  I, X, EndX: Integer;
begin
  X := 0;
  for I := 1 to 10 do
  begin
    EndX := X + BarButtons[I].Width;
    WriteStr(X, 24, BarButtons[I].Num, ATTR_KEY_NUM);
    X := X + Length(BarButtons[I].Num);

    WriteStr(X, 24, BarButtons[I].Lbl, ATTR_KEY_LBL);
    X := X + Length(BarButtons[I].Lbl);

    while X < EndX do
    begin
      WriteCell(X, 24, ' ', ATTR_KEY_LBL);
      Inc(X);
    end;
  end;
end;

procedure RedrawScreen;
begin
  if WideMode then
    RenderWidePanel(ActivePanel^)
  else
  begin
    RenderNormalPanel(LeftPanel, ActivePanel = @LeftPanel);
    RenderNormalPanel(RightPanel, ActivePanel = @RightPanel);
  end;
  DrawBottomBar;
  HideCursor;
  NeedFull := False;
  MouseShow;
end;

{ Called once per keystroke: repaints everything only when something needs it, }
{ otherwise just the rows whose contents or highlight changed.                 }
procedure UpdateScreen;
begin
  if NeedFull then
  begin
    RedrawScreen;
    Exit;
  end;

  MouseHide;
  if WideMode then
    UpdateWidePanel(ActivePanel^)
  else
  begin
    UpdateNormalPanel(LeftPanel, ActivePanel = @LeftPanel);
    UpdateNormalPanel(RightPanel, ActivePanel = @RightPanel);
  end;
  MouseShow;
end;

{===========================================================================}
{   RECURSIVE DELETION ENGINE                                               }
{===========================================================================}

{ Deletes one file and advances the progress bar by its weight }
procedure EraseFile(const FileName, ItemName: string; Size: LongInt);
var
  F: file;
begin
  ProgressNames(ItemName, '');
  Assign(F, FileName);
  SetFAttr(F, Archive);
  if DosError = 0 then ;
  Erase(F);
  if IOResult <> 0 then NoteFailure(ItemName);
  ProgressAdd(ProgressWeight(Size));
end;

{ Sums progress weight for a directory tree (used before deleting it) }
function CountTree(DirPath: TPathStr): LongInt;
var
  SR: SearchRec;
  Sum: LongInt;
begin
  if DirPath[Length(DirPath)] <> '\' then
    DirPath := DirPath + '\';

  Sum := ProgressWeight(0);  { the directory itself: 1 item, 0 bytes }
  FindFirst(DirPath + '*.*', ATTR_ALL_FILES, SR);
  while DosError = 0 do
  begin
    if (SR.Name <> '.') and (SR.Name <> '..') then
    begin
      if (SR.Attr and Directory) <> 0 then
        Inc(Sum, CountTree(DirPath + SR.Name + '\'))
      else
        Inc(Sum, ProgressWeight(SR.Size));
    end;
    FindNext(SR);
  end;
  CountTree := Sum;
end;

procedure EraseDirectoryTree(DirPath: TPathStr);
var
  SR: SearchRec;
  F: file;
  CurDosDir: string;
begin
  if DirPath[Length(DirPath)] <> '\' then
    DirPath := DirPath + '\';

  GetDir(0, CurDosDir);
  if CurDosDir[Length(CurDosDir)] <> '\' then
    CurDosDir := CurDosDir + '\';
  if Pos(DirPath, CurDosDir) = 1 then
    ChDir('\');

  FindFirst(DirPath + '*.*', ATTR_ALL_FILES, SR);
  while DosError = 0 do
  begin
    if (SR.Name <> '.') and (SR.Name <> '..') then
    begin
      if (SR.Attr and Directory) <> 0 then
        EraseDirectoryTree(DirPath + SR.Name + '\')
      else
        EraseFile(DirPath + SR.Name, SR.Name, SR.Size);
    end;
    FindNext(SR);
  end;

  if Length(DirPath) > 3 then
  begin
    if DirPath[Length(DirPath)] = '\' then
      Dec(DirPath[0]);
    Assign(F, DirPath);
    SetFAttr(F, Archive);
    if DosError = 0 then ;
    RmDir(DirPath);
    if IOResult <> 0 then NoteFailure(LastComponent(DirPath));
    ProgressAdd(ProgressWeight(0));
  end;
end;

{===========================================================================}
{   FILE ACTIONS (COPY / UNZIP EXTRACT, MOVE, MKDIR, DELETE, NEW FILE)     }
{===========================================================================}

{ Decides whether an existing destination may be overwritten }
function AllowReplace(const Dest, ItemName: string): Boolean;
begin
  AllowReplace := True;
  if not CfgConfirmOps then Exit;
  if OpReplaceAll or OpCancelled then
  begin
    AllowReplace := not OpCancelled;
    Exit;
  end;
  if not PathExists(Dest) then Exit;

  case DialogReplace(ItemName) of
    RP_ALL: OpReplaceAll := True;
    RP_NO:  AllowReplace := False;
    RP_CANCEL:
      begin
        AllowReplace := False;
        OpCancelled := True;
      end;
  end;

  ProgressRepaint;   { the prompt covered the progress dialog }
end;

{ Copies one file; shows Src name and full Dest path in the progress dialog }
function CopySingleFile(const Src, Dest, ItemName: string): Boolean;
var
  FIn, FOut: file;
  NumRead, NumWritten: Word;
  Buf: pointer;
  Ok: Boolean;
begin
  Ok := False;
  OpLastSkipped := False;
  ProgressNames(ItemName, Dest);

  if not AllowReplace(Dest, ItemName) then
  begin
    OpLastSkipped := True;
    { Advance the bar anyway so the total stays honest }
    if CfgWeightBySize then ProgressAdd(EntrySize(Src)) else ProgressAdd(1);
    CopySingleFile := False;
    Exit;
  end;

  Assign(FIn, Src);
  Reset(FIn, 1);
  if IOResult = 0 then
  begin
    Assign(FOut, Dest);
    Rewrite(FOut, 1);
    if IOResult = 0 then
    begin
      Buf := nil;
      GetMem(Buf, 4096);
      if Buf <> nil then
      begin
        repeat
          BlockRead(FIn, Buf^, 4096, NumRead);
          BlockWrite(FOut, Buf^, NumRead, NumWritten);
          if CfgWeightBySize then ProgressAdd(NumRead);
        until (NumRead = 0) or (NumWritten <> NumRead);
        FreeMem(Buf, 4096);
        Ok := True;
      end;
      Close(FOut);
    end;
    Close(FIn);
  end;

  if not CfgWeightBySize then ProgressAdd(1);
  if not Ok then NoteFailure(ItemName);
  CopySingleFile := Ok;
end;

{ True when Dest is Src or sits inside it - copying there would never end }
function IsSubPath(Src, Dest: TPathStr): Boolean;
begin
  Src := UpCaseStr(Src);
  Dest := UpCaseStr(Dest);
  if Src[Length(Src)] <> '\' then Src := Src + '\';
  if Dest[Length(Dest)] <> '\' then Dest := Dest + '\';
  IsSubPath := Pos(Src, Dest) = 1;
end;

{ Recursively copies SrcDir and everything beneath it to DestDir.          }
{ DestDir is the full target path, i.e. the new directory itself.          }
procedure CopyDirectoryTree(SrcDir, DestDir: TPathStr);
var
  SR: SearchRec;
begin
  if SrcDir[Length(SrcDir)] = '\' then Dec(SrcDir[0]);
  if DestDir[Length(DestDir)] = '\' then Dec(DestDir[0]);

  ProgressNames(SrcDir, DestDir);

  if OpCancelled then Exit;

  if not IsDirExists(DestDir) then
  begin
    MkDir(DestDir);
    if IOResult <> 0 then
    begin
      NoteFailure(LastComponent(DestDir));
      Exit;                      { target unreachable - skip this branch }
    end;
  end;
  ProgressAdd(ProgressWeight(0));

  { SearchRec is local, so each recursion level keeps its own DOS state }
  FindFirst(SrcDir + '\*.*', ATTR_ALL_FILES, SR);
  while DosError = 0 do
  begin
    if (SR.Name <> '.') and (SR.Name <> '..') then
    begin
      if (SR.Attr and Directory) <> 0 then
        CopyDirectoryTree(SrcDir + '\' + SR.Name, DestDir + '\' + SR.Name)
      else
        CopySingleFile(SrcDir + '\' + SR.Name, DestDir + '\' + SR.Name, SR.Name);
    end;
    if OpCancelled then Break;
    FindNext(SR);
  end;
end;

{ Result codes for a move attempt }
const
  MV_OK       = 0;
  MV_FAILED   = 1;
  MV_RECURSED = 2;   { Target sits inside the source }

{ Moves a file or a whole directory tree.                                   }
{ DOS can only rename within one drive, so a failed rename falls back to    }
{ copy-then-delete. That is the only way to move across drives.             }
function MoveEntry(const Src, Dest: string; IsDir: Boolean): Integer;
var
  F: file;
  Total, Bytes: LongInt;
begin
  if IsDir and IsSubPath(Src, Dest) then
  begin
    MoveEntry := MV_RECURSED;
    Exit;
  end;

  { Fast path: same drive, DOS just relinks the directory entry }
  Assign(F, Src);
  Rename(F, Dest);
  if IOResult = 0 then
  begin
    MoveEntry := MV_OK;
    Exit;
  end;

  { Slow path: copy across, then remove the original }
  if IsDir then
  begin
    ProgressOpen('Move', 'Scanning directories...', 1);
    Total := CountTree(Src) * 2;   { copied once, then deleted }
    ProgressOpen('Move', 'Moving the file or directory', Total);
    CopyDirectoryTree(Src, Dest);
    EraseDirectoryTree(Src);
    ProgressClose;
    MoveEntry := MV_OK;
  end
  else
  begin
    Bytes := EntrySize(Src);
    Total := ProgressWeight(Bytes) * 2;
    ProgressOpen('Move', 'Moving the file or directory', Total);
    if CopySingleFile(Src, Dest, Src) then
    begin
      EraseFile(Src, Src, Bytes);
      ProgressClose;
      MoveEntry := MV_OK;
    end
    else
    begin
      ProgressClose;
      { Declined at the replace prompt: leave the original alone }
      if OpLastSkipped then MoveEntry := MV_OK
      else MoveEntry := MV_FAILED;
    end;
  end;
end;

procedure ActionCopy;
var
  SrcName, DestInput, TargetFile, DefDest: string;
  I: Integer;
  Total: LongInt;
  Skipped: Boolean;
begin
  ResetOperation;
  with ActivePanel^ do
  begin
    if Count = 0 then Exit;

    if ActivePanel = @LeftPanel then DefDest := RightPanel.Path
    else DefDest := LeftPanel.Path;

    { Copy / Extract from Inside ZIP via UNZIP.EXE }
    if InsideZip then
    begin
      DestInput := DefDest;
      if HasTagged(ActivePanel^) then
      begin
        if not DialogPrompt('Extract from ZIP',
             'Extract ' + IntToStr(TaggedCount(ActivePanel^)) + ' file(s) to:',
             DestInput) then Exit;
        if DestInput = '' then Exit;
        if (DestInput[Length(DestInput)] <> '\') and
           (IsDirExists(DestInput) or (Pos('.', DestInput) = 0)) then
          DestInput := DestInput + '\';

        for I := 1 to Count do
        begin
          if Files[I].Tagged and not Files[I].IsDir then
          begin
            LaunchProgram(LocateBinary(CfgUnzip),
              UnzipCmd(ZipPath, Files[I].ZipFullName, DestInput), False);
            Files[I].Tagged := False;
          end;
        end;
      end
      else
      begin
        if Files[Selected].IsDir then Exit;
        if not DialogPrompt('Extract from ZIP',
             'Extract ' + Files[Selected].Name + ' to:', DestInput) then Exit;
        if DestInput = '' then Exit;
        if (DestInput[Length(DestInput)] <> '\') and
           (IsDirExists(DestInput) or (Pos('.', DestInput) = 0)) then
          DestInput := DestInput + '\';

        LaunchProgram(LocateBinary(CfgUnzip),
          UnzipCmd(ZipPath, Files[Selected].ZipFullName, DestInput), False);
      end;

      if ActivePanel = @LeftPanel then RefreshDirectory(RightPanel)
      else RefreshDirectory(LeftPanel);
      Exit;
    end;

    { Regular disk file copy }
    if HasTagged(ActivePanel^) then
    begin
      DestInput := DefDest;
      if not DialogPrompt('Copy Multiple',
           'Copy ' + IntToStr(TaggedCount(ActivePanel^)) + ' items to:',
           DestInput) then Exit;
      if DestInput = '' then Exit;

      if (DestInput[Length(DestInput)] <> '\') and
         (IsDirExists(DestInput) or (Pos('.', DestInput) = 0)) then
        DestInput := DestInput + '\';

      { Pre-scan: tagged directories are walked so the bar has a real total }
      ProgressOpen('Copy', 'Scanning directories...', 1);
      Total := 0;
      for I := 1 to Count do
      begin
        if Files[I].Tagged and (Files[I].Name <> '..') then
        begin
          if Files[I].IsDir then Inc(Total, CountTree(Path + Files[I].Name))
          else Inc(Total, ProgressWeight(Files[I].Size));
        end;
      end;
      ProgressOpen('Copy', 'Copying the file or directory', Total);

      Skipped := False;
      for I := 1 to Count do
      begin
        if Files[I].Tagged and (Files[I].Name <> '..') then
        begin
          if DestInput[Length(DestInput)] = '\' then
            TargetFile := DestInput + Files[I].Name
          else
            TargetFile := DestInput + '\' + Files[I].Name;

          if Files[I].IsDir then
          begin
            if IsSubPath(Path + Files[I].Name, TargetFile) then
              Skipped := True
            else
              CopyDirectoryTree(Path + Files[I].Name, TargetFile);
          end
          else
            CopySingleFile(Path + Files[I].Name, TargetFile, Files[I].Name);

          Files[I].Tagged := False;
        end;
        if OpCancelled then Break;
      end;
      ProgressClose;

      if Skipped then
        DialogInfo('Copy', 'Skipped: cannot copy a directory into itself.');
      ReportFailures('Copy', 'copy');
    end
    else
    begin
      if Files[Selected].Name = '..' then Exit;
      SrcName := Path + Files[Selected].Name;
      DestInput := DefDest;

      { Whole directory tree }
      if Files[Selected].IsDir then
      begin
        if not DialogPrompt('Copy Directory',
             'Copy directory ' + Files[Selected].Name + ' to:', DestInput) then Exit;
        if DestInput = '' then Exit;

        { A trailing backslash or an existing folder means 'copy into here' }
        if (DestInput[Length(DestInput)] = '\') or IsDirExists(DestInput) then
        begin
          if DestInput[Length(DestInput)] <> '\' then
            DestInput := DestInput + '\';
          TargetFile := DestInput + Files[Selected].Name;
        end
        else if Pos('\', DestInput) = 0 then
          TargetFile := Path + DestInput
        else
          TargetFile := DestInput;

        if IsSubPath(SrcName, TargetFile) then
        begin
          DialogInfo('Copy Directory', 'Cannot copy a directory into itself.');
          Exit;
        end;

        ProgressOpen('Copy', 'Scanning directories...', 1);
        Total := CountTree(SrcName);
        ProgressOpen('Copy', 'Copying the file or directory', Total);
        CopyDirectoryTree(SrcName, TargetFile);
        ProgressClose;
        ReportFailures('Copy', 'copy');
      end
      else
      begin
        if not DialogPrompt('Copy File',
             'Copy ' + Files[Selected].Name + ' to:', DestInput) then Exit;
        if DestInput = '' then Exit;

        if (DestInput[Length(DestInput)] = '\') or IsDirExists(DestInput) then
        begin
          if DestInput[Length(DestInput)] <> '\' then
            DestInput := DestInput + '\';
          TargetFile := DestInput + Files[Selected].Name;
        end
        else if Pos('\', DestInput) = 0 then
          TargetFile := Path + DestInput
        else
          TargetFile := DestInput;

        ProgressOpen('Copy', 'Copying the file or directory',
                     ProgressWeight(Files[Selected].Size));
        CopySingleFile(SrcName, TargetFile, Files[Selected].Name);
        ProgressClose;
        ReportFailures('Copy', 'copy');
      end;
    end;
  end;
  RefreshDirectory(LeftPanel);
  RefreshDirectory(RightPanel);
end;

procedure ActionRename;
var
  OldName, DestInput, TargetFile, DefDest: string;
  MovedName: string[12];
  I, Failed, Outcome: Integer;
  Recursed: Boolean;
begin
  ResetOperation;
  Failed := 0;
  Recursed := False;
  Outcome := MV_OK;
  with ActivePanel^ do
  begin
    if Count = 0 then Exit;
    if InsideZip then Exit; { ZIP archives are read-only mounts }

    if ActivePanel = @LeftPanel then DefDest := RightPanel.Path
    else DefDest := LeftPanel.Path;

    if HasTagged(ActivePanel^) then
    begin
      DestInput := DefDest;
      if not DialogPrompt('Move Multiple',
           'Move ' + IntToStr(TaggedCount(ActivePanel^)) + ' items to:',
           DestInput) then Exit;
      if DestInput = '' then Exit;

      if (DestInput[Length(DestInput)] <> '\') and
         (IsDirExists(DestInput) or (Pos('.', DestInput) = 0)) then
        DestInput := DestInput + '\';

      for I := 1 to Count do
      begin
        if Files[I].Tagged and (Files[I].Name <> '..') then
        begin
          OldName := Path + Files[I].Name;
          if DestInput[Length(DestInput)] = '\' then
            TargetFile := DestInput + Files[I].Name
          else
            TargetFile := DestInput + '\' + Files[I].Name;

          case MoveEntry(OldName, TargetFile, Files[I].IsDir) of
            MV_FAILED:   Failed := Failed + 1;
            MV_RECURSED: Recursed := True;
          end;
          Files[I].Tagged := False;
        end;
        if OpCancelled then Break;
      end;
      RefreshDirectory(LeftPanel);
      RefreshDirectory(RightPanel);

      if Recursed then
        DialogInfo('Move', 'Skipped: cannot move a directory into itself.')
      else if Failed > 0 then
        DialogInfo('Move', 'Could not move ' + IntToStr(Failed) + ' item(s).');
    end
    else
    begin
      if Files[Selected].Name = '..' then Exit;
      OldName := Path + Files[Selected].Name;
      DestInput := DefDest;
      if not DialogPrompt('Rename / Move',
           'Move/Rename ' + Files[Selected].Name + ' to:', DestInput) then Exit;
      if DestInput = '' then Exit;

      if (DestInput[Length(DestInput)] = '\') or IsDirExists(DestInput) then
      begin
        if DestInput[Length(DestInput)] <> '\' then
          DestInput := DestInput + '\';
        TargetFile := DestInput + Files[Selected].Name;
      end
      else if Pos('\', DestInput) = 0 then
        TargetFile := Path + DestInput
      else
        TargetFile := DestInput;

      MovedName := Files[Selected].Name;
      Outcome := MoveEntry(OldName, TargetFile, Files[Selected].IsDir);

      RefreshDirectory(ActivePanel^);
      if not WideMode then
      begin
        if ActivePanel = @LeftPanel then RefreshDirectory(RightPanel)
        else RefreshDirectory(LeftPanel);
      end;

      if Outcome = MV_RECURSED then
        DialogInfo('Move', 'Cannot move a directory into itself.')
      else if Outcome = MV_FAILED then
        DialogInfo('Move', 'Could not move ' + MovedName + '.');
    end;
  end;
end;

procedure ActionMkDir;
var
  DirName: string;
begin
  if ActivePanel^.InsideZip then Exit;
  DirName := '';
  if DialogPrompt('Make Directory', 'Create folder name:', DirName) and (DirName <> '') then
  begin
    MkDir(ActivePanel^.Path + DirName);
    if IOResult <> 0 then ;
    RefreshDirectory(ActivePanel^);
    SelectByName(ActivePanel^, DirName);
  end;
end;

procedure ActionDelete;
var
  Target: string;
  I: Integer;
  Total: LongInt;
begin
  ResetOperation;
  with ActivePanel^ do
  begin
    if Count = 0 then Exit;
    if InsideZip then Exit;

    if HasTagged(ActivePanel^) then
    begin
      if ConfirmOp('Confirm Delete',
           'Delete ' + IntToStr(TaggedCount(ActivePanel^)) + ' tagged item(s)?') then
      begin
        ProgressOpen('Delete', 'Scanning directories...', 1);
        Total := 0;
        for I := 1 to Count do
        begin
          if Files[I].Tagged and (Files[I].Name <> '..') then
          begin
            if Files[I].IsDir then Inc(Total, CountTree(Path + Files[I].Name))
            else Inc(Total, ProgressWeight(Files[I].Size));
          end;
        end;
        ProgressOpen('Delete', 'Deleting the file or directory', Total);

        for I := 1 to Count do
        begin
          if Files[I].Tagged and (Files[I].Name <> '..') then
          begin
            Target := Path + Files[I].Name;
            if Files[I].IsDir then EraseDirectoryTree(Target)
            else EraseFile(Target, Files[I].Name, Files[I].Size);
            Files[I].Tagged := False;
          end;
        end;
        ProgressClose;
        RefreshDirectory(LeftPanel);
        RefreshDirectory(RightPanel);
        ReportFailures('Delete', 'delete');
      end;
    end
    else
    begin
      if Files[Selected].Name = '..' then Exit;
      Target := Path + Files[Selected].Name;

      if Files[Selected].IsDir then
      begin
        if ConfirmOp('Confirm Delete',
             'Delete directory and ALL contents: ' + Files[Selected].Name + '?') then
        begin
          ProgressOpen('Delete', 'Scanning directories...', 1);
          Total := CountTree(Target);
          ProgressOpen('Delete', 'Deleting the file or directory', Total);
          EraseDirectoryTree(Target);
          ProgressClose;
          RefreshDirectory(LeftPanel);
          RefreshDirectory(RightPanel);
          ReportFailures('Delete', 'delete');
        end;
      end
      else
      begin
        if ConfirmOp('Confirm Delete',
             'Delete file: ' + Files[Selected].Name + '?') then
        begin
          ProgressOpen('Delete', 'Deleting the file or directory',
                       ProgressWeight(Files[Selected].Size));
          EraseFile(Target, Files[Selected].Name, Files[Selected].Size);
          ProgressClose;
          RefreshDirectory(LeftPanel);
          RefreshDirectory(RightPanel);
          ReportFailures('Delete', 'delete');
        end;
      end;
    end;
  end;
end;

procedure ActionNewFile;
var
  NewName, Target: string;
  F: file;
begin
  if ActivePanel^.InsideZip then Exit;
  NewName := '';
  if DialogPrompt('New File', 'Enter new file name:', NewName) and (NewName <> '') then
  begin
    Target := ActivePanel^.Path + NewName;

    Assign(F, Target);
    Reset(F, 1);
    if IOResult <> 0 then
    begin
      Rewrite(F, 1);
      if IOResult = 0 then Close(F);
    end
    else
      Close(F);

    LaunchProgram(LocateBinary(CfgEditor), Target, False);
    RefreshDirectory(ActivePanel^);
    SelectByName(ActivePanel^, NewName);
  end;
end;

procedure ActionViewEdit;
var
  TargetFile: string;
begin
  with ActivePanel^ do
  begin
    if Count = 0 then Exit;
    if Files[Selected].IsDir then Exit;

    if InsideZip then
    begin
      LaunchProgram(LocateBinary(CfgUnzip),
        UnzipCmd(ZipPath, Files[Selected].ZipFullName, '.'), False);
      LaunchProgram(LocateBinary(CfgEditor), Files[Selected].Name, False);
    end
    else
    begin
      TargetFile := Path + Files[Selected].Name;
      LaunchProgram(LocateBinary(CfgEditor), TargetFile, False);
    end;
    RefreshDirectory(ActivePanel^);
  end;
end;

procedure ActionViewImage;
var
  Target: string;
begin
  with ActivePanel^ do
  begin
    if Count = 0 then Exit;
    if Files[Selected].IsDir then Exit;

    if not IsImageExt(Files[Selected].Name) then
    begin
      DialogInfo('View Image', 'Not an image. Supported: BMP, JPG, GIF.');
      Exit;
    end;

    if InsideZip then
    begin
      { Extract to the current directory, then hand it to the viewer }
      LaunchProgram(LocateBinary(CfgUnzip),
        UnzipCmd(ZipPath, Files[Selected].ZipFullName, '.'), False);
      LaunchProgram(LocateBinary(CfgViewImg), Files[Selected].Name, False);
    end
    else
    begin
      Target := Path + Files[Selected].Name;
      LaunchProgram(LocateBinary(CfgViewImg), Target, False);
    end;

    RefreshDirectory(ActivePanel^);
  end;
end;

procedure ActionExecute;
var
  Target, Ext, PrevName: string;
  DotPos, I: Integer;
begin
  with ActivePanel^ do
  begin
    if Count = 0 then Exit;

    { Inside ZIP Navigation }
    if InsideZip then
    begin
      if Files[Selected].Name = '..' then
      begin
        if SubPath = '' then
        begin
          { Unmount ZIP and return to real disk folder }
          InsideZip := False;
          PrevName := LastComponent(ZipPath);
          Path := ZipPath;
          while (Length(Path) > 3) and (Path[Length(Path)] <> '\') do
            Dec(Path[0]);
          ZipPath := '';
          ReadDirectory(ActivePanel^);
          SelectByName(ActivePanel^, PrevName);
        end
        else
        begin
          { Move up one virtual level inside ZIP }
          if SubPath[Length(SubPath)] = '/' then Dec(SubPath[0]);
          PrevName := '';
          I := Length(SubPath);
          while (I > 0) and (SubPath[I] <> '/') do Dec(I);
          PrevName := Copy(SubPath, I + 1, Length(SubPath) - I);
          while (Length(SubPath) > 0) and (SubPath[Length(SubPath)] <> '/') do
            Dec(SubPath[0]);
          Path := ZipPath + '\';
          for I := 1 to Length(SubPath) do
            if SubPath[I] = '/' then Path := Path + '\'
            else Path := Path + SubPath[I];
          ReadZipDirectory(ActivePanel^);
          SelectByName(ActivePanel^, PrevName);
        end;
        Exit;
      end;

      if Files[Selected].IsDir then
      begin
        { Enter virtual subdirectory inside ZIP }
        SubPath := SubPath + Files[Selected].Name + '/';
        Path := ZipPath + '\';
        for I := 1 to Length(SubPath) do
          if SubPath[I] = '/' then Path := Path + '\'
          else Path := Path + SubPath[I];
        ReadZipDirectory(ActivePanel^);
        Exit;
      end;

      { Extract, then view images or edit anything else }
      LaunchProgram(LocateBinary(CfgUnzip),
        UnzipCmd(ZipPath, Files[Selected].ZipFullName, '.'), False);
      if IsImageExt(Files[Selected].Name) then
        LaunchProgram(LocateBinary(CfgViewImg), Files[Selected].Name, False)
      else
        LaunchProgram(LocateBinary(CfgEditor), Files[Selected].Name, False);
      RefreshDirectory(ActivePanel^);
      Exit;
    end;

    { Real Disk Directory Navigation }
    if Files[Selected].IsDir then
    begin
      if Files[Selected].Name = '..' then
      begin
        { Remember the folder being left so the cursor lands back on it }
        PrevName := LastComponent(Path);
        NavigateUp(Path);
        ReadDirectory(ActivePanel^);
        SelectByName(ActivePanel^, PrevName);
      end
      else
      begin
        NavigateDown(Path, Files[Selected].Name);
        ReadDirectory(ActivePanel^);
      end;
      Exit;
    end;

    { Check File Extension }
    Target := Files[Selected].Name;
    DotPos := Pos('.', Target);
    if DotPos > 0 then Ext := UpCaseStr(Copy(Target, DotPos + 1, 3))
    else Ext := '';

    { Mount .ZIP Archive into Virtual Directory }
    if Ext = 'ZIP' then
    begin
      InsideZip := True;
      ZipPath := Path + Target;
      SubPath := '';
      Path := ZipPath + '\';
      ReadZipDirectory(ActivePanel^);
      Exit;
    end;

    { Images go to the viewer }
    if IsImageExt(Target) then
    begin
      LaunchProgram(LocateBinary(CfgViewImg), Path + Target, False);
      RefreshDirectory(ActivePanel^);
      Exit;
    end;

    { Execute Executable Binaries }
    if (Ext = 'EXE') or (Ext = 'COM') or (Ext = 'BAT') then
    begin
      LaunchProgram(Path + Target, '', True);
      RefreshDirectory(ActivePanel^);
    end
    else
    begin
      LaunchProgram(LocateBinary(CfgEditor), Path + Target, False);
      RefreshDirectory(ActivePanel^);
    end;
  end;
end;

{===========================================================================}
{   COMMANDER EVENT LOOP                                                    }
{===========================================================================}

{ Shared by the function keys and by clicks on the bottom bar }
procedure DoFunctionKey(N: Integer);
begin
  case N of
    1: DialogHelp;
    2: DialogSettings;
    3: ActionViewImage;
    4: ActionViewEdit;
    5: ActionCopy;
    6: ActionRename;
    7: ActionMkDir;
    8: ActionDelete;
    9: ActionNewFile;
   10: Running := False;
  end;
end;

{ Which bar button covers a column, or 0. Walks the same widths as the draw }
function BarButtonAt(Col: Integer): Integer;
var
  I, X: Integer;
begin
  BarButtonAt := 0;
  X := 0;
  for I := 1 to 10 do
  begin
    if (Col >= X) and (Col < X + BarButtons[I].Width) then
    begin
      BarButtonAt := I;
      Exit;
    end;
    X := X + BarButtons[I].Width;
  end;
end;

{ File index under a click, or 0 when the click missed the list area }
function PanelIndexAt(var Panel: TPanel; Col, Row: Integer): Integer;
var
  C, Idx: Integer;
begin
  PanelIndexAt := 0;
  if (Row < 3) or (Row > 20) then Exit;

  if WideMode then
  begin
    for C := 0 to WIDE_COLS - 1 do
    begin
      if (Col >= WideColX[C]) and (Col < WideColX[C] + WideColW[C]) then
      begin
        Idx := Panel.TopIndex + (C * PANEL_ROWS) + (Row - 3);
        if (Idx >= 1) and (Idx <= Panel.Count) then PanelIndexAt := Idx;
        Exit;
      end;
    end;
  end
  else
  begin
    if (Col < Panel.StartX + 1) or (Col > Panel.StartX + 38) then Exit;
    Idx := Panel.TopIndex + (Row - 3);
    if (Idx >= 1) and (Idx <= Panel.Count) then PanelIndexAt := Idx;
  end;
end;

{ Sort column under a click on the header row.                            }
{ Normal mode has four labelled columns. Wide mode has no size/date/time  }
{ headings, so its indicator in the top border steps through the states.  }
function HeaderSortAt(var Panel: TPanel; Col, Row: Integer;
                      var NewCol: TSortCol): Boolean;
var
  RelX: Integer;
begin
  HeaderSortAt := False;

  if WideMode then
  begin
    if (Row = 0) and (Col >= 56) and (Col <= 73) then
    begin
      { Ascending -> descending -> next column. ApplySort flips the        }
      { direction when handed the current column, and resets to ascending  }
      { when handed a new one, so this walks all eight states.             }
      if Panel.SortDir = sdAsc then
        NewCol := Panel.SortCol
      else
        case Panel.SortCol of
          scName: NewCol := scSize;
          scSize: NewCol := scDate;
          scDate: NewCol := scTime;
          scTime: NewCol := scName;
        end;
      HeaderSortAt := True;
      Exit;
    end;
    if Row = 1 then          { every wide column is headed Name }
    begin
      NewCol := scName;
      HeaderSortAt := True;
    end;
    Exit;
  end;

  if Row <> 1 then Exit;
  RelX := Col - Panel.StartX;
  if (RelX >= 1) and (RelX <= 12) then NewCol := scName
  else if (RelX >= 14) and (RelX <= 22) then NewCol := scSize
  else if (RelX >= 24) and (RelX <= 31) then NewCol := scDate
  else if (RelX >= 33) and (RelX <= 38) then NewCol := scTime
  else Exit;
  HeaderSortAt := True;
end;

var
  LastClickIdx: Integer;
  LastClickTick: LongInt;

procedure HandleClick(Col, Row: Integer; RightBtn: Boolean);
var
  Target: PPanel;
  Idx, Btn: Integer;
  Tick: LongInt;
  SortCol: TSortCol;
begin
  NeedFull := False;

  { Function key bar }
  if Row = 24 then
  begin
    if RightBtn then Exit;
    Btn := BarButtonAt(Col);
    if Btn > 0 then
    begin
      NeedFull := True;
      DoFunctionKey(Btn);
    end;
    Exit;
  end;

  if Row > 23 then Exit;

  { Which panel was hit }
  if WideMode then
    Target := ActivePanel
  else if Col < 40 then
    Target := @LeftPanel
  else
    Target := @RightPanel;

  { Clicking an inactive panel activates it - borders change, so repaint }
  if Target <> ActivePanel then
  begin
    ActivePanel := Target;
    NeedFull := True;
  end;

  { Header click sorts that column; clicking it again reverses the order, }
  { exactly as the N / S / D / T keys do.                                  }
  if not RightBtn then
  begin
    if HeaderSortAt(Target^, Col, Row, SortCol) then
    begin
      ApplySort(Target^, SortCol);
      NeedFull := True;
      Exit;
    end;
  end;

  Idx := PanelIndexAt(Target^, Col, Row);
  if Idx = 0 then Exit;

  if RightBtn then
  begin
    { Same effect as Ins, but without advancing the cursor }
    Target^.Selected := Idx;
    if Target^.Files[Idx].Name <> '..' then
      Target^.Files[Idx].Tagged := not Target^.Files[Idx].Tagged;
    Target^.Dirty := True;
    Exit;
  end;

  Tick := GetTicks;
  Target^.Selected := Idx;
  Target^.Dirty := True;

  { Second click on the same entry within ~0.5s opens it }
  if (Idx = LastClickIdx) and (Tick - LastClickTick <= DBLCLICK_TICKS) and
     (Tick >= LastClickTick) then
  begin
    LastClickIdx := 0;
    NeedFull := True;
    ActionExecute;
  end
  else
  begin
    LastClickIdx := Idx;
    LastClickTick := Tick;
  end;
end;

{ True when a click was consumed }
function HandleMouse: Boolean;
var
  Col, Row: Integer;
begin
  HandleMouse := False;
  if not MouseAvailable then Exit;

  if MousePress(0, Col, Row) then
  begin
    HandleClick(Col, Row, False);
    HandleMouse := True;
    Exit;
  end;
  if MousePress(1, Col, Row) then
  begin
    HandleClick(Col, Row, True);
    HandleMouse := True;
  end;
end;

procedure ProcessKeyboard;
var
  Ch, AltCh: Char;
  Scan: Byte;
begin
  Ch := ReadKeyBIOS(Scan);

  { Default to a full repaint; pure navigation clears this again below }
  NeedFull := True;

  if Ch = #0 then
  begin
    AltCh := AltScanToChar(Scan);
    if AltCh <> #0 then
    begin
      if Length(QuickSearchStr) < 12 then
        QuickSearchStr := QuickSearchStr + AltCh;
      DoQuickSearch(ActivePanel^, QuickSearchStr);
      ActivePanel^.Dirty := True;
      NeedFull := False;
      Exit;
    end;

    QuickSearchStr := '';

    case Scan of
      KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_PAGEUP, KEY_PAGEDOWN,
      KEY_HOME, KEY_END, KEY_INSERT:
        NeedFull := False;
    end;

    case Scan of
      KEY_UP:
        if ActivePanel^.Selected > 1 then Dec(ActivePanel^.Selected);

      KEY_DOWN:
        if ActivePanel^.Selected < ActivePanel^.Count then Inc(ActivePanel^.Selected);

      KEY_LEFT:
        if WideMode then
        begin
          if ActivePanel^.Selected > PANEL_ROWS then
            Dec(ActivePanel^.Selected, PANEL_ROWS)
          else
            ActivePanel^.Selected := 1;
        end;

      KEY_RIGHT:
        if WideMode then
        begin
          if ActivePanel^.Selected + PANEL_ROWS <= ActivePanel^.Count then
            Inc(ActivePanel^.Selected, PANEL_ROWS)
          else
            ActivePanel^.Selected := ActivePanel^.Count;
        end;

      KEY_PAGEUP:
        begin
          if WideMode then
            Dec(ActivePanel^.Selected, WIDE_COLS * PANEL_ROWS)
          else
            Dec(ActivePanel^.Selected, PANEL_ROWS);
          if ActivePanel^.Selected < 1 then ActivePanel^.Selected := 1;
        end;

      KEY_PAGEDOWN:
        begin
          if WideMode then
            Inc(ActivePanel^.Selected, WIDE_COLS * PANEL_ROWS)
          else
            Inc(ActivePanel^.Selected, PANEL_ROWS);
          if ActivePanel^.Selected > ActivePanel^.Count then
            ActivePanel^.Selected := ActivePanel^.Count;
        end;

      KEY_HOME: ActivePanel^.Selected := 1;
      KEY_END:  ActivePanel^.Selected := ActivePanel^.Count;

      KEY_INSERT:
        with ActivePanel^ do
        begin
          if (Count > 0) and (Files[Selected].Name <> '..') then
          begin
            Files[Selected].Tagged := not Files[Selected].Tagged;
            Dirty := True;
            if Selected < Count then Inc(Selected);
          end;
        end;

      KEY_ALT_F1: SelectDrive(LeftPanel);

      KEY_ALT_F2: SelectDrive(RightPanel);

      KEY_F1:  DoFunctionKey(1);
      KEY_F2:  DoFunctionKey(2);
      KEY_F3:  DoFunctionKey(3);
      KEY_F4:  DoFunctionKey(4);
      KEY_F5:  DoFunctionKey(5);
      KEY_F6:  DoFunctionKey(6);
      KEY_F7:  DoFunctionKey(7);
      KEY_F8:  DoFunctionKey(8);
      KEY_F9:  DoFunctionKey(9);
      KEY_F10: DoFunctionKey(10);
    end;
  end
  else
  begin
    case Ch of
      #8:
        if QuickSearchStr <> '' then
        begin
          Dec(QuickSearchStr[0]);
          if QuickSearchStr <> '' then
            DoQuickSearch(ActivePanel^, QuickSearchStr);
          ActivePanel^.Dirty := True;
          NeedFull := False;
          Exit;
        end;

      #27:
        if QuickSearchStr <> '' then
        begin
          QuickSearchStr := '';
          ActivePanel^.Dirty := True;
          NeedFull := False;
          Exit;
        end
        else
          Running := False;
    end;

    QuickSearchStr := '';

    case Ch of
      #9: { TAB: Switch panel }
        begin
          if ActivePanel = @LeftPanel then
            ActivePanel := @RightPanel
          else
            ActivePanel := @LeftPanel;

          if WideMode then
            ActivePanel^.StartX := 0;
        end;

      #13: { ENTER }
        ActionExecute;

      'w', 'W':
        begin
          WideMode := not WideMode;
          FillBox(0, 0, 79, 23, ' ', ATTR_NORMAL);
          if WideMode then
            ActivePanel^.StartX := 0
          else
          begin
            LeftPanel.StartX := 0;
            RightPanel.StartX := 40;
          end;
        end;

      'f', 'F': DialogFilter(ActivePanel^);

      'n', 'N': ApplySort(ActivePanel^, scName);

      's', 'S': ApplySort(ActivePanel^, scSize);

      'd', 'D': ApplySort(ActivePanel^, scDate);

      't', 'T': ApplySort(ActivePanel^, scTime);
    end;
  end;
end;

{ Waits for the next event. With no mouse this is the original blocking    }
{ keyboard read, so behaviour on a machine without a driver is unchanged.  }
procedure WaitInput;
begin
  if not MouseAvailable then
  begin
    ProcessKeyboard;
    Exit;
  end;

  repeat
    if HandleMouse then Exit;
    if KeyWaiting then
    begin
      ProcessKeyboard;
      Exit;
    end;
  until not Running;
end;

{===========================================================================}
{   MAIN ENTRY POINT                                                        }
{===========================================================================}

var
  StartDir: string;
begin
  GetIntVec($24, OldInt24);
  SetIntVec($24, @CriticalErrorHandler);

  LoadConfig;

  MouseShown := False;
  MouseAvailable := MouseInit;
  LastClickIdx := 0;
  LastClickTick := 0;

  FillBox(0, 0, 79, 23, ' ', ATTR_NORMAL);

  GetDir(0, StartDir);
  if StartDir[Length(StartDir)] <> '\' then
    StartDir := StartDir + '\';

  WideMode := False;
  QuickSearchStr := '';

  LeftPanel.Path := StartDir;
  LeftPanel.StartX := 0;
  LeftPanel.SortCol := scName;
  LeftPanel.SortDir := sdAsc;
  LeftPanel.InsideZip := False;
  LeftPanel.ZipPath := '';
  LeftPanel.SubPath := '';
  LeftPanel.DrawnSel := 0;
  LeftPanel.DrawnTop := 0;
  LeftPanel.Dirty := True;
  ReadDirectory(LeftPanel);

  RightPanel.Path := StartDir;
  RightPanel.StartX := 40;
  RightPanel.SortCol := scName;
  RightPanel.SortDir := sdAsc;
  RightPanel.InsideZip := False;
  RightPanel.ZipPath := '';
  RightPanel.SubPath := '';
  RightPanel.DrawnSel := 0;
  RightPanel.DrawnTop := 0;
  RightPanel.Dirty := True;
  ReadDirectory(RightPanel);

  ActivePanel := @LeftPanel;
  Running := True;

  HideCursor;

  NeedFull := True;
  while Running do
  begin
    UpdateScreen;
    WaitInput;
  end;

  MouseHide;
  SetIntVec($24, OldInt24);
  FillBox(0, 0, 79, 24, ' ', $07);
  SetCursor(0, 0);
  ShowCursor;
end.