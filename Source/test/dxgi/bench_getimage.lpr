{
  Per-call cost benchmark for simba.capture_dxgi.DXGITryGetImageInto.

  Performs N back-to-back captures of the foreground window and reports
  median + max latency.

  Build:
    "/c/fpcup/lazarus/lazbuild.exe" --build-mode=Default bench_getimage.lpi
}
program bench_getimage;

{$mode objfpc}{$H+}

uses
  Interfaces,
  SysUtils, Windows, Classes,
  simba.base, simba.capture_dxgi;

const
  N = 200;

procedure InsertionSort(var A: array of UInt64);
var
  i, j: Integer;
  Key: UInt64;
begin
  for i := 1 to High(A) do
  begin
    Key := A[i];
    j := i - 1;
    while (j >= 0) and (A[j] > Key) do
    begin
      A[j + 1] := A[j];
      Dec(j);
    end;
    A[j + 1] := Key;
  end;
end;

var
  HW: HWND;
  Img: PColorBGRA;
  WindowRect: TRect;
  W, H, i: Integer;
  Freq, T0, T1: Int64;
  Lat: array[0..N-1] of UInt64;
  Sum, Median, MaxL: UInt64;
begin
  HW := GetForegroundWindow();
  if HW = 0 then Halt(1);
  DXGIAutoOpen(TWindowHandle(HW));
  if DXGILastError() <> '' then
  begin
    WriteLn('DXGIAutoOpen: ', DXGILastError()); Halt(1);
  end;

  if not GetWindowRect(HW, @WindowRect) then Halt(1);
  W := WindowRect.Right - WindowRect.Left;
  H := WindowRect.Bottom - WindowRect.Top;
  if W < 1 then W := 1;
  if H < 1 then H := 1;

  Img := nil;
  // Warm up.
  for i := 1 to 3 do
    DXGITryGetImage(TWindowHandle(HW), 0, 0, W, H, Img);

  QueryPerformanceFrequency(Freq);

  for i := 0 to N - 1 do
  begin
    QueryPerformanceCounter(T0);
    DXGITryGetImage(TWindowHandle(HW), 0, 0, W, H, Img);
    QueryPerformanceCounter(T1);
    Lat[i] := UInt64((T1 - T0) * 1000000 div Freq); // microseconds
    Sleep(2);
  end;

  if Img <> nil then FreeMem(Img);
  DXGIRelease();

  InsertionSort(Lat);
  Sum := 0;
  for i := 0 to N - 1 do Sum := Sum + Lat[i];
  Median := Lat[N div 2];
  MaxL := Lat[N - 1];

  WriteLn('bench_getimage: ', N, ' captures of ', W, 'x', H, ' window');
  WriteLn('  mean:   ', Sum div N, ' us');
  WriteLn('  median: ', Median, ' us');
  WriteLn('  max:    ', MaxL, ' us');
end.
