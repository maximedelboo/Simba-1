{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)
}
unit dllmain;

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils;

procedure Probe(hwnd: HWND; hinst: HMODULE; lpszCmdLine: PAnsiChar;
                nCmdShow: Integer); stdcall;

implementation

// Append a single line to %TEMP%\simba_hook.log. Robust by design: a DLL
// running inside an arbitrary host process must never raise. Any IO error
// is swallowed silently.
procedure WriteLog(const Msg: string);
var
  LogPath: string;
  TempDir: string;
  Header: string;
  Line: AnsiString;
  H: THandle;
  Written: DWORD;
  ModBase: Pointer;
begin
  try
    TempDir := GetEnvironmentVariable('TEMP');
    if TempDir = '' then
      TempDir := GetEnvironmentVariable('TMP');
    if TempDir = '' then
      Exit;
    LogPath := IncludeTrailingPathDelimiter(TempDir) + 'simba_hook.log';

    ModBase := Pointer(HInstance);
    Header := Format('[%s] pid=%d tid=%d base=0x%p | %s' + LineEnding,
      [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now()),
       GetCurrentProcessId(), GetCurrentThreadId(),
       ModBase, Msg]);
    Line := AnsiString(Header);

    H := CreateFileA(PAnsiChar(AnsiString(LogPath)),
                     FILE_APPEND_DATA,
                     FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
                     nil, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if H = INVALID_HANDLE_VALUE then
      Exit;
    try
      SetFilePointer(H, 0, nil, FILE_END);
      WriteFile(H, Line[1], Length(Line), Written, nil);
    finally
      CloseHandle(H);
    end;
  except
    // Swallow everything; a host-process DLL must not propagate exceptions.
  end;
end;

procedure Probe(hwnd: HWND; hinst: HMODULE; lpszCmdLine: PAnsiChar;
                nCmdShow: Integer); stdcall;
begin
  WriteLog('Probe called');
end;

initialization
  WriteLog('attach');

finalization
  WriteLog('detach');

end.
