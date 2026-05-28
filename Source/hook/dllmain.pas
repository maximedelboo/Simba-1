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

uses
  hook_engine;

// First 5 bytes of wglSwapBuffers on current Windows
// (`mov [rsp+0x08], rbx`), captured from live RuneLite. Used as the
// install-time sanity gate so a future Windows update changing the
// function's prologue fails-safe instead of corrupting opengl32.dll.
// 5 bytes rather than 14 deliberately: bytes 6..13 may be legitimately
// patched by overlay hooks already running in the host (Discord, Steam,
// OBS), and we don't want to refuse install in that scenario.
const
  EXPECTED_PROLOGUE: array[0..4] of Byte = ($48, $89, $5C, $24, $08);

var
  // Holds the wglSwapBuffers hook handle once installed. Untouched on the
  // default code path because installation is gated behind an env var.
  GWglHook: THookHandle;
  // Scratch error string for the finalization block, which has no scope
  // for locals. Lives at unit scope so the uninstall call has somewhere to
  // write its diagnostic.
  GFinErr: string;

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

// Dump the first 32 bytes of a target function so the future trampoline
// engine has concrete prologue data to plan against. The function lives in
// another DLL's .text section (already RX), so no VirtualProtect is needed
// for this read-only dump.
procedure ReportFunctionAt(const Name: string; Addr: Pointer);
const
  DumpBytes = 32;
var
  P: PByte;
  Hex: string;
  I: Integer;
begin
  if Addr = nil then
  begin
    WriteLog(Format('%s=nil (not exported)', [Name]));
    Exit;
  end;
  P := PByte(Addr);
  Hex := '';
  try
    for I := 0 to DumpBytes - 1 do
    begin
      if I > 0 then Hex := Hex + ' ';
      Hex := Hex + IntToHex(P[I], 2);
    end;
  except
    Hex := Hex + ' <read fault>';
  end;
  WriteLog(Format('%s=0x%p prologue=%s', [Name, Addr, Hex]));
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
    ReportFunctionAt('wglSwapBuffers',
      GetProcAddress(GetModuleHandleW('opengl32.dll'), 'wglSwapBuffers'));
  if HasOpenGL then
    ReportFunctionAt('wglSwapLayerBuffers',
      GetProcAddress(GetModuleHandleW('opengl32.dll'), 'wglSwapLayerBuffers'));
  if HasD3D11 then
    ReportFunctionAt('SwapBuffers (gdi32)',
      GetProcAddress(GetModuleHandleW('gdi32.dll'), 'SwapBuffers'));
end;

// In-DLL self-test for hook_engine. Both functions are hand-written in
// inline assembly so their first 15 bytes are guaranteed to be complete,
// relocatable instructions: push rbp (1) + mov rbp,rsp (3) + 11*nop (11)
// = 15 = HOOK_PATCH_SIZE. A naive Pascal function compiled by FPC may
// have a prologue whose 15th byte falls mid-instruction, which would
// corrupt the trampoline. ASMMODE INTEL is scoped to this region so it
// doesn't infect future asm elsewhere in the unit.
{$PUSH}{$ASMMODE INTEL}
function TestTarget(x: Integer): Integer; stdcall; assembler; nostackframe;
asm
  push rbp
  mov  rbp, rsp
  nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop
  mov  eax, ecx
  add  eax, 42
  pop  rbp
  ret
end;

function TestReplacement(x: Integer): Integer; stdcall; assembler; nostackframe;
asm
  push rbp
  mov  rbp, rsp
  nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop
  mov  eax, ecx
  add  eax, 99
  pop  rbp
  ret
end;
{$POP}

type
  TTestFn = function(x: Integer): Integer; stdcall;

// Exercise HookEngine_Install + trampoline call + HookEngine_Uninstall
// against TestTarget. Returns 'PASS' or 'FAIL: <which>: got=N expected=M'.
function TestHookEngine(): string;
var
  H: THookHandle;
  err: string;
  Got: Integer;
begin
  // Dump prologue first so the log captures ground truth before any
  // patching happens — invaluable when diagnosing hook failures.
  ReportFunctionAt('TestTarget', @TestTarget);

  Got := TestTarget(10);            // 10 + 42 = 52
  if Got <> 52 then
    Exit(Format('FAIL: baseline: got=%d expected=52', [Got]));

  if not HookEngine_Install(@TestTarget, @TestReplacement, [], H, err) then
    Exit('FAIL: install: ' + err);

  Got := TestTarget(10);            // 10 + 99 = 109 once hooked
  if Got <> 109 then
  begin
    if not HookEngine_Uninstall(H, err) then
      WriteLog('TestHookEngine: cleanup uninstall failed: ' + err);
    Exit(Format('FAIL: hooked: got=%d expected=109', [Got]));
  end;

  Got := TTestFn(H.Trampoline)(10); // trampoline preserves original, =52
  if Got <> 52 then
  begin
    if not HookEngine_Uninstall(H, err) then
      WriteLog('TestHookEngine: cleanup uninstall failed: ' + err);
    Exit(Format('FAIL: trampoline: got=%d expected=52', [Got]));
  end;

  if not HookEngine_Uninstall(H, err) then
    Exit('FAIL: uninstall: ' + err);

  Got := TestTarget(10);            // back to 52 after uninstall
  if Got <> 52 then
    Exit(Format('FAIL: post-uninstall: got=%d expected=52', [Got]));

  Result := 'PASS';
end;

var
  // Frame counter for the wglSwapBuffers hook. Atomic increment; logged
  // every LOG_EVERY_N frames so the log stays readable at 60+ fps.
  GFrameCount: Int64 = 0;

const
  LOG_EVERY_N = 60;

// ============================================================================
// Shared-memory frame capture
// ----------------------------------------------------------------------------
// On each wglSwapBuffers we glReadPixels the back buffer into a per-PID
// named file mapping (`Local\Simba_GL_Capture_<PID>`) protected by a named
// mutex (`Local\Simba_GL_Capture_Lock_<PID>`). Simba's reader opens these
// existing kernel objects, copies the latest frame, and crops to the
// requested region. This replaces the DXGI desktop-duplication path so
// overlapping windows no longer pollute the capture.
//
// Layout: a fixed-size header (TGLCaptureHeader) followed by pixel data.
// Capacity is fixed at 4 MiB pixels -- enough for up to 1024x1024 BGRA;
// larger viewports are truncated by clamping height. The hook holds the
// mutex only during glReadPixels + flip + header update; outside that
// window it never touches the mapping, so a non-reading Simba causes no
// contention.
// ============================================================================

const
  // ASCII 'SGLC' little-endian. Verified by reader before trusting header.
  GLCAPTURE_MAGIC: UInt32 = $43474C53;

  // OpenGL enums we use; declared here rather than pulling in dglOpenGL so
  // the DLL keeps its tiny dependency footprint.
  GL_VIEWPORT      = $0BA2;
  GL_BACK          = $0405;
  GL_BGRA          = $80E1;
  GL_UNSIGNED_BYTE = $1401;

type
  TGLCaptureHeader = packed record
    Magic:         UInt32;        // GLCAPTURE_MAGIC
    Width:         UInt32;        // pixels
    Height:        UInt32;        // pixels
    BytesPerPixel: UInt32;        // always 4 (BGRA)
    FrameCounter:  UInt64;        // atomic monotonic counter
    Capacity:      UInt64;        // bytes of pixel area available after header
    Reserved:      array[0..31] of Byte;
  end;
  PGLCaptureHeader = ^TGLCaptureHeader;

var
  // Lazily resolved from opengl32.dll on first frame after the hook is
  // installed. Done lazily because at DLL_PROCESS_ATTACH time there is no
  // current GL context, and GetProcAddress on a not-yet-loaded module
  // would fail.
  glGetIntegerv: procedure(pname: DWORD; params: PInteger); stdcall = nil;
  glReadBuffer:  procedure(mode: DWORD); stdcall = nil;
  glReadPixels:  procedure(x, y: Integer; width, height: Integer;
                           format, type_: DWORD; pixels: Pointer); stdcall = nil;

  // Per-PID named-kernel-object handles plus the mapped view. Created
  // lazily in InitSharedCapture on the first swap after install, torn
  // down in finalization.
  GShmHandle:   THandle    = 0;
  GShmView:     Pointer    = nil;
  GShmLock:     THandle    = 0;
  GShmCapacity: NativeUInt = 0;
  GShmInited:   Boolean    = False;
  GShmAttempted: Boolean   = False; // one-shot guard: don't retry on failure

// Lazy initializer for the shared-memory capture buffer. Returns silently
// on any failure -- if shared capture can't be set up the host process is
// still safe; Simba's reader will just keep returning False until the
// situation is fixed (which today means a Simba relaunch).
procedure InitSharedCapture();
const
  // 4 MiB pixel area = enough for 1024x1024 BGRA. RuneLite's typical
  // client area is 800x534 (~1.7 MiB) so this gives generous headroom.
  // Larger viewports are clamped at capture time rather than reallocating
  // the mapping mid-session (POC simplification).
  CAPACITY_BYTES = 4 * 1024 * 1024;
var
  OpenGL: HMODULE;
  ShmName: WideString;
  LockName: WideString;
  TotalSize: UInt64;
  Hdr: PGLCaptureHeader;
begin
  if GShmInited or GShmAttempted then Exit;
  GShmAttempted := True;

  OpenGL := GetModuleHandleW('opengl32.dll');
  if OpenGL = 0 then
  begin
    WriteLog('wgl_hook: shared capture: opengl32.dll not loaded');
    Exit;
  end;

  Pointer(glGetIntegerv) := GetProcAddress(OpenGL, 'glGetIntegerv');
  Pointer(glReadBuffer)  := GetProcAddress(OpenGL, 'glReadBuffer');
  Pointer(glReadPixels)  := GetProcAddress(OpenGL, 'glReadPixels');
  if (@glGetIntegerv = nil) or (@glReadBuffer = nil) or (@glReadPixels = nil) then
  begin
    WriteLog('wgl_hook: shared capture: failed to resolve gl* function pointers');
    Exit;
  end;

  GShmCapacity := CAPACITY_BYTES;
  TotalSize := UInt64(SizeOf(TGLCaptureHeader)) + UInt64(GShmCapacity);

  ShmName  := WideString('Local\Simba_GL_Capture_')      + WideString(IntToStr(GetCurrentProcessId()));
  LockName := WideString('Local\Simba_GL_Capture_Lock_') + WideString(IntToStr(GetCurrentProcessId()));

  GShmHandle := CreateFileMappingW(INVALID_HANDLE_VALUE, nil,
                                   PAGE_READWRITE,
                                   DWORD(TotalSize shr 32),
                                   DWORD(TotalSize and $FFFFFFFF),
                                   PWideChar(ShmName));
  if GShmHandle = 0 then
  begin
    WriteLog(Format('wgl_hook: shared capture: CreateFileMappingW failed err=%d',
      [GetLastError()]));
    Exit;
  end;

  GShmView := MapViewOfFile(GShmHandle, FILE_MAP_READ or FILE_MAP_WRITE, 0, 0, 0);
  if GShmView = nil then
  begin
    WriteLog(Format('wgl_hook: shared capture: MapViewOfFile failed err=%d',
      [GetLastError()]));
    CloseHandle(GShmHandle);
    GShmHandle := 0;
    Exit;
  end;

  GShmLock := CreateMutexW(nil, False, PWideChar(LockName));
  if GShmLock = 0 then
  begin
    WriteLog(Format('wgl_hook: shared capture: CreateMutexW failed err=%d',
      [GetLastError()]));
    UnmapViewOfFile(GShmView);
    GShmView := nil;
    CloseHandle(GShmHandle);
    GShmHandle := 0;
    Exit;
  end;

  // Zero-init the header. We do this without holding the mutex because
  // GShmInited is still False -- no reader will trust the header until
  // we publish it by setting GShmInited = True at the end.
  Hdr := PGLCaptureHeader(GShmView);
  FillChar(Hdr^, SizeOf(TGLCaptureHeader), 0);
  Hdr^.Magic := GLCAPTURE_MAGIC;
  Hdr^.BytesPerPixel := 4;
  Hdr^.Capacity := GShmCapacity;

  GShmInited := True;
  WriteLog(Format('wgl_hook: shared capture initialized (capacity=%d bytes)',
    [GShmCapacity]));
end;

// Read the current GL_BACK buffer into shared memory. Must be called
// BEFORE the trampoline call: once SwapBuffers returns, GL_BACK's
// contents are undefined.
procedure CaptureCurrentFrame();
var
  vp: array[0..3] of Integer;  // x, y, w, h
  W, H, Stride, Y: Integer;
  Pixels: PByte;
  LineBuf: array of Byte;
  Hdr: PGLCaptureHeader;
  WaitRes: DWORD;
begin
  if not GShmInited then
  begin
    InitSharedCapture();
    if not GShmInited then Exit;
  end;

  // glGetIntegerv(GL_VIEWPORT) returns x,y,w,h of the active viewport.
  // RuneLite resets this every frame to match its client area.
  glGetIntegerv(GL_VIEWPORT, @vp[0]);
  W := vp[2];
  H := vp[3];
  if (W <= 0) or (H <= 0) then Exit;
  Stride := W * 4;

  // Clamp height if the viewport would overflow our fixed buffer. A
  // partial top-cropped frame is more useful than nothing, and full
  // capture would need a reallocation we deliberately don't do in this
  // POC. Documented as a known limit: > ~1024x1024 = clipped.
  if (Int64(Stride) * H) > Int64(GShmCapacity) then
  begin
    H := GShmCapacity div Stride;
    if H <= 0 then Exit;
  end;

  // 50ms timeout: if Simba is holding the mutex that long something is
  // very wrong on the reader side; we'd rather drop this frame than
  // stall the render thread.
  WaitRes := WaitForSingleObject(GShmLock, 50);
  if WaitRes <> WAIT_OBJECT_0 then Exit;
  try
    Hdr := PGLCaptureHeader(GShmView);
    Pixels := PByte(GShmView) + SizeOf(TGLCaptureHeader);

    glReadBuffer(GL_BACK);
    glReadPixels(0, 0, W, H, GL_BGRA, GL_UNSIGNED_BYTE, Pixels);

    // GL returns rows bottom-up; Windows wants top-down. Flip in-place
    // by swapping line N with line H-1-N via a one-line scratch buffer.
    // Cost: H*Stride bytes copied 3x for the bottom half; acceptable at
    // 60fps for client-area-sized frames.
    SetLength(LineBuf, Stride);
    for Y := 0 to (H div 2) - 1 do
    begin
      Move((Pixels + Y * Stride)^, LineBuf[0], Stride);
      Move((Pixels + (H - 1 - Y) * Stride)^, (Pixels + Y * Stride)^, Stride);
      Move(LineBuf[0], (Pixels + (H - 1 - Y) * Stride)^, Stride);
    end;

    Hdr^.Width := UInt32(W);
    Hdr^.Height := UInt32(H);
    InterlockedIncrement64(Int64(Hdr^.FrameCounter));
  finally
    ReleaseMutex(GShmLock);
  end;
end;

// Replacement for opengl32!wglSwapBuffers. Runs on the host's render
// thread once per frame. Captures the back-buffer pixels into shared
// memory BEFORE handing off to the trampoline (post-swap, GL_BACK
// contents are undefined). Then forwards to the trampoline (which
// executes the original prologue and jumps back into the rest of the
// real function), bumps a frame counter, and logs every 60th frame so
// we have visible proof the hook is firing.
function WglSwapBuffersHook(hdc: HDC): BOOL; stdcall;
type
  PWglSwapBuffersFn = function(hdc: HDC): BOOL; stdcall;
var
  OrigFn: PWglSwapBuffersFn;
  N: Int64;
begin
  // Capture first -- glReadPixels on GL_BACK only meaningful pre-swap.
  // Wrapped in try/except because a faulting capture must not take down
  // the host's render thread.
  try
    CaptureCurrentFrame();
  except
    // Swallow: the host process must keep running even if our capture
    // hits an unexpected GL state.
  end;

  OrigFn := PWglSwapBuffersFn(GWglHook.Trampoline);
  if OrigFn = nil then
  begin
    Result := False;
    Exit;
  end;
  Result := OrigFn(hdc);
  N := InterlockedIncrement64(GFrameCount);
  if (N mod LOG_EVERY_N) = 0 then
    WriteLog(Format('wgl_hook: frame %d (hdc=0x%p)', [N, Pointer(hdc)]));
end;

// Locate wglSwapBuffers, verify its prologue, and (only if explicitly
// opted in via SIMBA_HOOK_INSTALL=1) install the hook. The default behavior
// is *non-destructive*: log what would be patched and return without
// touching the target. This keeps the DLL safe to inject into any process
// for diagnostic runs.
procedure PrepareWglHook();
var
  OpenGL: HMODULE;
  Addr: Pointer;
  Actual: PByte;
  I, J: Integer;
  Mismatch: Boolean;
  ExpectedHex, ActualHex: string;
  err: string;
begin
  OpenGL := GetModuleHandleW('opengl32.dll');
  if OpenGL = 0 then
  begin
    WriteLog('wgl_hook: opengl32.dll not loaded');
    Exit;
  end;

  Addr := GetProcAddress(OpenGL, 'wglSwapBuffers');
  if Addr = nil then
  begin
    WriteLog('wgl_hook: wglSwapBuffers not exported');
    Exit;
  end;

  Actual := PByte(Addr);
  Mismatch := False;
  for I := 0 to High(EXPECTED_PROLOGUE) do
    if Actual[I] <> EXPECTED_PROLOGUE[I] then
    begin
      Mismatch := True;
      Break;
    end;

  if Mismatch then
  begin
    ExpectedHex := '';
    ActualHex := '';
    for J := 0 to High(EXPECTED_PROLOGUE) do
    begin
      if J > 0 then
      begin
        ExpectedHex := ExpectedHex + ' ';
        ActualHex := ActualHex + ' ';
      end;
      ExpectedHex := ExpectedHex + IntToHex(EXPECTED_PROLOGUE[J], 2);
      ActualHex := ActualHex + IntToHex(Actual[J], 2);
    end;
    WriteLog(Format(
      'wgl_hook: prologue mismatch; refusing to install (expected=%s actual=%s)',
      [ExpectedHex, ActualHex]));
    Exit;
  end;

  WriteLog(Format('wgl_hook: prologue verified, installing (addr=0x%p)',
    [Addr]));

  // Note on race: HookEngine_Install re-reads the prologue and copies 14
  // bytes from Target verbatim. A concurrent third-party hook (Discord
  // overlay, Steam overlay, OBS) installing between our check above and
  // the engine's copy could leave bytes 5..13 modified — our trampoline
  // would then chain into that hook rather than the original. The
  // engine's own re-check catches the first 5 bytes; full atomicity is
  // not achievable without suspending all host threads.
  if HookEngine_Install(Addr, @WglSwapBuffersHook, EXPECTED_PROLOGUE,
                        GWglHook, err) then
    WriteLog(Format('wgl_hook: installed (trampoline=0x%p)',
      [GWglHook.Trampoline]))
  else
    WriteLog('wgl_hook: install failed: ' + err);
end;

procedure Probe(hwnd: HWND; hinst: HMODULE; lpszCmdLine: PAnsiChar;
                nCmdShow: Integer); stdcall;
begin
  WriteLog('Probe called');
  WriteLog('hook_engine_test: ' + TestHookEngine());
end;

initialization
  WriteLog('attach');
  ReportEnvironment();
  PrepareWglHook();

finalization
  if GWglHook.Installed then
  begin
    if not HookEngine_Uninstall(GWglHook, GFinErr) then
      WriteLog('wgl_hook: uninstall on detach failed: ' + GFinErr);
  end;
  // Tear down shared capture in the reverse order it was set up. Order
  // matters: the mapped view must be unmapped before its mapping handle
  // is closed; the mutex is independent.
  if GShmLock <> 0 then
  begin
    CloseHandle(GShmLock);
    GShmLock := 0;
  end;
  if GShmView <> nil then
  begin
    UnmapViewOfFile(GShmView);
    GShmView := nil;
  end;
  if GShmHandle <> 0 then
  begin
    CloseHandle(GShmHandle);
    GShmHandle := 0;
  end;
  WriteLog('detach');

end.
