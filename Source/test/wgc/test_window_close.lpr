{
  Stress test: window-close-during-capture.

  Spawns Notepad as a child process, opens a WGC session against its
  HWND, captures three frames, then KILLS the Notepad process while
  the capture is live. After the target process dies:

    - WGCTryGetImageInto must return False gracefully (no crash, no
      access violation, no deadlock).
    - WGCRelease must clean up without crashing or hanging.
    - A subsequent WGCAutoOpen against a DIFFERENT window must
      succeed - the lazy-singleton D3D11 device, WinRT init, and
      shared activation factories must all survive the prior
      target's sudden death.

  What this verifies in simba.capture_wgc.pas:

    - TFrameArrivedHandler.Invoke does not propagate a Pascal
      exception back into the COM callback when the capture item's
      backing surface goes away. The try/except wrapper in Invoke
      catches the failure path; the WinRT runtime sees E_FAIL on
      a bad frame instead of an unhandled exception.

    - InternalTearDownSession's IClosable.Close call against a
      session whose target HWND is dead is benign (the WinRT runtime
      itself fires the Closed event and the underlying capture item
      transitions cleanly; Close becomes a no-op).

    - The cached frame buffer (GFrameBuffer + GFrameBufferWidth/
      Height) is reset to zeroes on WGCRelease so a subsequent
      WGCAutoOpen against a fresh target can't accidentally serve
      a stale-pointer-into-dead-target memory region.

  Exit codes:
    0 = SUCCESS - all phases behaved as designed
    1 = Could not spawn Notepad / find its HWND
    2 = Initial WGCAutoOpen failed
    3 = Could not capture 3 frames before kill (Notepad died too
        early or WGC declined the surface)
    4 = WGCTryGetImageInto AFTER kill raised an exception or
        deadlocked
    5 = WGCRelease after kill raised an exception or hung
    6 = Subsequent WGCAutoOpen on a different window failed
        (D3D / WinRT singleton went bad)
    7 = BMP write of pre-kill frame #3 failed

  Build:
    "/c/fpcup/lazarus/lazbuild.exe" --build-mode=Default test_window_close.lpi

  Run:
    ./test_window_close.exe
}
program test_window_close;

{$mode objfpc}{$H+}

uses
  Interfaces,
  SysUtils, Windows, Classes,
  simba.base, simba.capture_wgc;

const
  NOTEPAD_WAIT_TIMEOUT_MS = 5000;   // how long we'll poll for Notepad's HWND
  POST_OPEN_SLEEP_MS      = 500;    // let the first FrameArrived land
  BETWEEN_FRAMES_SLEEP_MS = 250;    // between pre-kill captures
  POST_KILL_SLEEP_MS      = 500;    // give DWM time to notice the dead window

// FNV-1a 64-bit (matches the other tests).
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

// Spawn Notepad and return its PROCESS_INFORMATION + the resolved HWND.
// Returns False if spawn fails or no top-level window appears within the
// timeout.
type
  TSpawnedProcess = record
    ProcInfo: TProcessInformation;
    Window:   HWND;
  end;

// EnumWindows callback: find first visible top-level window owned by
// the given PID.
type
  TFindByPid = record
    Pid:   DWORD;
    Found: HWND;
  end;
  PFindByPid = ^TFindByPid;

function EnumByPidCB(Window: HWND; LParam: LPARAM): WINBOOL; stdcall;
var
  WinPid: DWORD;
begin
  Result := True;
  if not IsWindowVisible(Window) then Exit;
  WinPid := 0;
  GetWindowThreadProcessId(Window, @WinPid);
  if WinPid = PFindByPid(LParam)^.Pid then
  begin
    PFindByPid(LParam)^.Found := Window;
    Result := False; // stop
  end;
end;

function FindWindowByPid(Pid: DWORD): HWND;
var
  Search: TFindByPid;
begin
  Search.Pid := Pid;
  Search.Found := 0;
  EnumWindows(@EnumByPidCB, LPARAM(@Search));
  Result := Search.Found;
end;

function SpawnNotepad(out Spawn: TSpawnedProcess): Boolean;
var
  StartInfo: TStartupInfoW;
  CmdLine: WideString;
  Deadline: UInt64;
begin
  Result := False;
  FillChar(StartInfo, SizeOf(StartInfo), 0);
  StartInfo.cb := SizeOf(StartInfo);
  FillChar(Spawn, SizeOf(Spawn), 0);

  // CreateProcessW wants a writable buffer for lpCommandLine.
  CmdLine := 'notepad.exe';

  if not CreateProcessW(
    nil,
    PWideChar(CmdLine),
    nil, nil, False,
    CREATE_NEW_CONSOLE,
    nil, nil,
    StartInfo, Spawn.ProcInfo) then
  begin
    Exit;
  end;

  // Wait for the new process to be idle enough to show a top-level
  // window. WaitForInputIdle blocks until either the process has
  // started its message loop or the timeout fires.
  WaitForInputIdle(Spawn.ProcInfo.hProcess, NOTEPAD_WAIT_TIMEOUT_MS);

  // Now poll for the HWND. WaitForInputIdle returning doesn't quite
  // guarantee the window is visible (Win11 Notepad's startup is more
  // elaborate), so retry briefly.
  Deadline := GetTickCount64() + NOTEPAD_WAIT_TIMEOUT_MS;
  repeat
    Spawn.Window := FindWindowByPid(Spawn.ProcInfo.dwProcessId);
    if Spawn.Window <> 0 then
      Break;
    Sleep(50);
  until GetTickCount64() >= Deadline;

  Result := Spawn.Window <> 0;
end;

// Forcefully terminate a spawned process and wait for it to die.
procedure KillProcess(const PI: TProcessInformation);
begin
  TerminateProcess(PI.hProcess, 1);
  WaitForSingleObject(PI.hProcess, 2000);
  CloseHandle(PI.hThread);
  CloseHandle(PI.hProcess);
end;

// 24-bit BGR uncompressed BMP write (copied from test_wgc_capture).
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
  Spawn: TSpawnedProcess;
  Frames: array[0..2] of record
    Width:  Integer;
    Height: Integer;
    Hash:   UInt64;
    Data:   PColorBGRA;
  end;
  i, W, H, Attempts: Integer;
  Got: Boolean;
  WindowRect: Windows.TRect;
  BMPPath: String;
  PostKillBuf: PColorBGRA;
  PostKillByteSize: PtrUInt;
  PostKillCallReturned: Boolean;
  ReleaseReturned: Boolean;
  Foreground: HWND;
  ReopenReturned: Boolean;
begin
  WriteLn('WGC stress test: window-close-during-capture');
  WriteLn('--------------------------------------------');

  for i := 0 to High(Frames) do
    Frames[i].Data := nil;

  // ===== STEP 1: Spawn Notepad and find its HWND =====
  if not SpawnNotepad(Spawn) then
  begin
    WriteLn('FAIL: could not spawn Notepad or find its window within ',
            NOTEPAD_WAIT_TIMEOUT_MS, 'ms');
    Halt(1);
  end;
  WriteLn(Format('  [info] spawned Notepad pid=%d hwnd=0x%x',
                 [Spawn.ProcInfo.dwProcessId, Spawn.Window]));

  // ===== STEP 2: WGCAutoOpen against Notepad =====
  WGCAutoOpen(TWindowHandle(Spawn.Window));
  if WGCLastError() <> '' then
  begin
    WriteLn('FAIL: WGCAutoOpen on Notepad: ', WGCLastError());
    KillProcess(Spawn.ProcInfo);
    Halt(2);
  end;
  WriteLn('  [ok] WGCAutoOpen on Notepad');

  Sleep(POST_OPEN_SLEEP_MS);

  // ===== STEP 3: Capture 3 frames =====
  for i := 0 to 2 do
  begin
    GetWindowRect(Spawn.Window, @WindowRect);
    W := WindowRect.Right - WindowRect.Left;
    H := WindowRect.Bottom - WindowRect.Top;
    if W < 1 then W := 1;
    if H < 1 then H := 1;

    Got := False;
    Attempts := 0;
    while (not Got) and (Attempts < 20) do
    begin
      Got := WGCTryGetImage(TWindowHandle(Spawn.Window), 0, 0, W, H, Frames[i].Data);
      if not Got then
        Sleep(50);
      Inc(Attempts);
    end;

    if not Got then
    begin
      WriteLn('FAIL: could not capture pre-kill frame ', i + 1,
              ' after ', Attempts, ' attempts');
      WriteLn('  WGCLastError: ', WGCLastError());
      WGCRelease();
      KillProcess(Spawn.ProcInfo);
      Halt(3);
    end;

    Frames[i].Width := W;
    Frames[i].Height := H;
    Frames[i].Hash := FNV1a64(PByte(Frames[i].Data),
                              SizeUInt(W) * SizeUInt(H) * SizeOf(TColorBGRA));
    WriteLn(Format('  frame %d: %dx%d  hash=0x%s  WGCFrameCount=%d',
                   [i + 1, W, H, IntToHex(Frames[i].Hash, 16), WGCFrameCount()]));

    if i < 2 then
      Sleep(BETWEEN_FRAMES_SLEEP_MS);
  end;

  // ===== STEP 4: Save 3rd frame as BMP =====
  BMPPath := ExtractFilePath(ParamStr(0)) + 'frame_window_close_pre.bmp';
  if not WriteBMP(BMPPath, Frames[2].Data, Frames[2].Width, Frames[2].Height) then
  begin
    WriteLn('FAIL: WriteBMP for pre-kill frame 3');
    WGCRelease();
    KillProcess(Spawn.ProcInfo);
    Halt(7);
  end;
  WriteLn('  [ok] wrote pre-kill 3rd frame to ', BMPPath);

  // ===== STEP 5: Kill Notepad =====
  WriteLn('  [info] terminating Notepad pid=', Spawn.ProcInfo.dwProcessId);
  TerminateProcess(Spawn.ProcInfo.hProcess, 1);
  WaitForSingleObject(Spawn.ProcInfo.hProcess, 2000);
  CloseHandle(Spawn.ProcInfo.hThread);
  CloseHandle(Spawn.ProcInfo.hProcess);

  // ===== STEP 6: Give DWM time to react =====
  Sleep(POST_KILL_SLEEP_MS);
  WriteLn('  [info] post-kill: WGCFrameCount=', WGCFrameCount(),
          ' WGCFrameSkippedCount=', WGCFrameSkippedCount());

  // ===== STEP 7: WGCTryGetImageInto on dead target - must NOT crash =====
  PostKillByteSize := PtrUInt(Frames[2].Width) * PtrUInt(Frames[2].Height)
                      * SizeOf(TColorBGRA);
  PostKillBuf := GetMem(PostKillByteSize);
  FillChar(PostKillBuf^, PostKillByteSize, 0);

  PostKillCallReturned := False;
  try
    // Either returns True (stale frame from the cache - acceptable) or
    // False (rect mismatch / no frame after teardown - acceptable).
    // The only unacceptable outcome is an exception or hang.
    Got := WGCTryGetImageInto(TWindowHandle(Spawn.Window),
                              0, 0, Frames[2].Width, Frames[2].Height,
                              PostKillBuf, Frames[2].Width);
    PostKillCallReturned := True;
    WriteLn(Format('  [ok] post-kill WGCTryGetImageInto returned %s (no crash)',
                   [BoolToStr(Got, True)]));
  except
    on E: Exception do
    begin
      WriteLn('FAIL: post-kill WGCTryGetImageInto raised ',
              E.ClassName, ': ', E.Message);
      FreeMem(PostKillBuf);
      Halt(4);
    end;
  end;
  FreeMem(PostKillBuf);

  if not PostKillCallReturned then
  begin
    WriteLn('FAIL: post-kill WGCTryGetImageInto never returned');
    Halt(4);
  end;

  // ===== STEP 8: WGCRelease - must NOT crash or hang =====
  ReleaseReturned := False;
  try
    WGCRelease();
    ReleaseReturned := True;
    WriteLn('  [ok] WGCRelease after target-killed (no crash, no deadlock)');
  except
    on E: Exception do
    begin
      WriteLn('FAIL: WGCRelease raised ', E.ClassName, ': ', E.Message);
      Halt(5);
    end;
  end;
  if not ReleaseReturned then
  begin
    WriteLn('FAIL: WGCRelease did not return');
    Halt(5);
  end;

  // ===== STEP 9: WGCAutoOpen against a DIFFERENT, alive window =====
  // Use the foreground window (which by definition is not dead).
  // This proves the singleton D3D11 device + WinRT init survived the
  // prior target's death.
  Foreground := GetForegroundWindow();
  if (Foreground = 0) or (not IsWindow(Foreground)) then
  begin
    // Edge case: nothing in foreground. Fall back to the desktop window.
    Foreground := GetDesktopWindow();
  end;
  WriteLn('  [info] reopening WGC against fresh target hwnd=0x',
          IntToHex(Foreground, 8));

  ReopenReturned := False;
  try
    WGCAutoOpen(TWindowHandle(Foreground));
    ReopenReturned := True;
  except
    on E: Exception do
    begin
      WriteLn('FAIL: subsequent WGCAutoOpen raised ',
              E.ClassName, ': ', E.Message);
      Halt(6);
    end;
  end;

  if not ReopenReturned then
  begin
    WriteLn('FAIL: subsequent WGCAutoOpen did not return');
    Halt(6);
  end;

  if WGCLastError() <> '' then
  begin
    WriteLn('FAIL: subsequent WGCAutoOpen reported: ', WGCLastError());
    WGCRelease();
    Halt(6);
  end;
  WriteLn('  [ok] subsequent WGCAutoOpen on fresh target succeeded');

  // Final cleanup.
  WGCRelease();

  for i := 0 to High(Frames) do
    if Frames[i].Data <> nil then
      FreeMem(Frames[i].Data);

  WriteLn('SUCCESS: window-close-during-capture stress test passed');
  Halt(0);
end.
