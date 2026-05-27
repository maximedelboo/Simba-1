{
  Phase 1 acceptance test for the PUBLIC API of simba.winrt_helpers.

  Sibling of test_winrt_helpers.lpr. The other test re-declares the
  combase.dll externals itself and exercises the raw plumbing - useful
  to confirm FPC's stdcall marshalling matches WinRT but it does NOT
  exercise the helper unit's wrappers.

  THIS test calls only WinRT_Initialize / WinRT_GetActivationFactory /
  WinRT_Uninitialize / WinRT_LastError. That is the surface the
  capture_wgc unit (Phase 3) will use. If FPC interface marshalling
  with the helpers is broken in any way - signature mismatch, lock
  re-entrancy, refcount transfer through the `out IInterface` parameter -
  this test catches it.

  Exit codes:
    0 = SUCCESS
    1 = WinRT_Initialize failed
    2 = WinRT_GetActivationFactory failed
    3 = WinRT_GetActivationFactory returned True but Factory is nil

  Build: needs simba.winrt_helpers, which transitively pulls in
  simba.base + LCL. Built via lazbuild with the accompanying
  test_winrt_helpers_public.lpi.
}
program test_winrt_helpers_public;

{$mode objfpc}{$H+}

uses
  simba.winrt_helpers;

const
  // Windows.Foundation.Uri's static factory IID
  // (IUriRuntimeClassFactory in windows.foundation.h).
  IUriRuntimeClassFactory_IID: TGUID = '{44A9796F-723E-4FDF-A218-033E75B0C084}';

var
  Factory: IInterface;
begin
  WriteLn('Phase 1 public-API acceptance test for simba.winrt_helpers.');

  if not WinRT_Initialize() then
  begin
    WriteLn('FAIL: WinRT_Initialize: ', WinRT_LastError());
    Halt(1);
  end;
  WriteLn('  [ok] WinRT_Initialize() returned True');

  Factory := nil;
  if not WinRT_GetActivationFactory('Windows.Foundation.Uri',
                                    IUriRuntimeClassFactory_IID,
                                    Factory) then
  begin
    WriteLn('FAIL: WinRT_GetActivationFactory: ', WinRT_LastError());
    WinRT_Uninitialize();
    Halt(2);
  end;

  if Factory = nil then
  begin
    WriteLn('FAIL: WinRT_GetActivationFactory returned True but Factory is nil');
    WinRT_Uninitialize();
    Halt(3);
  end;
  WriteLn('  [ok] WinRT_GetActivationFactory returned non-nil factory');

  // Drop the factory (refcount transfer happens via FPC's interface
  // management when Factory goes out of scope, but be explicit so the
  // sequence is obvious in the trace).
  Factory := nil;
  WriteLn('  [ok] Factory released');

  WinRT_Uninitialize();
  WriteLn('  [ok] WinRT_Uninitialize()');

  WriteLn('SUCCESS: public-API round-trip via simba.winrt_helpers');
  Halt(0);
end.
