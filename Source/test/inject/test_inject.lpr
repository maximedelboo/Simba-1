{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)
}
program test_inject;

{$mode objfpc}{$H+}

// Embed the hook DLL so InjectDllFromResource can read RCDATA "HOOK64"
// from this exe's own image.
{$R ..\..\hook\simba_hook.res}

uses
  SysUtils, Windows,
  simba.inject;

var
  Pid: DWORD;
  Code: Integer;
  ErrMsg: string;
  N: UInt64;
begin
  if ParamCount < 1 then
  begin
    WriteLn('Usage: test_inject.exe <pid>');
    Halt(1);
  end;

  Val(ParamStr(1), N, Code);
  if Code <> 0 then
  begin
    WriteLn('FAIL: could not parse "', ParamStr(1), '" as a PID');
    Halt(1);
  end;
  Pid := DWORD(N);

  WriteLn('Injecting HOOK64 into pid=', Pid, '...');
  if InjectDllFromResource(Pid, 'HOOK64', ErrMsg) then
  begin
    WriteLn('SUCCESS: DLL injected into pid=', Pid);
    Halt(0);
  end;

  WriteLn('FAIL: ', ErrMsg);
  Halt(1);
end.
