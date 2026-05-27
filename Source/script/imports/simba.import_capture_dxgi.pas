unit simba.import_capture_dxgi;

{$i simba.inc}

interface

uses
  Classes, SysUtils,
  simba.script;

procedure ImportCaptureDXGI(Script: TSimbaScript);

implementation

uses
  lptypes,
  simba.capture_dxgi;

(*
DXGI Capture
============
Diagnostics for the DXGI Desktop Duplication window-capture backend.
On non-Windows platforms every entry point is a no-op; functions return
empty / zero so cross-platform scripts compile and run cleanly.
*)

(*
DXGILastError
-------------
```
function DXGILastError: String;
```
Returns the last error string from the DXGI capture pipeline (cleared
at the start of every Target.SetWindow / DXGIAutoOpen call). Empty
when the last bring-up succeeded.

Useful when a script's capture comes back empty / blank and the cause
needs to be diagnosed without leaving the script:

```
if not Target.HasImage() then
  WriteLn('DXGI capture failed: ', DXGILastError());
```

On non-Windows builds this always returns an empty string.
*)
procedure _LapeDXGILastError(const Params: PParamArray; const Result: Pointer); LAPE_WRAPPER_CALLING_CONV
begin
  PString(Result)^ := DXGILastError();
end;

(*
DXGIFrameCount
--------------
```
function DXGIFrameCount: Int64;
```
Total number of frames the DXGI pipeline has successfully written
into the cached frame buffer since process start. Climbs by one per
successful `AcquireNextFrame` + memcpy cycle. Useful for diagnostics —
confirming the capture pipeline is producing frames at all without
having to call DXGITryGetImage and inspect the result.
*)
procedure _LapeDXGIFrameCount(const Params: PParamArray; const Result: Pointer); LAPE_WRAPPER_CALLING_CONV
begin
  PInt64(Result)^ := DXGIFrameCount();
end;

procedure ImportCaptureDXGI(Script: TSimbaScript);
begin
  with Script.Compiler do
  begin
    DumpSection := 'DXGI';

    addGlobalFunc('function DXGILastError: String;', @_LapeDXGILastError);
    addGlobalFunc('function DXGIFrameCount: Int64;', @_LapeDXGIFrameCount);

    DumpSection := '';
  end;
end;

end.
