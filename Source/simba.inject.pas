{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)
}
unit simba.inject;

{$mode objfpc}{$H+}

interface

{$IFDEF WINDOWS}
uses
  Windows;

// Inject a DLL stored as an RCDATA resource in the calling exe into the
// process identified by PID. Writes the resource bytes to a temp file
// and triggers LoadLibraryW in the target via CreateRemoteThread. Returns
// True on success; populates errMsg on failure.
function InjectDllFromResource(pid: DWORD; resName: PWideChar;
                               out errMsg: string): Boolean;
{$ENDIF}

implementation

{$IFDEF WINDOWS}

uses
  SysUtils;

function Win32Err(const What: string): string;
var
  E: DWORD;
begin
  E := GetLastError();
  Result := Format('%s failed (code %d): %s', [What, E, SysErrorMessage(E)]);
end;

function GenerateTempDllPath(): UnicodeString;
var
  TempDir: array[0..MAX_PATH] of WideChar;
  Guid: TGUID;
  GuidStr: WideString;
  Len: DWORD;
begin
  Len := GetTempPathW(MAX_PATH, @TempDir[0]);
  if Len = 0 then
    TempDir[0] := WideChar(0);
  CreateGUID(Guid);
  GuidStr := WideString(GUIDToString(Guid));
  // Strip braces from GUIDToString output for a tidier filename.
  if (Length(GuidStr) >= 2) and (GuidStr[1] = '{') then
    GuidStr := Copy(GuidStr, 2, Length(GuidStr) - 2);
  Result := UnicodeString(TempDir) + 'simba_hook_' + UnicodeString(GuidStr) + '.dll';
end;

function WriteBufferToFile(const Path: UnicodeString;
                           Buf: Pointer; Size: DWORD;
                           out errMsg: string): Boolean;
var
  H: THandle;
  Written: DWORD;
begin
  Result := False;
  errMsg := '';
  H := CreateFileW(PWideChar(Path),
                   GENERIC_WRITE, 0, nil,
                   CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if H = INVALID_HANDLE_VALUE then
  begin
    errMsg := Win32Err('CreateFileW (temp dll)');
    Exit;
  end;
  Written := 0;
  try
    if not WriteFile(H, Buf^, Size, Written, nil) then
    begin
      errMsg := Win32Err('WriteFile (temp dll)');
      Exit;
    end;
    if Written <> Size then
    begin
      errMsg := Format('WriteFile (temp dll) short: %d of %d bytes', [Written, Size]);
      Exit;
    end;
    Result := True;
  finally
    CloseHandle(H);
  end;
end;

function InjectDllFromResource(pid: DWORD; resName: PWideChar;
                               out errMsg: string): Boolean;
var
  HRes: HRSRC;
  HData: HGLOBAL;
  Bytes: Pointer;
  Size: DWORD;
  TempPath: UnicodeString;
  TempPathBytes: DWORD;
  ProcHandle: THandle;
  RemoteMem: Pointer;
  Written: SIZE_T;
  Kernel32: HMODULE;
  LoadLibAddr: Pointer;
  Thread: THandle;
  WaitRes: DWORD;
  ExitCode: DWORD;
  ThreadId: DWORD;
begin
  Result := False;
  errMsg := '';
  TempPath := '';
  ProcHandle := 0;
  RemoteMem := nil;
  Thread := 0;

  if pid = 0 then
  begin
    errMsg := 'invalid pid (0)';
    Exit;
  end;
  if resName = nil then
  begin
    errMsg := 'resName is nil';
    Exit;
  end;

  HRes := FindResourceW(0, resName, PWideChar(MAKEINTRESOURCE(RT_RCDATA)));
  if HRes = 0 then
  begin
    errMsg := Win32Err('FindResourceW(HOOK64)');
    Exit;
  end;

  Size := SizeofResource(0, HRes);
  if Size = 0 then
  begin
    errMsg := Win32Err('SizeofResource');
    Exit;
  end;

  HData := LoadResource(0, HRes);
  if HData = 0 then
  begin
    errMsg := Win32Err('LoadResource');
    Exit;
  end;

  Bytes := LockResource(HData);
  if Bytes = nil then
  begin
    errMsg := 'LockResource returned nil';
    Exit;
  end;

  TempPath := GenerateTempDllPath();
  if not WriteBufferToFile(TempPath, Bytes, Size, errMsg) then
    Exit;

  try
    ProcHandle := OpenProcess(
      PROCESS_CREATE_THREAD or PROCESS_VM_OPERATION or
      PROCESS_VM_WRITE or PROCESS_VM_READ or PROCESS_QUERY_INFORMATION,
      False, pid);
    if ProcHandle = 0 then
    begin
      errMsg := Win32Err('OpenProcess');
      Exit;
    end;

    // Path string lives in the target's address space. UTF-16 + NUL terminator.
    TempPathBytes := (Length(TempPath) + 1) * SizeOf(WideChar);
    RemoteMem := VirtualAllocEx(ProcHandle, nil, TempPathBytes,
                                MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
    if RemoteMem = nil then
    begin
      errMsg := Win32Err('VirtualAllocEx');
      Exit;
    end;

    Written := 0;
    if not WriteProcessMemory(ProcHandle, RemoteMem,
                              PWideChar(TempPath), TempPathBytes, Written) then
    begin
      errMsg := Win32Err('WriteProcessMemory');
      Exit;
    end;

    // kernel32.dll is mapped at the same base in all 64-bit processes within
    // a Windows session (since Vista), so we can use our own LoadLibraryW
    // address as the address in the target.
    Kernel32 := GetModuleHandleW('kernel32.dll');
    if Kernel32 = 0 then
    begin
      errMsg := Win32Err('GetModuleHandleW(kernel32)');
      Exit;
    end;
    LoadLibAddr := GetProcAddress(Kernel32, 'LoadLibraryW');
    if LoadLibAddr = nil then
    begin
      errMsg := Win32Err('GetProcAddress(LoadLibraryW)');
      Exit;
    end;

    ThreadId := 0;
    Thread := CreateRemoteThread(ProcHandle, nil, 0,
                                 TFNThreadStartRoutine(LoadLibAddr),
                                 RemoteMem, 0, ThreadId);
    if Thread = 0 then
    begin
      errMsg := Win32Err('CreateRemoteThread');
      Exit;
    end;

    WaitRes := WaitForSingleObject(Thread, 5000);
    if WaitRes = WAIT_TIMEOUT then
    begin
      errMsg := 'WaitForSingleObject timed out after 5s';
      Exit;
    end;
    if WaitRes <> WAIT_OBJECT_0 then
    begin
      errMsg := Win32Err('WaitForSingleObject');
      Exit;
    end;

    ExitCode := 0;
    if not GetExitCodeThread(Thread, ExitCode) then
    begin
      errMsg := Win32Err('GetExitCodeThread');
      Exit;
    end;

    // On x64, the thread exit code is the low 32 bits of the HMODULE
    // returned by LoadLibraryW. Zero means LoadLibrary returned NULL.
    if ExitCode = 0 then
    begin
      errMsg := 'LoadLibraryW returned NULL in target (lower 32 bits of HMODULE = 0)';
      Exit;
    end;

    Result := True;
  finally
    if Thread <> 0 then
      CloseHandle(Thread);
    if (ProcHandle <> 0) and (RemoteMem <> nil) then
      VirtualFreeEx(ProcHandle, RemoteMem, 0, MEM_RELEASE);
    if ProcHandle <> 0 then
      CloseHandle(ProcHandle);
    // The temp DLL stays on disk while the target holds it mapped. Phase 5
    // (reflective loading) will eliminate this artefact entirely.
  end;
end;

{$ENDIF}

end.
