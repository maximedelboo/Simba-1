{
  Idle-CPU benchmark for simba.capture_dxgi.

  Opens the foreground window for capture, then sits in a busy loop
  pulling AcquireNextFrame(0) for 5 seconds without anything animating
  on screen. With DXGI Desktop Duplication this should be essentially
  free: AcquireNextFrame returns DXGI_ERROR_WAIT_TIMEOUT in microseconds
  when nothing changed, and PumpFrame short-circuits accordingly.

  Reports:
    - calls/sec
    - approximate user-mode CPU time consumed by this process (via
      GetProcessTimes).

  Build:
    "/c/fpcup/lazarus/lazbuild.exe" --build-mode=Default bench_idle.lpi
}
program bench_idle;

{$mode objfpc}{$H+}

uses
  Interfaces,
  SysUtils, Windows, Classes,
  simba.base, simba.capture_dxgi;

const
  BENCH_MS = 5000;
  // Realistic ACA/DTM poll rate. Without a sleep the loop runs at ~10kHz
  // and CPU is saturated; for an "idle Simba sitting at a script paused
  // on Wait(16)" baseline 60Hz is the meaningful number.
  POLL_INTERVAL_MS = 16;

function GetProcUserTimeMs(): UInt64;
var
  CreationT, ExitT, KernelT, UserT: TFileTime;
  K, U: UInt64;
begin
  Result := 0;
  CreationT := Default(TFileTime);
  ExitT := Default(TFileTime);
  KernelT := Default(TFileTime);
  UserT := Default(TFileTime);
  if GetProcessTimes(GetCurrentProcess(), CreationT, ExitT, KernelT, UserT) then
  begin
    K := (UInt64(KernelT.dwHighDateTime) shl 32) or UInt64(KernelT.dwLowDateTime);
    U := (UInt64(UserT.dwHighDateTime)   shl 32) or UInt64(UserT.dwLowDateTime);
    // FILETIME is in 100ns units.
    Result := (K + U) div 10000;
  end;
end;

var
  HW: HWND;
  Img: PColorBGRA;
  Start: QWord;
  Now: QWord;
  StartCPU, EndCPU: UInt64;
  Ok, Fail: Int64;
  WindowRect: TRect;
  W, H: Integer;
begin
  HW := GetForegroundWindow();
  if HW = 0 then
  begin
    WriteLn('No foreground window'); Halt(1);
  end;

  DXGIAutoOpen(TWindowHandle(HW));
  if DXGILastError() <> '' then
  begin
    WriteLn('DXGIAutoOpen: ', DXGILastError()); Halt(1);
  end;

  if not GetWindowRect(HW, @WindowRect) then
    Exit;
  W := WindowRect.Right - WindowRect.Left;
  H := WindowRect.Bottom - WindowRect.Top;
  if W < 1 then W := 1;
  if H < 1 then H := 1;

  Img := nil;
  // Warm up: one successful capture before timing.
  DXGITryGetImage(TWindowHandle(HW), 0, 0, W, H, Img);

  Ok := 0; Fail := 0;
  Start := GetTickCount64();
  StartCPU := GetProcUserTimeMs();

  while True do
  begin
    Now := GetTickCount64();
    if (Now - Start) >= BENCH_MS then Break;

    if DXGITryGetImage(TWindowHandle(HW), 0, 0, W, H, Img) then
      Inc(Ok)
    else
      Inc(Fail);
    Sleep(POLL_INTERVAL_MS);
  end;

  EndCPU := GetProcUserTimeMs();
  if Img <> nil then FreeMem(Img);
  DXGIRelease();

  WriteLn('bench_idle: ', BENCH_MS, 'ms wall, ',
          Ok, ' successful + ', Fail, ' failed calls, CPU ',
          (EndCPU - StartCPU), 'ms (',
          Format('%.1f', [100.0 * (EndCPU - StartCPU) / BENCH_MS]), '% one-core)');
end.
