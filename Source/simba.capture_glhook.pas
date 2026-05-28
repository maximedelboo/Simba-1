{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)
}
unit simba.capture_glhook;

{$i simba.inc}

interface

uses
  Classes, SysUtils,
  simba.base;

// Auto-inject the OpenGL render-thread hook DLL (RCDATA "HOOK64" embedded
// in Simba.exe) into the process owning Window. Idempotent per-PID for
// the lifetime of this Simba session: re-calls with the same window or
// any other window in an already-injected process are no-ops. Failures
// are logged via DebugLn and swallowed -- the hook is opportunistic; the
// DXGI desktop-duplication backend remains the fallback capture path.
procedure GLHookAutoInject(Window: TWindowHandle);

implementation

{$IFDEF WINDOWS}

uses
  Windows, syncobjs,
  simba.inject;

var
  // Guards GInjectedPids. Both the LCL main thread (IDE picker path) and
  // script-runner threads (TSimbaTarget.SetWindow) call GLHookAutoInject;
  // serialise the set + injection attempt so two concurrent SetWindow
  // calls into the same PID inject once, not twice.
  GInjectLock: TCriticalSection = nil;

  // PIDs we've already injected into during this Simba session. Plain
  // dynamic array: the set stays tiny in practice (one or two RuneLite
  // clients) so linear scan is cheaper than the TList<> ceremony.
  GInjectedPids: array of DWORD;

procedure GLHookLogError(const Msg: String);
begin
  DebugLn(DEBUG_RED + '[GL-hook] ' + Msg + DEBUG_RESET);
end;

// Caller MUST hold GInjectLock.
function PidAlreadyInjected(Pid: DWORD): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(GInjectedPids) do
    if GInjectedPids[I] = Pid then
      Exit(True);
  Result := False;
end;

// Caller MUST hold GInjectLock.
procedure RecordInjectedPid(Pid: DWORD);
var
  N: Integer;
begin
  N := Length(GInjectedPids);
  SetLength(GInjectedPids, N + 1);
  GInjectedPids[N] := Pid;
end;

procedure GLHookAutoInject(Window: TWindowHandle);
var
  Pid: DWORD;
  ErrMsg: string;
begin
  if GInjectLock = nil then
    Exit;
  if Window = 0 then Exit;
  if not IsWindow(HWND(Window)) then Exit;

  Pid := 0;
  GetWindowThreadProcessId(HWND(Window), @Pid);
  if Pid = 0 then Exit;

  // Never inject Simba into itself -- selecting Simba's own window as
  // the target (e.g. during debugging) must not load the hook here.
  if Pid = GetCurrentProcessId() then Exit;

  GInjectLock.Enter;
  try
    try
      if PidAlreadyInjected(Pid) then Exit;

      // Only record on success. A transient failure (e.g. OpenProcess
      // permission denied because Simba isn't elevated yet) shouldn't
      // permanently skip the PID for the rest of this Simba session --
      // the user can fix the cause and retry by re-selecting the target.
      if InjectDllFromResource(Pid, 'HOOK64', ErrMsg) then
      begin
        RecordInjectedPid(Pid);
        DebugLn('[GL-hook] injected into pid=%d', [Pid]);
      end
      else
        GLHookLogError(Format('inject pid=%d failed: %s', [Pid, ErrMsg]));
    except
      on E: Exception do
        GLHookLogError('Exception during GLHookAutoInject: ' +
                       E.ClassName + ': ' + E.Message);
    end;
  finally
    GInjectLock.Leave;
  end;
end;

{$ELSE}

procedure GLHookAutoInject(Window: TWindowHandle);
begin
end;

{$ENDIF}

{$IFDEF WINDOWS}
initialization
  GInjectLock := TCriticalSection.Create();

// Note: we deliberately do NOT free GInjectLock in finalization. A
// concurrent script-runner thread could race the nil-check at the top of
// GLHookAutoInject against finalization's free and call .Enter on freed
// memory. Letting the OS clean up the lock at process exit is safer than
// trying to coordinate teardown.
{$ENDIF}

end.
