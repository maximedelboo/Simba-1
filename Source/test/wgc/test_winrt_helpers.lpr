{
  Phase 1 acceptance test for simba.winrt_helpers.pas.

  Stands alone (no simba.base/LCL dependency) by re-declaring the same
  combase.dll entry points and exercising them in the same order the
  helper unit does:

    1. RoInitialize(RO_INIT_MULTITHREADED) succeeds
    2. WindowsCreateString builds an HSTRING from a Pascal String
    3. RoGetActivationFactory returns the IUriRuntimeClassFactory for
       Windows.Foundation.Uri
    4. The HSTRING is released via WindowsDeleteString
    5. The factory interface releases cleanly (refcount transfer)
    6. RoUninitialize closes out

  Prints SUCCESS on the happy path, otherwise prints the failing step
  and a FormatMessage'd HRESULT and exits with a non-zero code.

  This file is intentionally NOT wired into Simba.lpi - it is a
  one-shot Phase 1 acceptance proof. The actual Simba binary depends
  on simba.winrt_helpers.pas, which mirrors this code.
}
program test_winrt_helpers;

{$mode objfpc}{$H+}

uses
  SysUtils, Windows;

const
  RO_INIT_MULTITHREADED = 1;

  // Windows.Foundation.Uri's static factory IID
  // (from windows.foundation.h - IUriRuntimeClassFactory).
  IUriRuntimeClassFactory_IID: TGUID = '{44A9796F-723E-4FDF-A218-033E75B0C084}';

function RoInitialize(initType: Integer): HRESULT; stdcall; external 'combase.dll' name 'RoInitialize';
procedure RoUninitialize(); stdcall; external 'combase.dll' name 'RoUninitialize';
function WindowsCreateString(srcString: PWideChar; length: UInt32; out hstring: Pointer): HRESULT; stdcall; external 'combase.dll' name 'WindowsCreateString';
function WindowsDeleteString(hstring: Pointer): HRESULT; stdcall; external 'combase.dll' name 'WindowsDeleteString';
function WindowsGetStringRawBuffer(hstring: Pointer; out length: UInt32): PWideChar; stdcall; external 'combase.dll' name 'WindowsGetStringRawBuffer';
function RoGetActivationFactory(activatableClassId: Pointer; const iid: TGUID; out factory: IInterface): HRESULT; stdcall; external 'combase.dll' name 'RoGetActivationFactory';

function HResultToStr(HR: HRESULT): String;
var
  Buffer: PWideChar;
  Len: DWORD;
  W: UnicodeString;
begin
  Buffer := nil;
  Len := FormatMessageW(
    FORMAT_MESSAGE_FROM_SYSTEM or
    FORMAT_MESSAGE_IGNORE_INSERTS or
    FORMAT_MESSAGE_ALLOCATE_BUFFER,
    nil, DWORD(HR), 0, PWideChar(@Buffer), 0, nil);
  if (Len > 0) and (Buffer <> nil) then
  begin
    try
      SetString(W, Buffer, Len);
      Result := Format('0x%.8x (%s)', [HR, Trim(String(W))]);
    finally
      LocalFree(HLOCAL(Buffer));
    end;
  end
  else
    Result := Format('0x%.8x', [HR]);
end;

procedure Die(const Step: String; HR: HRESULT);
begin
  WriteLn(StdErr, 'FAIL at ', Step, ': ', HResultToStr(HR));
  Halt(1);
end;

var
  HR: HRESULT;
  ClassName: UnicodeString;
  ClassNameHS: Pointer;
  Factory: IInterface;
  RoundTrip: PWideChar;
  RoundTripLen: UInt32;
  Roundtripped: UnicodeString;
begin
  WriteLn('Phase 1 acceptance test for simba.winrt_helpers plumbing.');

  // Step 1: RoInitialize
  HR := RoInitialize(RO_INIT_MULTITHREADED);
  if not Succeeded(HR) then Die('RoInitialize', HR);
  WriteLn('  [ok] RoInitialize(MTA)');

  // Step 2: WindowsCreateString
  ClassName := 'Windows.Foundation.Uri';
  ClassNameHS := nil;
  HR := WindowsCreateString(PWideChar(ClassName), Length(ClassName), ClassNameHS);
  if not Succeeded(HR) then Die('WindowsCreateString', HR);
  if ClassNameHS = nil then
  begin
    WriteLn(StdErr, 'FAIL: WindowsCreateString returned null HSTRING');
    Halt(2);
  end;
  WriteLn('  [ok] WindowsCreateString("Windows.Foundation.Uri")');

  // Sanity: round-trip the HSTRING back to a Pascal string and confirm
  // it matches what we put in.
  RoundTripLen := 0;
  RoundTrip := WindowsGetStringRawBuffer(ClassNameHS, RoundTripLen);
  if (RoundTrip = nil) or (RoundTripLen <> UInt32(Length(ClassName))) then
  begin
    WriteLn(StdErr, 'FAIL: WindowsGetStringRawBuffer length mismatch (',
            RoundTripLen, ' vs ', Length(ClassName), ')');
    Halt(3);
  end;
  SetString(Roundtripped, RoundTrip, RoundTripLen);
  if Roundtripped <> ClassName then
  begin
    WriteLn(StdErr, 'FAIL: HSTRING round-trip mismatch: "', String(Roundtripped),
            '" vs "', String(ClassName), '"');
    Halt(4);
  end;
  WriteLn('  [ok] WindowsGetStringRawBuffer round-trip matches');

  // Step 3: RoGetActivationFactory
  Factory := nil;
  HR := RoGetActivationFactory(ClassNameHS, IUriRuntimeClassFactory_IID, Factory);
  if not Succeeded(HR) then
  begin
    WindowsDeleteString(ClassNameHS);
    RoUninitialize();
    Die('RoGetActivationFactory', HR);
  end;
  if Factory = nil then
  begin
    WindowsDeleteString(ClassNameHS);
    RoUninitialize();
    WriteLn(StdErr, 'FAIL: RoGetActivationFactory returned S_OK but null factory');
    Halt(5);
  end;
  WriteLn('  [ok] RoGetActivationFactory(IUriRuntimeClassFactory) returned non-nil');

  // Step 4: release the HSTRING (factory still holds its own ref to nothing
  // - HSTRINGs are not COM, the factory just used the value).
  HR := WindowsDeleteString(ClassNameHS);
  if not Succeeded(HR) then Die('WindowsDeleteString', HR);
  WriteLn('  [ok] WindowsDeleteString');

  // Step 5: release factory (out-of-scope on var assignment).
  Factory := nil;
  WriteLn('  [ok] Factory released');

  // Step 6: RoUninitialize
  RoUninitialize();
  WriteLn('  [ok] RoUninitialize');

  WriteLn('SUCCESS');
  Halt(0);
end.
