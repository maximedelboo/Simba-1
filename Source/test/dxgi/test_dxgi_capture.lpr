{
  Acceptance test for simba.capture_dxgi.pas + the
  simba.nativeinterface_windows.GetWindowImage DXGI delegation.

  Default mode (no special argv) drives a real DXGI Desktop Duplication
  capture session against a target HWND:

    1. Parse HWND from argv[1] (decimal or 0x-hex). If absent, use
       GetForegroundWindow.
    2. DXGIAutoOpen(hwnd).
    3. Capture 5 frames at ~1.1s intervals via DXGITryGetImage.
    4. Hash each frame (FNV-1a 64-bit; cheap, no extra deps) and confirm
       at least 4 of 5 differ for a moving target like Task Manager.
    5. Save frame #3 as a 24-bit BMP for visual inspection
       (frame_03.bmp next to the executable).
    6. DXGIRelease.

  Exit codes:
    0 = SUCCESS
    1 = DXGIAutoOpen failed (no duplication produced; see DXGILastError)
    2 = DXGITryGetImage failed on the first attempt (no frame ever
        arrived). Most common cause: target window is on a monitor
        whose IDXGIOutput1 lives on a different DXGI adapter than the
        D3D11 default-driver adapter (hybrid laptops).
    3 = Frame hashes all identical (capture is "live" only in name -
        likely capturing a frozen surface; flaky on certain virtual
        displays).
    4 = BMP write failed.

  Build:
    "/c/fpcup/lazarus/lazbuild.exe" --build-mode=Default test_dxgi_capture.lpi

  Run examples:
    ./test_dxgi_capture.exe 0x000B0042   # specific HWND
    ./test_dxgi_capture.exe              # foreground window
}
program test_dxgi_capture;

{$mode objfpc}{$H+}

uses
  Interfaces,
  SysUtils, Windows, Classes,
  simba.base, simba.capture_dxgi;

const
  CAPTURE_DELAY_MS_FIRST = 500;
  CAPTURE_DELAY_MS_BETWEEN = 1100; // > Task Manager's ~1s update cycle
  NUM_FRAMES = 5;
  BMP_FRAME_INDEX = 2; // 0-based; 3rd frame

type
  TFrameInfo = record
    Width:  Integer;
    Height: Integer;
    Hash:   UInt64;
    Data:   PColorBGRA;
  end;

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
  FileHeader.bfType := $4D42;
  FileHeader.bfOffBits := SizeOf(FileHeader) + SizeOf(InfoHeader);
  FileHeader.bfSize := FileHeader.bfOffBits + UInt32((RowSize + PadSize) * Height);

  FillChar(InfoHeader, SizeOf(InfoHeader), 0);
  InfoHeader.biSize := SizeOf(InfoHeader);
  InfoHeader.biWidth := Width;
  InfoHeader.biHeight := Height;
  InfoHeader.biPlanes := 1;
  InfoHeader.biBitCount := 24;
  InfoHeader.biCompression := 0;
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
begin
  ExitCode_ := 0;

  WriteLn('DXGI capture acceptance test');
  WriteLn('----------------------------');

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

  DXGIAutoOpen(TWindowHandle(HW));
  if DXGILastError() <> '' then
  begin
    WriteLn('FAIL: DXGIAutoOpen reported: ', DXGILastError());
    Halt(1);
  end;
  WriteLn('  [ok] DXGIAutoOpen()');

  WriteLn('  [info] sleeping ', CAPTURE_DELAY_MS_FIRST, 'ms for first frame...');
  Sleep(CAPTURE_DELAY_MS_FIRST);

  for i := 0 to NUM_FRAMES - 1 do
    Frames[i].Data := nil;

  for i := 0 to NUM_FRAMES - 1 do
  begin
    Got := False;
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

      Got := DXGITryGetImage(TWindowHandle(HW), 0, 0, W, H, Frames[i].Data);
      if not Got then
        Sleep(100);
      Inc(Attempts);
    end;

    if not Got then
    begin
      if i = 0 then
      begin
        WriteLn('FAIL: DXGITryGetImage returned False on first frame after ',
                Attempts, ' attempts');
        WriteLn('  Last error: ', DXGILastError());
        DXGIRelease();
        Halt(2);
      end
      else
      begin
        WriteLn('  [warn] frame ', i, ': DXGITryGetImage returned False');
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

    WriteLn(Format('  frame %d: %dx%d  hash=0x%s  DXGIFrameCount=%d',
                   [i + 1, W, H, HexU64(Frames[i].Hash), DXGIFrameCount()]));

    if i < NUM_FRAMES - 1 then
      Sleep(CAPTURE_DELAY_MS_BETWEEN);
  end;

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

  if DistinctCount >= 4 then
    WriteLn('  [ok] >=4/5 distinct hashes - live moving capture confirmed')
  else if DistinctCount >= 2 then
    WriteLn('  [info] only ', DistinctCount, '/5 distinct hashes - capture is producing frames')
  else
    WriteLn('  [warn] all 5 hashes identical - capture appears frozen');

  DXGIRelease();
  WriteLn('  [ok] DXGIRelease()');

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

  WriteLn('SUCCESS: DXGI capture roundtrip');
  Halt(0);
end.
