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

// PSAPI exports for enumerating loaded modules in the host process.
function EnumProcessModules(hProcess: THandle; lphModule: Pointer;
  cb: DWORD; var lpcbNeeded: DWORD): BOOL; stdcall;
  external 'psapi.dll' name 'EnumProcessModules';
function GetModuleBaseNameW(hProcess: THandle; hModule: HMODULE;
  lpBaseName: PWideChar; nSize: DWORD): DWORD; stdcall;
  external 'psapi.dll' name 'GetModuleBaseNameW';

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

// Report the host process's image name and presence of modules we'd need to
// hook for OpenGL capture. Cheap reconnaissance for the next phase.
procedure ReportEnvironment();
var
  ExeName: array[0..MAX_PATH] of WideChar;
  ExeLen: DWORD;
  Modules: array[0..511] of HMODULE;
  Needed, I: DWORD;
  ModName: array[0..MAX_PATH] of WideChar;
  Lower: string;
  HasOpenGL, HasJvm, HasD3D11: Boolean;
  Count: Integer;
begin
  ExeLen := GetModuleFileNameW(0, @ExeName[0], MAX_PATH);
  if ExeLen > 0 then
    WriteLog('host_exe=' + string(WideString(ExeName)));

  HasOpenGL := False;
  HasJvm := False;
  HasD3D11 := False;
  Needed := 0;
  Count := 0;
  if EnumProcessModules(GetCurrentProcess(), @Modules[0],
                        SizeOf(Modules), Needed) then
  begin
    Count := Needed div SizeOf(HMODULE);
    if Count > Length(Modules) then
      Count := Length(Modules);
    for I := 0 to Count - 1 do
    begin
      if GetModuleBaseNameW(GetCurrentProcess(), Modules[I],
                            @ModName[0], MAX_PATH) > 0 then
      begin
        Lower := LowerCase(string(WideString(ModName)));
        if Lower = 'opengl32.dll' then HasOpenGL := True
        else if Lower = 'jvm.dll' then HasJvm := True
        else if Lower = 'd3d11.dll' then HasD3D11 := True;
      end;
    end;
  end;
  WriteLog(Format('modules: count=%d opengl32=%s jvm=%s d3d11=%s',
    [Count, BoolToStr(HasOpenGL, True), BoolToStr(HasJvm, True),
     BoolToStr(HasD3D11, True)]));

  if HasOpenGL then
  begin
    // If opengl32.dll is loaded, report the address of wglSwapBuffers — this
    // is the function our future trampoline engine will need to patch.
    WriteLog(Format('wglSwapBuffers=0x%p',
      [GetProcAddress(GetModuleHandleW('opengl32.dll'), 'wglSwapBuffers')]));
  end;
end;

initialization
  WriteLog('attach');
  ReportEnvironment();

finalization
  WriteLog('detach');

end.
