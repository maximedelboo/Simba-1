unit simba.import_capture_wgc;

{$i simba.inc}

interface

uses
  Classes, SysUtils,
  simba.script;

procedure ImportCaptureWGC(Script: TSimbaScript);

implementation

uses
  lptypes,
  simba.capture_wgc;

(*
WGC Capture
===========
Diagnostics for the Windows Graphics Capture (WGC) window-capture backend.
On non-Windows platforms every entry point is a no-op; functions return
empty / zero so cross-platform scripts compile and run cleanly.
*)

(*
WGCLastError
------------
```
function WGCLastError: String;
```
Returns the last error string from the WGC capture pipeline (cleared at
the start of every Target.SetWindow / WGCAutoOpen call). Empty when the
last bring-up succeeded.

Useful when a script's capture comes back empty / blank and the cause
needs to be diagnosed without leaving the script:

```
if not Target.HasImage() then
  WriteLn('WGC capture failed: ', WGCLastError());
```

On non-Windows builds this always returns an empty string.
*)
procedure _LapeWGCLastError(const Params: PParamArray; const Result: Pointer); LAPE_WRAPPER_CALLING_CONV
begin
  PString(Result)^ := WGCLastError();
end;

(*
WGCFrameCount
-------------
```
function WGCFrameCount: Int64;
```
Total number of frames the WGC FrameArrived handler has successfully
written into the latest-frame buffer since process start. Useful for
diagnostics — confirming the capture pipeline is producing frames at
all without having to call WGCTryGetImage and inspect the result.
*)
procedure _LapeWGCFrameCount(const Params: PParamArray; const Result: Pointer); LAPE_WRAPPER_CALLING_CONV
begin
  PInt64(Result)^ := WGCFrameCount();
end;

procedure ImportCaptureWGC(Script: TSimbaScript);
begin
  with Script.Compiler do
  begin
    DumpSection := 'WGC';

    addGlobalFunc('function WGCLastError: String;', @_LapeWGCLastError);
    addGlobalFunc('function WGCFrameCount: Int64;', @_LapeWGCFrameCount);

    DumpSection := '';
  end;
end;

end.
