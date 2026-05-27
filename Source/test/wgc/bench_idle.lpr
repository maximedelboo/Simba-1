{
  Idle-CPU benchmark for the WGC FrameArrived idle-skip optimization.

  Opens a WGC capture session against the given (or foreground) window,
  then sits idle for IDLE_SECONDS without calling WGCTryGetImageInto.
  Measures the CPU time consumed by the current process (user + kernel,
  summed across all process threads — covers the WinRT thread-pool
  thread running FrameArrived) over that idle window via GetProcessTimes.

  After idle, does a quick "resume sanity check": captures one frame,
  sleeps ~50ms, captures another, hashes both, and reports whether
  they differ. For an animating target (Task Manager updating once
  per second) the second post-idle hash should differ from the first
  if the stage-and-deliver loop has properly resumed.

  Also reports WGCFrameCount and WGCFrameSkippedCount before/after
  the idle window. With the optimization enabled, FrameSkippedCount
  should climb to roughly IDLE_SECONDS * 60Hz (the DWM compose rate)
  while FrameCount stays mostly flat (modulo the 1-2 frames that fire
  before the timestamp goes stale, plus the resume frame after the
  active touch).

  Build:
    "/c/fpcup/lazarus/lazbuild.exe" --build-mode=Default bench_idle.lpi

  Run:
    ./bench_idle.exe <HWND-in-hex-or-decimal>
    ./bench_idle.exe                # uses foreground window
}
program bench_idle;

{$mode objfpc}{$H+}

uses
  Interfaces, SysUtils, Windows, Classes,
  simba.base, simba.capture_wgc;

const
  IDLE_SECONDS = 5;
  RESUME_SLEEP_MS = 80;   // > one DWM cycle, so the resume-staging
                          // frame has time to land

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

// Convert a Windows FILETIME (100ns ticks since 1601) to a 64-bit
// 100ns-tick count.
function FileTimeToTicks(const FT: Windows.TFileTime): UInt64; inline;
begin
  Result := (UInt64(FT.dwHighDateTime) shl 32) or UInt64(FT.dwLowDateTime);
end;

// Sum (UserTime + KernelTime) across the calling process. Returns
// 100ns ticks since process start.
function ProcessCPUTicks(): UInt64;
var
  Created, Exited, Kernel, User: Windows.TFileTime;
begin
  Result := 0;
  if GetProcessTimes(GetCurrentProcess(), Created, Exited, Kernel, User) then
    Result := FileTimeToTicks(Kernel) + FileTimeToTicks(User);
end;

// FNV-1a 64-bit (same as test_wgc_capture).
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

var
  HW: HWND;
  WindowRect: Windows.TRect;
  W, H: Integer;
  ByteSize: PtrUInt;
  TicksBefore, TicksAfter: UInt64;
  IdleCpuMs: Double;
  WallStart: UInt64;
  WallElapsedMs: Double;
  FramesBefore, FramesAfter: Int64;
  SkippedBefore, SkippedAfter: Int64;
  Dst1, Dst2: PColorBGRA;
  Hash1, Hash2: UInt64;
  Got: Boolean;
  Attempt: Integer;
begin
  if ParamCount >= 1 then
  begin
    HW := ParseHWND(ParamStr(1));
    if HW = 0 then
      HW := GetForegroundWindow();
  end
  else
    HW := GetForegroundWindow();

  if (HW = 0) or (not IsWindow(HW)) then
  begin
    WriteLn('FAIL: no valid HWND');
    Halt(1);
  end;

  if not GetWindowRect(HW, @WindowRect) then
  begin
    WriteLn('FAIL: GetWindowRect');
    Halt(1);
  end;
  W := WindowRect.Right - WindowRect.Left;
  H := WindowRect.Bottom - WindowRect.Top;
  if (W <= 0) or (H <= 0) then
  begin
    WriteLn('FAIL: bad rect');
    Halt(1);
  end;

  WriteLn('Idle-CPU benchmark for WGC FrameArrived idle-skip');
  WriteLn('-------------------------------------------------');
  WriteLn('  HWND        : ', HW);
  WriteLn('  rect        : ', W, 'x', H);
  WriteLn('  idle window : ', IDLE_SECONDS, ' seconds');

  WGCAutoOpen(TWindowHandle(HW));
  if WGCLastError() <> '' then
  begin
    WriteLn('FAIL: WGCAutoOpen: ', WGCLastError());
    Halt(2);
  end;

  ByteSize := PtrUInt(W) * PtrUInt(H) * SizeOf(TColorBGRA);

  // Prime the pipeline with reads until a frame is captured. With the
  // idle-skip optimization enabled, the very first call after WGCAutoOpen
  // returns False (no frame has been staged yet — staging only starts
  // after the timestamp gets bumped). The retry loop handles that:
  //   - call 1 sets the timestamp, returns False
  //   - next FrameArrived (within ~16ms) stages
  //   - call 2 succeeds
  Dst1 := GetMem(ByteSize);
  Got := False;
  for Attempt := 1 to 20 do
  begin
    Sleep(50);
    Got := WGCTryGetImageInto(TWindowHandle(HW), 0, 0, W, H, Dst1, W);
    if Got then break;
  end;
  if not Got then
  begin
    WriteLn('FAIL: priming WGCTryGetImageInto failed after 20 attempts');
    FreeMem(Dst1);
    WGCRelease();
    Halt(3);
  end;
  WriteLn('  [info] pipeline primed; first frame captured');

  // Allow the staging-deliver loop to fully settle before we start
  // measuring idle. (A handful of FrameArrived calls happen in the
  // ~50ms after the touch before the timestamp goes stale.)
  Sleep(400);

  // ===== IDLE WINDOW =====
  FramesBefore  := WGCFrameCount();
  SkippedBefore := WGCFrameSkippedCount();
  TicksBefore   := ProcessCPUTicks();
  WallStart     := GetTickCount64();

  WriteLn('  [info] entering ', IDLE_SECONDS, 's idle period - no consumer calls...');
  Sleep(IDLE_SECONDS * 1000);

  TicksAfter    := ProcessCPUTicks();
  WallElapsedMs := (GetTickCount64() - WallStart);
  FramesAfter   := WGCFrameCount();
  SkippedAfter  := WGCFrameSkippedCount();

  // 100ns ticks -> milliseconds.
  IdleCpuMs := (TicksAfter - TicksBefore) / 10000.0;

  WriteLn(Format('  [result] wall-clock idle  : %8.1f ms', [WallElapsedMs]));
  WriteLn(Format('  [result] process CPU used : %8.3f ms', [IdleCpuMs]));
  WriteLn(Format('  [result] CPU%% during idle : %8.3f%% of one core',
                 [(IdleCpuMs / WallElapsedMs) * 100.0]));
  WriteLn(Format('  [result] FrameCount delta : %d (staging done)', [FramesAfter - FramesBefore]));
  WriteLn(Format('  [result] SkippedCount delta: %d (idle-skip taken)',
                 [SkippedAfter - SkippedBefore]));

  // ===== RESUME SANITY CHECK =====
  WriteLn('  [info] resume sanity check (post-idle freshness)...');
  Dst2 := GetMem(ByteSize);

  // First post-idle call: returns stale frame from before the idle period.
  Got := WGCTryGetImageInto(TWindowHandle(HW), 0, 0, W, H, Dst1, W);
  if not Got then
  begin
    WriteLn('FAIL: first post-idle WGCTryGetImageInto failed');
    FreeMem(Dst1); FreeMem(Dst2);
    WGCRelease();
    Halt(4);
  end;
  Hash1 := FNV1a64(PByte(Dst1), ByteSize);
  WriteLn(Format('  [info] post-idle frame #1 hash: 0x%s (stale - last active frame)',
                 [IntToHex(Hash1, 16)]));

  // Wait for the next FrameArrived (which sees the touch from the call
  // above and resumes staging).
  Sleep(RESUME_SLEEP_MS);

  Got := WGCTryGetImageInto(TWindowHandle(HW), 0, 0, W, H, Dst2, W);
  if not Got then
  begin
    WriteLn('FAIL: second post-idle WGCTryGetImageInto failed');
    FreeMem(Dst1); FreeMem(Dst2);
    WGCRelease();
    Halt(4);
  end;
  Hash2 := FNV1a64(PByte(Dst2), ByteSize);
  WriteLn(Format('  [info] post-idle frame #2 hash: 0x%s (after %dms - should be fresh)',
                 [IntToHex(Hash2, 16), RESUME_SLEEP_MS]));

  if Hash1 = Hash2 then
    WriteLn('  [warn] hashes match - target may not be animating, or resume did not engage')
  else
    WriteLn('  [ok] hashes differ - stage-and-deliver loop resumed correctly');

  FreeMem(Dst1);
  FreeMem(Dst2);
  WGCRelease();

  WriteLn('DONE');
  Halt(0);
end.
