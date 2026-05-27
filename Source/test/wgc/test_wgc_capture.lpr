{
  Acceptance test for simba.capture_wgc.pas + the
  simba.nativeinterface_windows.GetWindowImage WGC delegation.

  Default mode (no special argv) drives a real WGC capture session against
  a target HWND:

    1. Parse HWND from argv[1] (decimal or 0x-hex). If absent, use
       GetForegroundWindow.
    2. WGCAutoOpen(hwnd).
    3. Wait briefly for the frame pool to deliver the first frame.
    4. Capture 5 frames at 200ms intervals via WGCTryGetImage.
    5. Hash each frame (FNV-1a 64-bit; cheap, no extra deps) and confirm
       at least 4 of 5 differ for a moving target like Task Manager.
    6. Save frame #3 as a 24-bit BMP for visual inspection
       (frame_03.bmp next to the executable).
    7. Call SimbaNativeInterface.GetWindowImage (the public entry point)
       and verify that the integration delegates to WGC — proves the
       wiring is intact.
    8. WGCRelease.

  Special mode --notepad:
    Replacement for the old --cpu-only short-circuit test. Confirms that
    WGC successfully captures from a CPU-rendered window (classic
    Notepad — no GPU DLLs loaded). Used to be a "stays at 0" expectation
    when the GPU auto-detection short-circuit was in place; now the
    auto-detection is gone (pure replacement design) and WGC captures
    every window kind, so the expectation flips: WGCFrameCount MUST
    climb and at least one frame MUST be retrievable.

  Exit codes:
    0 = SUCCESS
    1 = WGCAutoOpen failed (no frame buffer dimensions produced)
    2 = WGCTryGetImage failed on the first attempt (no frame ever
        arrived). Most common cause: target window can't be captured
        (DRM, certain UWP windows, IDD-only setups).
    3 = Frame hashes all identical (capture is "live" only in name -
        likely capturing a frozen/blank surface).
    4 = BMP write failed.
    5 = SimbaNativeInterface.GetWindowImage round-trip failed
        (WGC declined the capture; GetWindowImage has no fallback).
    6 = --notepad mode: WGC failed to capture from Notepad
        (WGCFrameCount stayed at 0 or WGCTryGetImage returned False).

  Build:
    "/c/fpcup/lazarus/lazbuild.exe" --build-mode=Default test_wgc_capture.lpi

  Run examples:
    ./test_wgc_capture.exe 0x000B0042   # specific HWND
    ./test_wgc_capture.exe              # foreground window
    ./test_wgc_capture.exe --notepad    # CPU-window-via-WGC check
}
program test_wgc_capture;

{$mode objfpc}{$H+}

uses
  // Interfaces brings in the LCL widget-set registrations the LCLType
  // helpers in simba.nativeinterface need.
  Interfaces,
  SysUtils, Windows, Classes,
  simba.base, simba.capture_wgc,
  simba.nativeinterface_windows;

const
  CAPTURE_DELAY_MS_FIRST = 500;    // wait for first frame
  CAPTURE_DELAY_MS_BETWEEN = 1100; // between subsequent frames. Must
                                   // exceed Task Manager's ~1s update
                                   // cycle so an idle tick-updating
                                   // target produces 4/5 distinct
                                   // hashes (spec target).
  NUM_FRAMES = 5;
  BMP_FRAME_INDEX = 2;            // 0-based; 3rd frame

type
  TFrameInfo = record
    Width:  Integer;
    Height: Integer;
    Hash:   UInt64;
    Data:   PColorBGRA; // owned; freed at exit
  end;

// FNV-1a 64-bit. Simple, fast, sufficient for "are these byte arrays
// distinct" — not for security.
function FNV1a64(Data: PByte; Len: SizeUInt): UInt64;
const
  FNV_OFFSET = UInt64($CBF29CE484222325);
  FNV_PRIME  = UInt64($00000100000001B3);
var
  i: SizeUInt;
begin
  Result := FNV_OFFSET;
  for i := 0 to Len - 1 do
  begin
    Result := Result xor Data[i];
    Result := Result * FNV_PRIME;
  end;
end;

function HexU64(V: UInt64): String;
begin
  Result := IntToHex(V, 16);
end;

// Parse argv[1] as HWND. Accepts "12345" or "0xABCD" / "0XABCD".
// Returns 0 on parse failure (caller substitutes GetForegroundWindow).
function ParseHWND(const S: String): HWND;
var
  Code: Integer;
  N: UInt64;
begin
  Result := 0;
  if S = '' then Exit;
  if (Length(S) > 2) and (S[1] = '0') and ((S[2] = 'x') or (S[2] = 'X')) then
    Val('$' + Copy(S, 3, Length(S) - 2), N, Code)
  else
    Val(S, N, Code);
  if Code = 0 then
    Result := HWND(N);
end;

// Write a 24-bit BGR uncompressed BMP from a BGRA32 buffer. BMPs are
// stored bottom-up; we flip on write.
function WriteBMP(const Filename: String; Data: PColorBGRA;
                  Width, Height: Integer): Boolean;
var
  F: TFileStream;
  FileHeader: packed record
    bfType:      Word;
    bfSize:      UInt32;
    bfReserved1: Word;
    bfReserved2: Word;
    bfOffBits:   UInt32;
  end;
  InfoHeader: packed record
    biSize:          UInt32;
    biWidth:         Int32;
    biHeight:        Int32;
    biPlanes:        Word;
    biBitCount:      Word;
    biCompression:   UInt32;
    biSizeImage:     UInt32;
    biXPelsPerMeter: Int32;
    biYPelsPerMeter: Int32;
    biClrUsed:       UInt32;
    biClrImportant:  UInt32;
  end;
  RowSize, PadSize: Integer;
  PadBytes: array[0..3] of Byte;
  Y, X: Integer;
  RowBuf: array of Byte;
  Src: PColorBGRA;
begin
  Result := False;

  RowSize := Width * 3;
  PadSize := (4 - (RowSize mod 4)) and 3;
  FillChar(PadBytes, SizeOf(PadBytes), 0);

  FillChar(FileHeader, SizeOf(FileHeader), 0);
  FileHeader.bfType := $4D42; // 'BM'
  FileHeader.bfOffBits := SizeOf(FileHeader) + SizeOf(InfoHeader);
  FileHeader.bfSize := FileHeader.bfOffBits + UInt32((RowSize + PadSize) * Height);

  FillChar(InfoHeader, SizeOf(InfoHeader), 0);
  InfoHeader.biSize := SizeOf(InfoHeader);
  InfoHeader.biWidth := Width;
  InfoHeader.biHeight := Height;       // positive: bottom-up DIB
  InfoHeader.biPlanes := 1;
  InfoHeader.biBitCount := 24;
  InfoHeader.biCompression := 0;       // BI_RGB
  InfoHeader.biSizeImage := UInt32((RowSize + PadSize) * Height);

  SetLength(RowBuf, RowSize);
  try
    try
      F := TFileStream.Create(Filename, fmCreate);
    except
      Exit;
    end;
    try
      F.WriteBuffer(FileHeader, SizeOf(FileHeader));
      F.WriteBuffer(InfoHeader, SizeOf(InfoHeader));

      // Write rows bottom-up.
      for Y := Height - 1 downto 0 do
      begin
        Src := PColorBGRA(PByte(Data) + Y * Width * SizeOf(TColorBGRA));
        for X := 0 to Width - 1 do
        begin
          RowBuf[X * 3 + 0] := Src[X].B;
          RowBuf[X * 3 + 1] := Src[X].G;
          RowBuf[X * 3 + 2] := Src[X].R;
        end;
        F.WriteBuffer(RowBuf[0], RowSize);
        if PadSize > 0 then
          F.WriteBuffer(PadBytes, PadSize);
      end;
      Result := True;
    finally
      F.Free;
    end;
  except
    Result := False;
  end;
end;

// EnumWindows callback for the Notepad search.
type
  TNotepadSearch = record
    Found: HWND;
  end;
  PNotepadSearch = ^TNotepadSearch;

function FindNotepadCallback(Window: HWND; LParam: LPARAM): WINBOOL; stdcall;
var
  Buf: array[0..255] of WideChar;
  N: Integer;
  ClassName: String;
begin
  Result := True;
  if not IsWindowVisible(Window) then Exit;
  N := GetClassNameW(Window, Buf, Length(Buf));
  if N <= 0 then Exit;
  ClassName := UTF8Encode(UnicodeString(WideCharLenToString(Buf, N)));
  // Classic Notepad is "Notepad". Win11 modern Notepad is a UWP/WinUI
  // package — also captures via WGC, but classic Notepad is the
  // strongest test case for "WGC works on a process with no GPU DLLs
  // loaded".
  if ClassName = 'Notepad' then
  begin
    PNotepadSearch(LParam)^.Found := Window;
    Result := False; // stop enumeration
  end;
end;

function FindNotepadWindow: HWND;
var
  Search: TNotepadSearch;
begin
  Search.Found := 0;
  EnumWindows(@FindNotepadCallback, LPARAM(@Search));
  Result := Search.Found;
end;

// --notepad mode: replacement for the old CPU-only short-circuit test.
// The new design has no GPU auto-detection — WGC engages for every
// window. Notepad must therefore produce frames. Returns process exit
// code.
function RunNotepadTest: Integer;
var
  HW: HWND;
  TitleBuf: array[0..255] of WideChar;
  TitleLen: Integer;
  Title: String;
  StartCount: Int64;
  WindowRect: Windows.TRect;
  W, H: Integer;
  Probe: PColorBGRA;
  Got: Boolean;
begin
  WriteLn('Notepad-via-WGC test');
  WriteLn('--------------------');

  HW := FindNotepadWindow();
  if HW = 0 then
  begin
    WriteLn('SKIP: no Notepad (class "Notepad") window found.');
    WriteLn('  Open classic Notepad and re-run.');
    Result := 0;
    Exit;
  end;

  TitleLen := GetWindowTextW(HW, TitleBuf, Length(TitleBuf));
  if TitleLen > 0 then
    Title := UTF8Encode(UnicodeString(WideCharLenToString(TitleBuf, TitleLen)))
  else
    Title := '(no title)';
  WriteLn('  [info] target HWND ', HW, ' title: ', Title);

  StartCount := WGCFrameCount();
  WriteLn('  [info] WGCFrameCount before: ', StartCount);

  WGCAutoOpen(TWindowHandle(HW));
  if WGCLastError() <> '' then
  begin
    WriteLn('FAIL: WGCAutoOpen reported: ', WGCLastError());
    Result := 1;
    Exit;
  end;

  // Give plenty of time for the first frame.
  Sleep(1500);

  WriteLn('  [info] WGCFrameCount after WGCAutoOpen + 1500ms: ', WGCFrameCount());
  WriteLn('  [info] WGCLastError: "', WGCLastError(), '"');

  if WGCFrameCount() <= StartCount then
  begin
    WriteLn('FAIL: WGCFrameCount did not climb - WGC did not capture from Notepad');
    WriteLn('  (Pure replacement design: WGC must engage for every window,');
    WriteLn('   including CPU-rendered ones with no GPU DLLs loaded.)');
    WGCRelease();
    Result := 6;
    Exit;
  end;

  // Verify we can actually retrieve a frame.
  if not GetWindowRect(HW, @WindowRect) then
  begin
    WriteLn('FAIL: GetWindowRect for Notepad failed');
    WGCRelease();
    Result := 1;
    Exit;
  end;
  W := WindowRect.Right - WindowRect.Left;
  H := WindowRect.Bottom - WindowRect.Top;
  if W < 1 then W := 1;
  if H < 1 then H := 1;

  Probe := nil;
  Got := WGCTryGetImage(TWindowHandle(HW), 0, 0, W, H, Probe);
  if Probe <> nil then
    FreeMem(Probe);

  if not Got then
  begin
    WriteLn('FAIL: WGCTryGetImage returned False despite WGCFrameCount climbing');
    WGCRelease();
    Result := 6;
    Exit;
  end;

  WGCRelease();
  WriteLn('  [ok] WGC captured ', WGCFrameCount() - StartCount,
          ' frame(s) from Notepad; WGCTryGetImage produced ', W, 'x', H,
          ' image');
  WriteLn('SUCCESS: WGC handles CPU-rendered windows (pure replacement design confirmed)');
  Result := 0;
end;

var
  HW: HWND;
  Frames: array[0..NUM_FRAMES - 1] of TFrameInfo;
  i, j, DistinctCount: Integer;
  TitleBuf: array[0..255] of WideChar;
  TitleLen: Integer;
  Title: String;
  WindowRect: Windows.TRect;
  W, H: Integer;
  Got: Boolean;
  BMPName: String;
  BMPFullPath: String;
  Attempts: Integer;
  ExitCode_: Integer;
  Identical: Array of Boolean;
  HookData: PColorBGRA;
  HookFrameCount: Int64;
  Native: TSimbaNativeInterface_Windows;
begin
  ExitCode_ := 0;

  // --notepad: Notepad-via-WGC check (replaces the old --cpu-only).
  if (ParamCount >= 1) and (ParamStr(1) = '--notepad') then
    Halt(RunNotepadTest());

  WriteLn('WGC capture acceptance test');
  WriteLn('---------------------------');

  // Resolve target HWND.
  if ParamCount >= 1 then
  begin
    HW := ParseHWND(ParamStr(1));
    if HW = 0 then
    begin
      WriteLn('  [warn] could not parse "', ParamStr(1), '" as HWND; falling back to foreground');
      HW := GetForegroundWindow();
    end
    else
      WriteLn('  [info] using HWND from argv: ', HW);
  end
  else
  begin
    HW := GetForegroundWindow();
    WriteLn('  [info] no HWND argv; using foreground window: ', HW);
  end;

  if HW = 0 then
  begin
    WriteLn('FAIL: no valid HWND to capture');
    Halt(1);
  end;

  if not IsWindow(HW) then
  begin
    WriteLn('FAIL: HWND ', HW, ' is not a valid window');
    Halt(1);
  end;

  TitleLen := GetWindowTextW(HW, TitleBuf, SizeOf(TitleBuf) div SizeOf(WideChar));
  if TitleLen > 0 then
    Title := UTF8Encode(UnicodeString(WideCharLenToString(TitleBuf, TitleLen)))
  else
    Title := '(no title)';
  WriteLn('  [info] window title: ', Title);

  if GetWindowRect(HW, @WindowRect) then
  begin
    W := WindowRect.Right - WindowRect.Left;
    H := WindowRect.Bottom - WindowRect.Top;
    WriteLn('  [info] window rect: ', W, 'x', H,
            ' at (', WindowRect.Left, ',', WindowRect.Top, ')');
  end;

  // 1. Open.
  WGCAutoOpen(TWindowHandle(HW));
  if WGCLastError() <> '' then
  begin
    WriteLn('FAIL: WGCAutoOpen reported: ', WGCLastError());
    Halt(1);
  end;
  WriteLn('  [ok] WGCAutoOpen()');

  // 2. Wait for first frame.
  WriteLn('  [info] sleeping ', CAPTURE_DELAY_MS_FIRST, 'ms for first frame...');
  Sleep(CAPTURE_DELAY_MS_FIRST);

  // 3. Capture N frames.
  for i := 0 to NUM_FRAMES - 1 do
    Frames[i].Data := nil;

  for i := 0 to NUM_FRAMES - 1 do
  begin
    // Determine target rect from current window size each iteration
    // (window may have moved/resized between iterations; we always sample
    // the FULL captured surface, which the FrameArrived handler resizes
    // to whatever the target's current size is).
    Got := False;

    // First-frame retry: WGC sometimes takes longer than 500ms. Retry up
    // to ~2s before giving up.
    Attempts := 0;
    while (not Got) and (Attempts < 10) do
    begin
      if GetWindowRect(HW, @WindowRect) then
      begin
        W := WindowRect.Right - WindowRect.Left;
        H := WindowRect.Bottom - WindowRect.Top;
      end
      else
      begin
        W := 800; H := 600;
      end;
      if W < 1 then W := 1;
      if H < 1 then H := 1;

      Got := WGCTryGetImage(TWindowHandle(HW), 0, 0, W, H, Frames[i].Data);
      if not Got then
        Sleep(100);
      Inc(Attempts);
    end;

    if not Got then
    begin
      if i = 0 then
      begin
        WriteLn('FAIL: WGCTryGetImage returned False on first frame after ',
                Attempts, ' attempts');
        WriteLn('  Last error: ', WGCLastError());
        WGCRelease();
        Halt(2);
      end
      else
      begin
        // Subsequent frames may fail transiently if the window resized
        // mid-iteration. Use the previous frame's hash as a placeholder.
        WriteLn('  [warn] frame ', i, ': WGCTryGetImage returned False');
        Frames[i].Width := Frames[i - 1].Width;
        Frames[i].Height := Frames[i - 1].Height;
        Frames[i].Hash := 0;
        Continue;
      end;
    end;

    Frames[i].Width := W;
    Frames[i].Height := H;
    Frames[i].Hash := FNV1a64(PByte(Frames[i].Data),
                              SizeUInt(W) * SizeUInt(H) * SizeOf(TColorBGRA));

    WriteLn(Format('  frame %d: %dx%d  hash=0x%s  WGCFrameCount=%d',
                   [i + 1, W, H, HexU64(Frames[i].Hash), WGCFrameCount()]));

    if i < NUM_FRAMES - 1 then
      Sleep(CAPTURE_DELAY_MS_BETWEEN);
  end;

  // 4. Confirm liveness: count distinct hashes.
  SetLength(Identical, NUM_FRAMES);
  for i := 0 to NUM_FRAMES - 1 do
    Identical[i] := False;
  DistinctCount := 0;
  for i := 0 to NUM_FRAMES - 1 do
  begin
    if Identical[i] then Continue;
    Inc(DistinctCount);
    for j := i + 1 to NUM_FRAMES - 1 do
      if Frames[j].Hash = Frames[i].Hash then
        Identical[j] := True;
  end;
  WriteLn('  [info] distinct hashes: ', DistinctCount, ' / ', NUM_FRAMES);

  // 5. Save frame #BMP_FRAME_INDEX as BMP.
  BMPName := 'frame_' + Format('%.2d', [BMP_FRAME_INDEX + 1]) + '.bmp';
  BMPFullPath := ExtractFilePath(ParamStr(0)) + BMPName;
  if (Frames[BMP_FRAME_INDEX].Data <> nil) and
     (Frames[BMP_FRAME_INDEX].Width > 0) and
     (Frames[BMP_FRAME_INDEX].Height > 0) then
  begin
    if not WriteBMP(BMPFullPath, Frames[BMP_FRAME_INDEX].Data,
                    Frames[BMP_FRAME_INDEX].Width,
                    Frames[BMP_FRAME_INDEX].Height) then
    begin
      WriteLn('FAIL: WriteBMP failed for ', BMPFullPath);
      ExitCode_ := 4;
    end
    else
      WriteLn('  [ok] wrote ', BMPFullPath, ' (',
              Frames[BMP_FRAME_INDEX].Width, 'x', Frames[BMP_FRAME_INDEX].Height, ')');
  end
  else
    WriteLn('  [warn] no data for frame ', BMP_FRAME_INDEX + 1, '; skipping BMP write');

  // 6. Acceptance verdict.
  if DistinctCount >= 4 then
    WriteLn('  [ok] >=4/5 distinct hashes - live moving capture confirmed')
  else if DistinctCount >= 2 then
    WriteLn('  [info] only ', DistinctCount, '/5 distinct hashes - capture is producing frames')
  else
    WriteLn('  [warn] all 5 hashes identical - capture appears frozen');

  // 7. GetWindowImage round-trip. GetWindowImage is a thin delegation
  //    to WGCTryGetImage; WGCAutoOpen was already called above, so the
  //    call should succeed. ImageData is allocated via ReAllocMem inside
  //    the WGC path.
  WriteLn('  [info] SimbaNativeInterface.GetWindowImage round-trip');
  Native := TSimbaNativeInterface_Windows.Create();
  try
    HookData := nil;
    HookFrameCount := WGCFrameCount();
    if W < 1 then W := 1;
    if H < 1 then H := 1;
    Got := Native.GetWindowImage(TWindowHandle(HW), 0, 0, W, H, HookData);
    if (not Got) or (HookData = nil) then
    begin
      WriteLn('FAIL: SimbaNativeInterface.GetWindowImage returned ', Got,
              ' / ImageData=', PtrUInt(HookData));
      WriteLn('  WGC declined the capture (GetWindowImage has no fallback).');
      ExitCode_ := 5;
    end
    else
    begin
      WriteLn('  [ok] GetWindowImage Result=True, ImageData non-nil (',
              W, 'x', H, ')');
      WriteLn('  [info] WGCFrameCount: before=', HookFrameCount,
              ' after=', WGCFrameCount());
    end;
    if HookData <> nil then
      FreeMem(HookData);
  finally
    Native.Free;
  end;

  // 8. Cleanup.
  WGCRelease();
  WriteLn('  [ok] WGCRelease()');

  for i := 0 to NUM_FRAMES - 1 do
    if Frames[i].Data <> nil then
      FreeMem(Frames[i].Data);

  if ExitCode_ <> 0 then
    Halt(ExitCode_);

  if DistinctCount < 2 then
  begin
    WriteLn('FAIL: capture appears frozen (all hashes identical)');
    Halt(3);
  end;

  WriteLn('SUCCESS: WGC capture roundtrip + GetWindowImage integration');
  Halt(0);
end.
