{
  Stress test: DXGI capture lifecycle survives target window
  destruction.

  Strategy:
    1. Spawn a notepad.exe.
    2. DXGIAutoOpen against its HWND, then DXGITryGetImage repeatedly
       in a tight loop.
    3. Asynchronously close notepad mid-loop (PostMessage(WM_CLOSE)).
    4. Confirm DXGITryGetImage starts returning False without crashing.
    5. Confirm DXGIRelease completes cleanly.

  Exit codes:
    0 = SUCCESS
    1 = setup failure (couldn't spawn / find / open notepad)
    2 = DXGI raised an exception (caught by Pascal try/except)
    3 = DXGITryGetImage kept returning True after the window was closed
        for too long (stale handle should fail fast)

  Build:
    "/c/fpcup/lazarus/lazbuild.exe" --build-mode=Default test_window_close.lpi
}
program test_window_close;

{$mode objfpc}{$H+}

uses
  Interfaces,
  SysUtils, Windows, Classes,
  simba.base, simba.capture_dxgi;

const
  MAX_AFTER_CLOSE_TRUE = 50;  // calls that may still succeed after WM_CLOSE
                              // (DXGI keeps capturing the monitor; the
                              // window's pixels are gone but the cached
                              // crop may still address valid monitor
                              // pixels for a brief grace period until
                              // the OS reflows the screen)

var
  StartupInfo: TStartupInfo;
  ProcInfo: TProcessInformation;
  CmdLine: AnsiString;
  HW: HWND;
  i, Attempts: Integer;
  Img: PColorBGRA;
  WindowRect: TRect;
  W, H: Integer;
  Got: Boolean;
  AfterCloseTrueCount: Integer;
  CrashCaught: Boolean;

type
  TSearch = record
    PID:   DWORD;
    Found: HWND;
  end;
  PSearch = ^TSearch;

function SearchCB(Window: HWND; LParam: LPARAM): WINBOOL; stdcall;
var
  OwnerPID: DWORD;
  P: PSearch;
begin
  Result := True;
  P := PSearch(LParam);
  OwnerPID := 0;
  GetWindowThreadProcessId(Window, OwnerPID);
  if (OwnerPID = P^.PID) and IsWindowVisible(Window) then
  begin
    P^.Found := Window;
    Result := False;
  end;
end;

function FindNotepadByPID(PID: DWORD): HWND;
var
  S: TSearch;
begin
  S.PID := PID;
  S.Found := 0;
  EnumWindows(@SearchCB, LPARAM(@S));
  Result := S.Found;
end;

begin
  CrashCaught := False;
  FillChar(StartupInfo, SizeOf(StartupInfo), 0);
  StartupInfo.cb := SizeOf(StartupInfo);
  CmdLine := 'notepad.exe';
  UniqueString(CmdLine);
  if not CreateProcess(nil, PChar(CmdLine), nil, nil, False, 0, nil, nil,
                       StartupInfo, ProcInfo) then
  begin
    WriteLn('FAIL: CreateProcess(notepad) failed: ', GetLastError());
    Halt(1);
  end;
  WaitForInputIdle(ProcInfo.hProcess, 2000);

  HW := 0;
  Attempts := 0;
  while (HW = 0) and (Attempts < 30) do
  begin
    HW := FindNotepadByPID(ProcInfo.dwProcessId);
    if HW = 0 then Sleep(100);
    Inc(Attempts);
  end;

  if HW = 0 then
  begin
    WriteLn('FAIL: did not find notepad window');
    TerminateProcess(ProcInfo.hProcess, 0);
    CloseHandle(ProcInfo.hProcess);
    CloseHandle(ProcInfo.hThread);
    Halt(1);
  end;

  WriteLn('Target HWND ', HW, ' (PID ', ProcInfo.dwProcessId, ')');

  DXGIAutoOpen(TWindowHandle(HW));
  if DXGILastError() <> '' then
  begin
    WriteLn('FAIL: DXGIAutoOpen: ', DXGILastError());
    TerminateProcess(ProcInfo.hProcess, 0);
    Halt(1);
  end;

  if not GetWindowRect(HW, @WindowRect) then
  begin
    WriteLn('FAIL: GetWindowRect');
    Halt(1);
  end;
  W := WindowRect.Right - WindowRect.Left;
  H := WindowRect.Bottom - WindowRect.Top;

  Img := nil;
  try
    // First, warm up.
    DXGITryGetImage(TWindowHandle(HW), 0, 0, W, H, Img);
    WriteLn('  warmup ok');

    // Capture loop with mid-loop window destruction.
    AfterCloseTrueCount := 0;
    for i := 0 to 99 do
    begin
      Got := DXGITryGetImage(TWindowHandle(HW), 0, 0, W, H, Img);

      if i = 25 then
      begin
        WriteLn('  posting WM_CLOSE at iteration ', i);
        PostMessage(HW, WM_CLOSE, 0, 0);
      end;

      if (i > 25) and Got then
        Inc(AfterCloseTrueCount);

      Sleep(20);
    end;

    WriteLn('  ', AfterCloseTrueCount, ' calls returned True after WM_CLOSE');
    if AfterCloseTrueCount > MAX_AFTER_CLOSE_TRUE then
    begin
      WriteLn('FAIL: capture kept succeeding for too long after close');
      Halt(3);
    end;

    DXGIRelease();
    WriteLn('  DXGIRelease() ok');
  except
    on E: Exception do
    begin
      CrashCaught := True;
      WriteLn('FAIL: exception during stress: ', E.ClassName, ': ', E.Message);
    end;
  end;

  if Img <> nil then FreeMem(Img);
  CloseHandle(ProcInfo.hProcess);
  CloseHandle(ProcInfo.hThread);

  if CrashCaught then Halt(2);
  WriteLn('SUCCESS');
end.
