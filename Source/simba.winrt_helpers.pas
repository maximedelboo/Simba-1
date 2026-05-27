{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)
}
unit simba.winrt_helpers;

{$i simba.inc}

interface

uses
  Classes, SysUtils,
  simba.base;

type
  THString = record
  private
    FHandle: Pointer;
  public
    procedure FromPascal(const S: String);
    function ToPascal(): String;
    procedure Finalize();
  end;

function WinRT_Initialize(): Boolean;
procedure WinRT_Uninitialize();
function WinRT_GetActivationFactory(const ClassName: String; const IID: TGUID; out Factory: IInterface): Boolean;
function WinRT_LastError(): String;
function WinRT_HRESULTToStr(HR: LongInt): String;

implementation

{$IFDEF WINDOWS}

uses
  Windows, syncobjs;

const
  RO_INIT_MULTITHREADED = 1;

function RoInitialize(initType: Integer): HRESULT; stdcall; external 'combase.dll' name 'RoInitialize';
procedure RoUninitialize(); stdcall; external 'combase.dll' name 'RoUninitialize';
function WindowsCreateString(srcString: PWideChar; length: UInt32; out hstring: Pointer): HRESULT; stdcall; external 'combase.dll' name 'WindowsCreateString';
function WindowsDeleteString(hstring: Pointer): HRESULT; stdcall; external 'combase.dll' name 'WindowsDeleteString';
function WindowsGetStringRawBuffer(hstring: Pointer; out length: UInt32): PWideChar; stdcall; external 'combase.dll' name 'WindowsGetStringRawBuffer';
function RoGetActivationFactory(activatableClassId: Pointer; const iid: TGUID; out factory: IInterface): HRESULT; stdcall; external 'combase.dll' name 'RoGetActivationFactory';

var
  GLock: TCriticalSection = nil;
  GRefCount: Integer = 0;
  GInitialized: Boolean = False;
  GLastError: String = '';

function WinRT_HRESULTToStr(HR: LongInt): String;
var
  Buffer: PWideChar;
  Len: DWORD;
  W: UnicodeString;
  Ch: WideChar;
begin
  Buffer := nil;
  Len := FormatMessageW(
    FORMAT_MESSAGE_FROM_SYSTEM or
    FORMAT_MESSAGE_IGNORE_INSERTS or
    FORMAT_MESSAGE_ALLOCATE_BUFFER,
    nil,
    DWORD(HR),
    0,
    PWideChar(@Buffer),
    0,
    nil
  );

  if (Len > 0) and (Buffer <> nil) then
  begin
    try
      SetString(W, Buffer, Len);
      while Length(W) > 0 do
      begin
        Ch := W[Length(W)];
        if (Ch = #10) or (Ch = #13) or (Ch = ' ') or (Ch = #9) then
          SetLength(W, Length(W) - 1)
        else
          Break;
      end;
      Result := String(W);
    finally
      LocalFree(HLOCAL(Buffer));
    end;

    if Result <> '' then
      Exit;
  end
  else if Buffer <> nil then
    LocalFree(HLOCAL(Buffer));

  Result := '0x' + IntToHex(HR, 8);
end;

procedure THString.FromPascal(const S: String);
var
  U: UnicodeString;
  HR: HRESULT;
  NewHandle: Pointer;
  Msg: String;
begin
  if FHandle <> nil then
  begin
    WindowsDeleteString(FHandle);
    FHandle := nil;
  end;

  if S = '' then
    Exit;

  U := UnicodeString(S);
  NewHandle := nil;
  HR := WindowsCreateString(PWideChar(U), Length(U), NewHandle);
  if Succeeded(HR) then
  begin
    FHandle := NewHandle;
  end
  else
  begin
    // WinRT_HRESULTToStr calls FormatMessageW + LocalFree; build outside the lock.
    Msg := 'WindowsCreateString failed: ' + WinRT_HRESULTToStr(HR);
    GLock.Enter;
    try
      GLastError := Msg;
    finally
      GLock.Leave;
    end;
    FHandle := nil;
  end;
end;

function THString.ToPascal(): String;
var
  Buf: PWideChar;
  Len: UInt32;
  W: UnicodeString;
begin
  Result := '';
  if FHandle = nil then
    Exit;

  Len := 0;
  Buf := WindowsGetStringRawBuffer(FHandle, Len);
  if (Buf = nil) or (Len = 0) then
    Exit;

  SetString(W, Buf, Len);
  Result := String(W);
end;

procedure THString.Finalize();
begin
  if FHandle <> nil then
  begin
    WindowsDeleteString(FHandle);
    FHandle := nil;
  end;
end;

function WinRT_Initialize(): Boolean;
const
  RPC_E_CHANGED_MODE = HRESULT($80010106);
var
  HR: HRESULT;
begin
  GLock.Enter;
  try
    GLastError := '';
    if GRefCount = 0 then
    begin
      HR := RoInitialize(RO_INIT_MULTITHREADED);
      // RPC_E_CHANGED_MODE: calling thread already had RoInitialize called
      // with a different (STA) apartment — typical when invoked from LCL's
      // main thread after Forms init. Our free-threaded frame pool makes
      // the caller's apartment irrelevant; accept STA and move on. We did
      // NOT contribute to combase's per-thread refcount, so GInitialized
      // stays False so WinRT_Uninitialize doesn't call RoUninitialize.
      if HR = RPC_E_CHANGED_MODE then
      begin
        GInitialized := False;
      end
      else if not Succeeded(HR) then
      begin
        GLastError := 'RoInitialize failed: ' + WinRT_HRESULTToStr(HR);
        GInitialized := False;
        Exit(False);
      end
      else
        GInitialized := True;
    end;
    Inc(GRefCount);
    Result := True;
  finally
    GLock.Leave;
  end;
end;

procedure WinRT_Uninitialize();
begin
  GLock.Enter;
  try
    GLastError := '';
    if GRefCount <= 0 then
      Exit;

    Dec(GRefCount);
    if (GRefCount = 0) and GInitialized then
    begin
      RoUninitialize();
      GInitialized := False;
    end;
  finally
    GLock.Leave;
  end;
end;

function WinRT_GetActivationFactory(const ClassName: String; const IID: TGUID; out Factory: IInterface): Boolean;
var
  ClassNameHS: THString;
  HR: HRESULT;
  Msg: String;
begin
  Factory := nil;
  Result := False;
  ClassNameHS.FHandle := nil;

  GLock.Enter;
  try
    GLastError := '';
  finally
    GLock.Leave;
  end;

  try
    ClassNameHS.FromPascal(ClassName);
    if ClassNameHS.FHandle = nil then
    begin
      GLock.Enter;
      try
        if GLastError = '' then
          GLastError := 'WinRT_GetActivationFactory: empty or invalid class name';
      finally
        GLock.Leave;
      end;
      Exit;
    end;

    HR := RoGetActivationFactory(ClassNameHS.FHandle, IID, Factory);
    if Succeeded(HR) then
    begin
      Result := Factory <> nil;
      if not Result then
      begin
        GLock.Enter;
        try
          GLastError := 'RoGetActivationFactory returned S_OK but null factory for ' + ClassName;
        finally
          GLock.Leave;
        end;
      end;
    end
    else
    begin
      Factory := nil;
      // WinRT_HRESULTToStr calls FormatMessageW + LocalFree; build outside the lock.
      Msg := 'RoGetActivationFactory failed for ' + ClassName + ': ' + WinRT_HRESULTToStr(HR);
      GLock.Enter;
      try
        GLastError := Msg;
      finally
        GLock.Leave;
      end;
    end;
  finally
    ClassNameHS.Finalize();
  end;
end;

function WinRT_LastError(): String;
begin
  GLock.Enter;
  try
    Result := GLastError;
  finally
    GLock.Leave;
  end;
end;

{$ELSE}

procedure THString.FromPascal(const S: String); begin FHandle := nil; end;
function  THString.ToPascal(): String;          begin Result := ''; end;
procedure THString.Finalize();                  begin FHandle := nil; end;

function  WinRT_Initialize(): Boolean;          begin Result := False; end;
procedure WinRT_Uninitialize();                 begin end;

function WinRT_GetActivationFactory(const ClassName: String; const IID: TGUID; out Factory: IInterface): Boolean;
begin
  Factory := nil;
  Result := False;
end;

function WinRT_LastError(): String;             begin Result := ''; end;

function WinRT_HRESULTToStr(HR: LongInt): String;
begin
  Result := '0x' + IntToHex(HR, 8);
end;

{$ENDIF}

{$IFDEF WINDOWS}
initialization
  GLock := TCriticalSection.Create();

finalization
  if GInitialized then
  begin
    RoUninitialize();
    GInitialized := False;
  end;
  if GLock <> nil then
  begin
    GLock.Free;
    GLock := nil;
  end;
{$ENDIF}

end.
