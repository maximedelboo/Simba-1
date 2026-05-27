{
  Cold-start regression test for WGCAutoOpen / WGCTryGetImageInto.

  Reproduces the IDE-callsite pattern that the 28fc42ec lazy-staging
  optimization broke: WGCAutoOpen(hwnd) immediately followed by a
  single WGCTryGetImageInto with no Sleep in between. Single-shot IDE
  callers (image debug viewer, ACA on first target pick) do exactly
  this and have no retry loop.

  Before the fix:
    * GLastConsumerTouchedAt is 0 after WGCAutoOpen returns
    * FrameArrived sees LastTouched=0 and takes the idle-skip path
    * No frame is ever staged before the consumer call
    * WGCTryGetImageInto returns False
    * (the call itself bumps the timestamp, so the NEXT FrameArrived
      stages — but no consumer is waiting to read it)

  After the fix:
    * WGCAutoOpen sets GLastConsumerTouchedAt := GetTickCount64()
    * 200ms warm-up window in which FrameArrived stages every frame
    * First WGCTryGetImageInto after WGCAutoOpen (within the window)
      gets a fresh frame on the first call

  We give DWM up to ~50ms to deliver the first FrameArrived after
  StartCapture (one compose cycle is ~16ms, two is the safe margin).
  That delay is FrameArrived-side, not consumer-side, and the warm-up
  window is 200ms — far longer.

  Pass criteria:
    * WGCTryGetImageInto returns True on the FIRST call after the
      small "let FrameArrived fire once" sleep
    * The returned image is non-zero (at least one non-zero pixel —
      a freshly-staged frame from a real window will always have one)

  Exit codes:
    0 = SUCCESS (cold-start fix verified)
    1 = bad/missing HWND argument
    2 = WGCAutoOpen failed
    3 = WGCTryGetImageInto returned False on first call (REGRESSION)
    4 = WGCTryGetImageInto returned True but image is all zeros

  Build:
    "/c/fpcup/lazarus/lazbuild.exe" --build-mode=Default test_coldstart.lpi

  Run:
    ./test_coldstart.exe <HWND-in-hex-or-decimal>
    ./test_coldstart.exe                # uses foreground window
}
program test_coldstart;

{$mode objfpc}{$H+}

uses
  Interfaces, SysUtils, Windows, Classes,
  simba.base, simba.capture_wgc;

const
  // Time we sleep AFTER WGCAutoOpen and BEFORE the first
  // WGCTryGetImageInto, to let at least one FrameArrived fire from
  // the DWM compose loop. This is the natural latency between
  // StartCapture and the first frame landing in the staging path —
  // it would be present in any real caller and is independent of the
  // 200ms warm-up window the fix establishes.
  //
  // The fix's promise: as long as this delay is < 200ms, the very
  // first WGCTryGetImageInto succeeds. We use 50ms (~3 DWM cycles).
  FRAME_ARRIVE_WAIT_MS = 50;

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

function ImageHasNonZeroPixel(P: PColorBGRA; PixelCount: PtrUInt): Boolean;
var
  i: PtrUInt;
  Q: PCardinal;
begin
  Result := False;
  Q := PCardinal(P);
  for i := 0 to PixelCount - 1 do
    if Q[i] <> 0 then
    begin
      Result := True;
      Exit;
    end;
end;

var
  HW: HWND;
  WindowRect: Windows.TRect;
  W, H: Integer;
  ByteSize: PtrUInt;
  PixelCount: PtrUInt;
  Dst: PColorBGRA;
  Got: Boolean;
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

  WriteLn('Cold-start regression test for WGCAutoOpen+WGCTryGetImageInto');
  WriteLn('--------------------------------------------------------------');
  WriteLn('  HWND        : ', HW);
  WriteLn('  rect        : ', W, 'x', H);

  // ===== The actual test =====
  // Step 1: WGCAutoOpen — opens session, registers FrameArrived,
  // StartCapture's. The FIX sets GLastConsumerTouchedAt here so the
  // warm-up window is now armed.
  WGCAutoOpen(TWindowHandle(HW));
  if WGCLastError() <> '' then
  begin
    WriteLn('FAIL: WGCAutoOpen: ', WGCLastError());
    Halt(2);
  end;
  WriteLn('  [step 1] WGCAutoOpen OK');

  // Step 2: Give FrameArrived a chance to fire at least once. This
  // delay is well inside the 200ms warm-up window, so the handler
  // takes the STAGING path (not the idle-skip path) and the latest-
  // frame buffer gets populated.
  Sleep(FRAME_ARRIVE_WAIT_MS);
  WriteLn('  [step 2] slept ', FRAME_ARRIVE_WAIT_MS, 'ms (FrameArrived warm-up)');

  // Step 3: The single critical call. Without the fix this returns
  // False (no frame ever staged because the handler was in skip mode
  // from t=0). With the fix it returns True.
  ByteSize := PtrUInt(W) * PtrUInt(H) * SizeOf(TColorBGRA);
  PixelCount := PtrUInt(W) * PtrUInt(H);
  Dst := GetMem(ByteSize);
  FillChar(Dst^, ByteSize, 0); // zero so a False-but-OK-looking buffer is detectable

  Got := WGCTryGetImageInto(TWindowHandle(HW), 0, 0, W, H, Dst, W);
  if not Got then
  begin
    WriteLn('FAIL: first WGCTryGetImageInto returned False (COLD-START REGRESSION)');
    FreeMem(Dst);
    WGCRelease();
    Halt(3);
  end;
  WriteLn('  [step 3] first WGCTryGetImageInto returned True');

  // Step 4: Sanity-check the buffer isn't all zeros (would mean we
  // got back a wired-down empty buffer instead of an actual frame).
  if not ImageHasNonZeroPixel(Dst, PixelCount) then
  begin
    WriteLn('FAIL: image is all zeros (no real frame data staged)');
    FreeMem(Dst);
    WGCRelease();
    Halt(4);
  end;
  WriteLn('  [step 4] image has non-zero pixels (real frame data)');

  FreeMem(Dst);
  WGCRelease();

  WriteLn('PASS: cold-start fix verified');
  Halt(0);
end.
