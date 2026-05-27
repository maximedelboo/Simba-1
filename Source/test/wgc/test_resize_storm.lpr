{
  Stress test: resize-storm-during-capture.

  Spawns Notepad, opens a WGC session against it, kicks off a
  background thread that resizes the Notepad window every ~20ms
  cycling through {300x200, 800x600, 1200x900, 600x400} for 3
  seconds. Meanwhile the main thread hammers WGCTryGetImageInto
  in a tight loop with no delay. Counts successes, failures,
  and distinct frame hashes (sampled from up to 50 successes).

  What this verifies in simba.capture_wgc.pas:

    - The staging-texture recreation path in
      TFrameArrivedHandler.Invoke (when texDesc.Width/Height
      changes) is race-safe against concurrent WGCTryGetImageInto
      reads. The handler holds GCaptureLock around the
      CreateTexture2D + CopyResource + Map + memcpy sequence; the
      reader takes GFrameBufferLock around the memcpy. Both touch
      GFrameBuffer / GFrameBufferWidth / GFrameBufferHeight only
      under GFrameBufferLock, so a reader can never see a
      buffer-size/contents tear.

    - SetLength(GFrameBuffer, ...) inside the handler does not
      invalidate a pointer a reader is mid-Move() with. The
      reader's Move() runs entirely INSIDE GFrameBufferLock, so
      the handler cannot reach its SetLength until the reader
      finishes.

    - W, H, and the buffer pointer are read+used atomically under
      one GFrameBufferLock acquisition by the reader (the bounds
      check and the row-copy loop happen back-to-back inside the
      same critical section).

    - The old staging texture released cleanly when the new one is
      created (GStagingTexture := nil; before re-assignment lets
      the interface refcount drop to zero and FreeTexture runs).

    - No memory corruption when dimensions transition. If the
      mutex ordering is wrong, this test will AV under load.

  Pass criteria:
    - Test runs to completion without raising an exception
    - At least one successful capture
    - At least 2 distinct frame hashes during the storm (proves
      live capture survived the resizes)
    - Final post-storm capture is valid at the last size

  Exit codes:
    0 = SUCCESS
    1 = could not spawn Notepad / find HWND
    2 = WGCAutoOpen failed
    3 = main-loop or resize-thread raised an exception
    4 = zero successful captures during the 3s storm
    5 = only one (or zero) distinct hashes - capture froze
    6 = post-storm capture failed
    7 = post-storm BMP write failed

  Build:
    "/c/fpcup/lazarus/lazbuild.exe" --build-mode=Default test_resize_storm.lpi

  Run:
    ./test_resize_storm.exe
}
program test_resize_storm;

{$mode objfpc}{$H+}

uses
  Interfaces,
  SysUtils, Windows, Classes,
  simba.base, simba.capture_wgc;

const
  STORM_DURATION_MS = 3000;
  RESIZE_PERIOD_MS  = 20;
  MAX_HASH_SAMPLES  = 50;
  NOTEPAD_WAIT_TIMEOUT_MS = 5000;
  POST_OPEN_SLEEP_MS = 400;

type
  TSize2 = record W, H: Integer end;

const
  RESIZE_SIZES: array[0..3] of TSize2 = (
    (W: 300;  H: 200),
    (W: 800;  H: 600),
    (W: 1200; H: 900),
    (W: 600;  H: 400)
  );

// ===== Shared FNV-1a =====
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

// ===== Notepad spawn (same pattern as test_window_close) =====
type
  TSpawnedProcess = record
    ProcInfo: TProcessInformation;
    Window:   HWND;
  end;

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
    Result := False;
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

  CmdLine := 'notepad.exe';
  if not CreateProcessW(
    nil, PWideChar(CmdLine),
    nil, nil, False,
    CREATE_NEW_CONSOLE,
    nil, nil,
    StartInfo, Spawn.ProcInfo) then
    Exit;

  WaitForInputIdle(Spawn.ProcInfo.hProcess, NOTEPAD_WAIT_TIMEOUT_MS);

  Deadline := GetTickCount64() + NOTEPAD_WAIT_TIMEOUT_MS;
  repeat
    Spawn.Window := FindWindowByPid(Spawn.ProcInfo.dwProcessId);
    if Spawn.Window <> 0 then Break;
    Sleep(50);
  until GetTickCount64() >= Deadline;

  Result := Spawn.Window <> 0;
end;

procedure KillProcess(const PI: TProcessInformation);
begin
  TerminateProcess(PI.hProcess, 1);
  WaitForSingleObject(PI.hProcess, 2000);
  CloseHandle(PI.hThread);
  CloseHandle(PI.hProcess);
end;

// ===== 24-bit BGR BMP writer (same as other tests) =====
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

// ===== Background resize thread =====
//
// Cycles through RESIZE_SIZES, calling SetWindowPos on the target every
// ~RESIZE_PERIOD_MS. Atomic Stop flag, no shared mutable state with the
// main thread except the HWND (which doesn't change) and the
// thread-safe SetWindowPos itself.
type
  TResizeThread = class(TThread)
  private
    FWindow:        HWND;
    FStopRequested: LongBool;
    FResizes:       Int64;
    FLastException: String;
  protected
    procedure Execute; override;
  public
    constructor Create(AWindow: HWND);
    procedure RequestStop;
    property Resizes: Int64 read FResizes;
    property LastException: String read FLastException;
  end;

constructor TResizeThread.Create(AWindow: HWND);
begin
  inherited Create(True); // suspended
  FWindow := AWindow;
  FStopRequested := False;
  FResizes := 0;
  FLastException := '';
  FreeOnTerminate := False;
end;

procedure TResizeThread.RequestStop;
begin
  InterlockedExchange(LongInt(FStopRequested), Ord(True));
end;

procedure TResizeThread.Execute;
var
  Idx: Integer;
  Sz: TSize2;
begin
  Idx := 0;
  try
    while not FStopRequested do
    begin
      Sz := RESIZE_SIZES[Idx mod Length(RESIZE_SIZES)];
      // SWP_NOMOVE keeps current position; SWP_NOZORDER avoids Z-order
      // ping-pong; SWP_ASYNCWINDOWPOS posts the message rather than
      // blocking so the resize thread can keep firing every 20ms even
      // if the window's owning thread is briefly busy.
      SetWindowPos(FWindow, 0, 0, 0, Sz.W, Sz.H,
                   SWP_NOMOVE or SWP_NOZORDER or SWP_NOACTIVATE or SWP_ASYNCWINDOWPOS);
      Inc(FResizes);
      Inc(Idx);
      Sleep(RESIZE_PERIOD_MS);
    end;
  except
    on E: Exception do
      FLastException := E.ClassName + ': ' + E.Message;
  end;
end;

// ===== Hash sample tracking =====
//
// Tiny linear-probe set that records up to MAX_HASH_SAMPLES distinct
// hashes. We don't care about the exact total of distinct hashes
// (could be hundreds during the storm); we just want to confirm "more
// than 1" - i.e. the capture wasn't frozen on one stale frame.
type
  THashSet = record
    Items: array[0..MAX_HASH_SAMPLES - 1] of UInt64;
    Count: Integer;
  end;

procedure HashSetInit(out S: THashSet);
begin
  S.Count := 0;
end;

procedure HashSetAdd(var S: THashSet; H: UInt64);
var
  i: Integer;
begin
  for i := 0 to S.Count - 1 do
    if S.Items[i] = H then Exit;
  if S.Count >= MAX_HASH_SAMPLES then Exit;
  S.Items[S.Count] := H;
  Inc(S.Count);
end;

// ===== main =====
var
  Spawn: TSpawnedProcess;
  Resizer: TResizeThread;
  CaptureBuf: PColorBGRA;
  CaptureCap: PtrUInt;
  Successes, Failures: Int64;
  HashSamples: Int64;
  HashSet: THashSet;
  Got: Boolean;
  StormStart, NowMs: UInt64;
  WindowRect: Windows.TRect;
  W, H: Integer;
  ByteSize: PtrUInt;
  HashThis: UInt64;
  CapAttempts: Integer;
  BMPPath: String;
  FinalW, FinalH: Integer;
  MainException: String;
begin
  WriteLn('WGC stress test: resize-storm-during-capture');
  WriteLn('--------------------------------------------');

  // ===== STEP 1: Spawn Notepad =====
  if not SpawnNotepad(Spawn) then
  begin
    WriteLn('FAIL: could not spawn Notepad');
    Halt(1);
  end;
  WriteLn(Format('  [info] spawned Notepad pid=%d hwnd=0x%x',
                 [Spawn.ProcInfo.dwProcessId, Spawn.Window]));

  // ===== STEP 2: WGCAutoOpen =====
  WGCAutoOpen(TWindowHandle(Spawn.Window));
  if WGCLastError() <> '' then
  begin
    WriteLn('FAIL: WGCAutoOpen: ', WGCLastError());
    KillProcess(Spawn.ProcInfo);
    Halt(2);
  end;
  WriteLn('  [ok] WGCAutoOpen');

  Sleep(POST_OPEN_SLEEP_MS);

  // Pre-allocate a reader buffer big enough for the LARGEST resize
  // size + a generous safety margin (frames can be slightly larger
  // than the client area due to titlebars / DPI). We re-query the
  // current window rect every iteration but the buffer never shrinks.
  CaptureCap := PtrUInt(2000) * PtrUInt(1400) * SizeOf(TColorBGRA);
  CaptureBuf := GetMem(CaptureCap);
  Successes := 0;
  Failures := 0;
  HashSamples := 0;
  HashSetInit(HashSet);
  MainException := '';

  // ===== STEP 3: Spin up resize thread =====
  Resizer := TResizeThread.Create(Spawn.Window);
  Resizer.Start;
  WriteLn('  [info] resize thread started (cycling through ',
          Length(RESIZE_SIZES), ' sizes every ', RESIZE_PERIOD_MS, 'ms)');

  // ===== STEP 4: Hammer WGCTryGetImageInto for STORM_DURATION_MS =====
  StormStart := GetTickCount64();
  try
    repeat
      NowMs := GetTickCount64();
      if (NowMs - StormStart) >= STORM_DURATION_MS then Break;

      // Re-read current window size every iteration. The window can be
      // ANY of the cycle sizes right now. We try GetWindowRect; if it
      // returns junk we fall back to the smallest configured size.
      if GetWindowRect(Spawn.Window, @WindowRect) then
      begin
        W := WindowRect.Right - WindowRect.Left;
        H := WindowRect.Bottom - WindowRect.Top;
      end
      else
      begin
        W := RESIZE_SIZES[0].W;
        H := RESIZE_SIZES[0].H;
      end;
      if W < 1 then W := 1;
      if H < 1 then H := 1;

      // Defensive: clamp to our buffer's capacity. If somebody manually
      // dragged the window way bigger than our cycle, we still shouldn't
      // smash memory.
      ByteSize := PtrUInt(W) * PtrUInt(H) * SizeOf(TColorBGRA);
      if ByteSize > CaptureCap then
      begin
        Inc(Failures); // skip oversize iterations
        Continue;
      end;

      Got := WGCTryGetImageInto(TWindowHandle(Spawn.Window),
                                0, 0, W, H, CaptureBuf, W);
      if Got then
      begin
        Inc(Successes);
        // Sample at most MAX_HASH_SAMPLES hashes - hashing every frame
        // would dominate the run time and bias the success/failure ratio.
        if HashSamples < MAX_HASH_SAMPLES then
        begin
          HashThis := FNV1a64(PByte(CaptureBuf), ByteSize);
          HashSetAdd(HashSet, HashThis);
          Inc(HashSamples);
        end;
      end
      else
        Inc(Failures);
    until False;
  except
    on E: Exception do
    begin
      MainException := E.ClassName + ': ' + E.Message;
      WriteLn('FAIL: exception during storm: ', MainException);
    end;
  end;

  // ===== STEP 5: Stop resize thread =====
  Resizer.RequestStop;
  Resizer.WaitFor;
  WriteLn(Format('  [info] resize thread fired %d SetWindowPos calls',
                 [Resizer.Resizes]));
  if Resizer.LastException <> '' then
    WriteLn('  [warn] resize thread reported: ', Resizer.LastException);
  Resizer.Free;

  WriteLn(Format('  [stats] storm duration: %dms', [STORM_DURATION_MS]));
  WriteLn(Format('  [stats] total calls   : %d', [Successes + Failures]));
  WriteLn(Format('  [stats] successes     : %d', [Successes]));
  WriteLn(Format('  [stats] failures      : %d', [Failures]));
  WriteLn(Format('  [stats] hash samples  : %d', [HashSamples]));
  WriteLn(Format('  [stats] distinct hashes: %d', [HashSet.Count]));
  WriteLn(Format('  [stats] WGCFrameCount : %d', [WGCFrameCount()]));
  WriteLn(Format('  [stats] WGCSkipped    : %d', [WGCFrameSkippedCount()]));

  // ===== STEP 6: pass/fail gates =====
  if MainException <> '' then
  begin
    FreeMem(CaptureBuf);
    WGCRelease();
    KillProcess(Spawn.ProcInfo);
    Halt(3);
  end;

  if Successes = 0 then
  begin
    WriteLn('FAIL: zero successful captures during storm');
    FreeMem(CaptureBuf);
    WGCRelease();
    KillProcess(Spawn.ProcInfo);
    Halt(4);
  end;

  if HashSet.Count < 2 then
  begin
    WriteLn('FAIL: only ', HashSet.Count, ' distinct hash(es) - capture appears frozen');
    FreeMem(CaptureBuf);
    WGCRelease();
    KillProcess(Spawn.ProcInfo);
    Halt(5);
  end;

  // ===== STEP 7: Post-storm verification - capture one frame at the
  //              last set size and save it. =====
  // The resize thread's last action set the window to whatever size
  // came up next in the cycle. Wait a beat for that final resize to
  // settle and FrameArrived to deliver a frame at the new size.
  Sleep(200);

  if not GetWindowRect(Spawn.Window, @WindowRect) then
  begin
    WriteLn('FAIL: post-storm GetWindowRect failed');
    FreeMem(CaptureBuf);
    WGCRelease();
    KillProcess(Spawn.ProcInfo);
    Halt(6);
  end;
  FinalW := WindowRect.Right - WindowRect.Left;
  FinalH := WindowRect.Bottom - WindowRect.Top;
  if FinalW < 1 then FinalW := 1;
  if FinalH < 1 then FinalH := 1;

  Got := False;
  CapAttempts := 0;
  while (not Got) and (CapAttempts < 20) do
  begin
    Got := WGCTryGetImageInto(TWindowHandle(Spawn.Window),
                              0, 0, FinalW, FinalH, CaptureBuf, FinalW);
    if not Got then
      Sleep(50);
    Inc(CapAttempts);
  end;

  if not Got then
  begin
    WriteLn('FAIL: post-storm WGCTryGetImageInto failed after ',
            CapAttempts, ' attempts');
    FreeMem(CaptureBuf);
    WGCRelease();
    KillProcess(Spawn.ProcInfo);
    Halt(6);
  end;
  WriteLn(Format('  [ok] post-storm capture %dx%d after %d attempt(s)',
                 [FinalW, FinalH, CapAttempts]));

  BMPPath := ExtractFilePath(ParamStr(0)) + 'frame_resize_storm_final.bmp';
  if not WriteBMP(BMPPath, CaptureBuf, FinalW, FinalH) then
  begin
    WriteLn('FAIL: post-storm BMP write to ', BMPPath);
    FreeMem(CaptureBuf);
    WGCRelease();
    KillProcess(Spawn.ProcInfo);
    Halt(7);
  end;
  WriteLn('  [ok] wrote post-storm frame to ', BMPPath);

  // ===== STEP 8: cleanup =====
  FreeMem(CaptureBuf);
  WGCRelease();
  KillProcess(Spawn.ProcInfo);

  WriteLn('SUCCESS: resize-storm-during-capture stress test passed');
  Halt(0);
end.
