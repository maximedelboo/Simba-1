{
  Author: Patch for IDE+script-level RemoteInput auto-pairing
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)
  --------------------------------------------------------------------------
  Auto-pair libremoteinput whenever the active target window becomes a
  Java AWT canvas hosting RuneLite. Hooked from two places:
    * simba.ide_vars.SetWindowSelection — fires when the user picks a
      target via the IDE crosshair (ACA, DTM editor, debug viewer benefit)
    * simba.target.TSimbaTarget.SetWindow — fires when ANY process (the
      IDE or a spawned script subprocess) sets its Target.SetWindow to a
      window handle (so plain `Target.GetImage()` works in scripts without
      requiring WaspLib's fakeinput pairing)

  While paired, the per-process capture path (TSimbaImage.CreateFromWindow
  → SimbaNativeInterface.GetWindowImage) reads pixels from the OpenGL
  framebuffer via the JVM-side injection instead of GDI BitBlt — fixing
  the long-standing "frozen capture when GPU plugin is enabled" issue.

  Windows-only by necessity (libremoteinput is a Windows DLL); the unit
  compiles as a no-op on other platforms.

  The pairing state is held per-process — IDE and each running script have
  separate PairedTarget values, all reading the same shared JVM injection.
}
unit simba.remoteinput_autopair;

{$i simba.inc}

interface

uses
  Classes, SysUtils,
  simba.base;

// Pairs libremoteinput against the new window if it looks like RuneLite;
// otherwise releases any prior pairing. Safe to call repeatedly.
procedure RemoteInputAutoPair(Window: TWindowHandle);

// Returns True if currently paired and a fresh BGRA32 framebuffer was copied
// into ImageData for the given window. Allocates ImageData via ReAllocMem
// (matching the BitBlt path's convention) so the caller's FreeMem works.
function RemoteInputTryGetImage(Window: TWindowHandle; X, Y, Width, Height: Integer; var ImageData: PColorBGRA): Boolean;

// Releases the current pairing (e.g. on shutdown).
procedure RemoteInputRelease();

implementation

{$IFDEF WINDOWS}

uses
  Windows, dynlibs,
  simba.process, simba.vartype_windowhandle, simba.nativeinterface_windows;

type
  // libremoteinput export signatures (cdecl; see libremoteinput64.dll exports)
  TEIOS_Inject_PID    = function(PID: UInt32): UInt32; cdecl;
  TEIOS_PairClient    = function(PID: UInt32): Pointer; cdecl;
  TEIOS_ReleaseTarget = procedure(Target: Pointer); cdecl;
  TEIOS_ReleaseClient = procedure(PID: UInt32); cdecl;
  TEIOS_GetTargetDimensions = procedure(Target: Pointer; out Width, Height: Int32); cdecl;
  TEIOS_GetImageBuffer      = function(Target: Pointer): PByte; cdecl;
  TEIOS_UpdateImageBuffer   = procedure(Target: Pointer); cdecl;
  TEIOS_KillZombieClients   = procedure(); cdecl;

var
  LibHandle: TLibHandle = 0;
  LibProbed: Boolean = False;

  _EIOS_Inject_PID:          TEIOS_Inject_PID;
  _EIOS_PairClient:          TEIOS_PairClient;
  _EIOS_ReleaseTarget:       TEIOS_ReleaseTarget;
  _EIOS_ReleaseClient:       TEIOS_ReleaseClient;
  _EIOS_GetTargetDimensions: TEIOS_GetTargetDimensions;
  _EIOS_GetImageBuffer:      TEIOS_GetImageBuffer;
  _EIOS_UpdateImageBuffer:   TEIOS_UpdateImageBuffer;
  _EIOS_KillZombieClients:   TEIOS_KillZombieClients;

  // Per-process pairing state
  PairedWindow: TWindowHandle = 0;
  PairedPID:    TProcessID    = 0;
  PairedTarget: Pointer       = nil;

function CandidateLibPaths: TStringArray;
var
  Base: String;
begin
  Base := ExtractFilePath(ParamStr(0));
  Result := [
    Base + 'Plugins' + PathDelim + 'wasp-plugins' + PathDelim + 'libremoteinput' + PathDelim + 'libremoteinput64.dll',
    Base + 'Plugins' + PathDelim + 'libremoteinput' + PathDelim + 'libremoteinput64.dll',
    Base + 'libremoteinput64.dll'
  ];
end;

function ProbeLib(): Boolean;
var
  Path: String;
begin
  if LibProbed then
    Exit(LibHandle <> 0);
  LibProbed := True;

  for Path in CandidateLibPaths() do
    if FileExists(Path) then
    begin
      LibHandle := LoadLibrary(PChar(Path));
      if LibHandle <> 0 then
        Break;
    end;

  if LibHandle = 0 then Exit(False);

  _EIOS_Inject_PID          := TEIOS_Inject_PID(GetProcAddress(LibHandle, 'EIOS_Inject_PID'));
  _EIOS_PairClient          := TEIOS_PairClient(GetProcAddress(LibHandle, 'EIOS_PairClient'));
  _EIOS_ReleaseTarget       := TEIOS_ReleaseTarget(GetProcAddress(LibHandle, 'EIOS_ReleaseTarget'));
  _EIOS_ReleaseClient       := TEIOS_ReleaseClient(GetProcAddress(LibHandle, 'EIOS_ReleaseClient'));
  _EIOS_GetTargetDimensions := TEIOS_GetTargetDimensions(GetProcAddress(LibHandle, 'EIOS_GetTargetDimensions'));
  _EIOS_GetImageBuffer      := TEIOS_GetImageBuffer(GetProcAddress(LibHandle, 'EIOS_GetImageBuffer'));
  _EIOS_UpdateImageBuffer   := TEIOS_UpdateImageBuffer(GetProcAddress(LibHandle, 'EIOS_UpdateImageBuffer'));
  _EIOS_KillZombieClients   := TEIOS_KillZombieClients(GetProcAddress(LibHandle, 'EIOS_KillZombieClients'));

  Result := Assigned(_EIOS_Inject_PID) and Assigned(_EIOS_PairClient) and
            Assigned(_EIOS_GetTargetDimensions) and Assigned(_EIOS_GetImageBuffer) and
            Assigned(_EIOS_UpdateImageBuffer);

  if not Result then
  begin
    FreeLibrary(LibHandle);
    LibHandle := 0;
  end;
end;

function LooksLikeRuneLite(Window: TWindowHandle): Boolean;
begin
  Result := False;
  if not Window.IsValid() then Exit;
  if Window.GetClassName() <> 'SunAwtCanvas' then Exit;
  Result := Pos('RuneLite', Window.GetRootWindow().GetTitle()) > 0;
end;

procedure RemoteInputRelease();
var
  Pid: TProcessID;
begin
  Pid := PairedPID;

  // EIOS_ReleaseTarget frees the local Target struct in *this* process.
  // EIOS_ReleaseClient is what tells the JVM-side agent to forget that
  // this PID is paired -- without it the agent thinks we still own the
  // slot and rejects any subsequent pair attempt (from us, from a
  // sibling subprocess, or from WaspLib's fakeinput) with AV.
  if (PairedTarget <> nil) and Assigned(_EIOS_ReleaseTarget) then
  begin
    try
      _EIOS_ReleaseTarget(PairedTarget);
    except
    end;
  end;
  if (Pid <> 0) and Assigned(_EIOS_ReleaseClient) then
  begin
    try
      _EIOS_ReleaseClient(Pid);
    except
    end;
  end;
  if Assigned(_EIOS_KillZombieClients) then
  begin
    try
      _EIOS_KillZombieClients();
    except
    end;
  end;

  PairedTarget := nil;
  PairedPID    := 0;
  PairedWindow := 0;
end;

procedure RemoteInputAutoPair(Window: TWindowHandle);
var
  PID: TProcessID;
  Deadline: QWord;
begin
  // Re-pair only when the window actually changes.
  if Window = PairedWindow then Exit;

  if not LooksLikeRuneLite(Window) then
  begin
    RemoteInputRelease();
    Exit;
  end;

  if not ProbeLib() then Exit;

  PID := Window.GetPID();
  if PID = 0 then Exit;

  // If we were paired to a different PID, release first.
  if (PairedTarget <> nil) and (PID <> PairedPID) then
    RemoteInputRelease();

  try
    _EIOS_Inject_PID(PID);
  except
    // Inject may raise on access-violation if another process owns the
    // JVM-side injection. Fall back to no-op; capture stays on BitBlt.
    Exit;
  end;

  // libremoteinput's inject is mostly synchronous but the JVM-side
  // reflection/agent attach can take a fraction of a second. Retry the
  // pairing with a short deadline — matches the pattern in
  // WaspLib/fakeinput.simba.
  Deadline := GetTickCount64() + 2500;
  repeat
    try
      PairedTarget := _EIOS_PairClient(PID);
    except
      PairedTarget := nil;
    end;
    if PairedTarget <> nil then Break;
    Sleep(100);
  until GetTickCount64() > Deadline;

  if PairedTarget = nil then Exit;

  PairedPID    := PID;
  PairedWindow := Window;
end;

function RemoteInputTryGetImage(Window: TWindowHandle; X, Y, Width, Height: Integer; var ImageData: PColorBGRA): Boolean;
var
  SrcW, SrcH, Row: Int32;
  Src: PByte;
  DstRow: PColorBGRA;
  SrcRow: PByte;
begin
  Result := False;
  if (PairedTarget = nil) or (Window <> PairedWindow) then Exit;
  if (Width <= 0) or (Height <= 0) then Exit;

  try
    _EIOS_UpdateImageBuffer(PairedTarget);
    _EIOS_GetTargetDimensions(PairedTarget, SrcW, SrcH);
    Src := _EIOS_GetImageBuffer(PairedTarget);
  except
    Exit;
  end;

  if (Src = nil) or (SrcW <= 0) or (SrcH <= 0) then Exit;

  // Clip requested rect into source bounds; out-of-bounds → fall back.
  if (X < 0) or (Y < 0) or (X + Width > SrcW) or (Y + Height > SrcH) then Exit;

  // Allocate the output buffer (caller will FreeMem it). Same allocator as
  // the BitBlt path uses (ReAllocMem at simba.nativeinterface_windows.pas
  // line ~322), so memory is interchangeable with the existing teardown.
  ReAllocMem(ImageData, Width * Height * SizeOf(TColorBGRA));

  // libremoteinput's framebuffer is BGRA32, row-major, top-down, tightly
  // packed at SrcW*4 bytes per row. Copy the requested subrect.
  for Row := 0 to Height - 1 do
  begin
    SrcRow := Src + ((Y + Row) * SrcW + X) * SizeOf(TColorBGRA);
    DstRow := ImageData;
    Inc(DstRow, Row * Width);
    Move(SrcRow^, DstRow^, Width * SizeOf(TColorBGRA));
  end;

  Result := True;
end;

initialization
  // Register ourselves as the GetWindowImage hook so the per-process
  // capture path tries RemoteInput before BitBlt.
  simba.nativeinterface_windows.GetWindowImageHook := @RemoteInputTryGetImage;

finalization
  RemoteInputRelease();
  if LibHandle <> 0 then
  begin
    FreeLibrary(LibHandle);
    LibHandle := 0;
  end;

{$ELSE}

// Non-Windows: no-op stubs so the unit compiles cross-platform.
procedure RemoteInputAutoPair(Window: TWindowHandle);
begin
end;

function RemoteInputTryGetImage(Window: TWindowHandle; X, Y, Width, Height: Integer; var ImageData: PColorBGRA): Boolean;
begin
  Result := False;
end;

procedure RemoteInputRelease();
begin
end;

{$ENDIF}

end.
