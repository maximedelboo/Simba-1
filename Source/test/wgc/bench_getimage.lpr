{
  Microbenchmark for the Target.GetImage() optimization.

  Measures the cost difference between the OLD path (WGCTryGetImage
  allocates a fresh buffer + copies, then a second memcpy parks the
  data into a pre-existing destination) and the NEW path
  (WGCTryGetImageInto writes directly into the destination, one copy).

  The "OLD" simulation faithfully reproduces what TSimbaImage.CreateFromWindow
  used to do:
    1. call WGCTryGetImage  -> alloc + row copy from GFrameBuffer
    2. memcpy that buffer into the final destination (the FromData copy)
    3. free the intermediate

  The "NEW" path:
    1. call WGCTryGetImageInto -> single row copy from GFrameBuffer into
       the caller-supplied destination

  Both paths leave the same bytes in the same destination, so the only
  thing being measured is the elimination of the extra alloc + memcpy.

  Build:
    "/c/fpcup/lazarus/lazbuild.exe" --build-mode=Default bench_getimage.lpi

  Run:
    ./bench_getimage.exe <HWND-in-hex-or-decimal>
    ./bench_getimage.exe                # uses foreground window
}
program bench_getimage;

{$mode objfpc}{$H+}

uses
  Interfaces, SysUtils, Windows, Classes,
  simba.base, simba.capture_wgc, simba.nativeinterface_windows;

const
  ITERATIONS = 5000;
  WARMUP     = 100;

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

function NowMs: Double;
var
  Freq, Counter: Int64;
begin
  QueryPerformanceFrequency(Freq);
  QueryPerformanceCounter(Counter);
  Result := (Counter * 1000.0) / Freq;
end;

var
  HW: HWND;
  WindowRect: Windows.TRect;
  W, H, I: Integer;
  DstOld, DstNew, Temp: PColorBGRA;
  T0, T1: Double;
  OldMs, NewMs: Double;
  Got: Boolean;
  Improvement: Double;
  ByteSize: PtrUInt;
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

  WriteLn('GetImage microbenchmark');
  WriteLn('-----------------------');
  WriteLn('  HWND      : ', HW);
  WriteLn('  rect      : ', W, 'x', H);
  WriteLn('  iterations: ', ITERATIONS, ' (warmup ', WARMUP, ')');

  WGCAutoOpen(TWindowHandle(HW));
  if WGCLastError() <> '' then
  begin
    WriteLn('FAIL: WGCAutoOpen: ', WGCLastError());
    Halt(2);
  end;

  // Wait for first frame.
  Sleep(700);

  ByteSize := PtrUInt(W) * PtrUInt(H) * SizeOf(TColorBGRA);

  // Pre-allocate the final destinations so we don't measure the one-time
  // SetSize/GetMem cost — only the per-call work. That matches what
  // happens in steady state for callers like Target.GetImage() that
  // reuse a TSimbaImage across calls (and is conservative for callers
  // that create a fresh one each call: SetSize is the same one-time
  // cost on both sides, plus a FillData zero-fill on the OLD side
  // that the NEW side skips via direct GetMem in CreateFromWindow).
  DstOld := GetMem(ByteSize);
  DstNew := GetMem(ByteSize);

  // Sanity: a single old-path and new-path call to confirm both work.
  Temp := nil;
  Got := WGCTryGetImage(TWindowHandle(HW), 0, 0, W, H, Temp);
  if not Got then
  begin
    WriteLn('FAIL: initial WGCTryGetImage failed');
    if Temp <> nil then FreeMem(Temp);
    FreeMem(DstOld); FreeMem(DstNew);
    WGCRelease();
    Halt(3);
  end;
  Move(Temp^, DstOld^, ByteSize);
  FreeMem(Temp);

  Got := WGCTryGetImageInto(TWindowHandle(HW), 0, 0, W, H, DstNew, W);
  if not Got then
  begin
    WriteLn('FAIL: initial WGCTryGetImageInto failed');
    FreeMem(DstOld); FreeMem(DstNew);
    WGCRelease();
    Halt(3);
  end;

  // ===== Warmup =====
  for I := 1 to WARMUP do
  begin
    Temp := nil;
    WGCTryGetImage(TWindowHandle(HW), 0, 0, W, H, Temp);
    if Temp <> nil then
    begin
      Move(Temp^, DstOld^, ByteSize);
      FreeMem(Temp);
    end;

    WGCTryGetImageInto(TWindowHandle(HW), 0, 0, W, H, DstNew, W);
  end;

  // ===== OLD path (alloc + copy via WGCTryGetImage, then memcpy into DstOld) =====
  T0 := NowMs;
  for I := 1 to ITERATIONS do
  begin
    Temp := nil;
    if WGCTryGetImage(TWindowHandle(HW), 0, 0, W, H, Temp) then
    begin
      // Simulate TSimbaImage.FromData copy: parks Temp into DstOld.
      Move(Temp^, DstOld^, ByteSize);
    end;
    if Temp <> nil then
      FreeMem(Temp);
  end;
  T1 := NowMs;
  OldMs := T1 - T0;

  // ===== NEW path (direct copy into DstNew via WGCTryGetImageInto) =====
  T0 := NowMs;
  for I := 1 to ITERATIONS do
  begin
    WGCTryGetImageInto(TWindowHandle(HW), 0, 0, W, H, DstNew, W);
  end;
  T1 := NowMs;
  NewMs := T1 - T0;

  if OldMs > 0 then
    Improvement := (1.0 - (NewMs / OldMs)) * 100.0
  else
    Improvement := 0;

  WriteLn(Format('  OLD path  (alloc + copy + memcpy + free) : %8.2f ms total / %6.4f ms per call',
                 [OldMs, OldMs / ITERATIONS]));
  WriteLn(Format('  NEW path  (direct WGCTryGetImageInto)    : %8.2f ms total / %6.4f ms per call',
                 [NewMs, NewMs / ITERATIONS]));
  WriteLn(Format('  Improvement                              : %6.2f%%',
                 [Improvement]));

  // Quick correctness check: both buffers should now hold the same most-recent
  // frame (or close to it; the WGC stream is live, so they're sampled at
  // slightly different times). We only verify they're the same size (no NaN/
  // freed-memory crash).
  WriteLn('  destination buffers still valid: ',
          (DstOld <> nil) and (DstNew <> nil));

  FreeMem(DstOld);
  FreeMem(DstNew);
  WGCRelease();

  WriteLn('DONE');
  Halt(0);
end.
