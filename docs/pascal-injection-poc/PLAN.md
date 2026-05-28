# Pure-Pascal DLL injection POC — execution plan

## Goal of this branch (POC scope only)

Prove the foundational primitive: **a Pascal-compiled DLL can be embedded in
Simba's exe as a resource, written into a target Windows process's address
space, and successfully execute code there** — using only Win32 APIs that ship
on every Windows machine.

This is the load-bearing piece. Without it, the OpenGL `wglSwapBuffers` hook,
WGL_NV_DX_interop2, shared D3D11 texture export, and IPC plumbing all build on
this base. If the injection primitive doesn't work cleanly the whole project
fails; if it works, the rest is well-understood mechanical work.

**Out of scope for this branch (deferred):**
- `wglSwapBuffers` hook (inline trampoline + length disassembler)
- D3D11 device + WGL_NV_DX_interop2 + shared texture export
- Capture protocol over named pipe
- Integration with Simba's capture backend chain
- Reflective DLL loader (skip standard `LoadLibrary`)

The POC stops once we have a working `Inject(pid, dllBytes)` that gets a
Pascal-built DLL loaded into Notepad and observably executing.

## Architecture

```
Simba-Win64.exe (Pascal, already exists)
├── Source/simba.inject.pas                   [NEW]   inject + remote LoadLibrary
├── Source/hook/simba_gl_hook.lpr             [NEW]   the DLL source
├── Source/hook/simba_gl_hook.lpi             [NEW]   Lazarus project file
├── Source/hook/dllmain.pas                   [NEW]   DllMain + test code
└── (embedded resource)                       built-in PE resource RCDATA "HOOK64"
   ↓
   simba_gl_hook.dll bytes
```

At Simba build time:
1. The hook DLL is compiled first (FPC/lazbuild).
2. The DLL binary is included in Simba's main exe via a `.rc` resource script
   that gets compiled into `Simba.res`.
3. At runtime, the injector reads the DLL bytes from its own resources, writes
   them to a temp file (POC simplification — reflective loading is a phase 2
   item that skips this step), and calls `LoadLibraryW` in the target via
   `CreateRemoteThread`.

## Phased work

### Phase 0 — Scaffolding (done in this commit)
- New branch `pascal-injection-poc` off `dxgi-capture-backend`
- `docs/pascal-injection-poc/PLAN.md` (this file)
- Empty `Source/hook/` directory
- Empty `Source/test/inject/` directory

### Phase 1 — Build a minimal Pascal hook DLL
**Acceptance:** `simba_gl_hook.dll` builds cleanly via `lazbuild` and, if
loaded by any process (e.g. via `rundll32 simba_gl_hook.dll,Probe`), writes a
log line to `%TEMP%\simba_hook.log` containing PID, timestamp, and module base.

Files:
- `Source/hook/simba_gl_hook.lpr` — `library` declaration, exports `Probe`
- `Source/hook/simba_gl_hook.lpi` — Lazarus project file targeting Win64 DLL
- `Source/hook/dllmain.pas` — `DllMain`-style entry + Probe export + logger

### Phase 2 — Embed the DLL into Simba's main exe
**Acceptance:** Simba's existing `.res` (or a separate resource) now contains
the compiled hook DLL as `RCDATA`. The bytes can be read back at runtime via
`FindResource` / `LoadResource` / `LockResource` and match the file on disk.

Files:
- `Source/hook/build_dll_resource.bat` — runs after DLL build to refresh the
  `.rc` file referenced by Simba's main `.res`
- New resource script `Source/hook/simba_hook.rc` referencing the built DLL
- Modifications to Simba's existing `simba.rc` (or a sibling `.rc` include)

### Phase 3 — Pascal injector
**Acceptance:** A standalone test exe (`Source/test/inject/test_inject.lpr`)
takes a PID, extracts the embedded hook DLL bytes, writes to `%TEMP%`, calls
the injector, and the target process's `%TEMP%\simba_hook.log` shows a fresh
line within 1 second of injection.

Files:
- `Source/simba.inject.pas`:
  - `function InjectDllFromResource(pid: DWORD; resName: PWideChar): Boolean;`
  - Internally: `FindResource` → `LoadResource` → `LockResource` → write to
    `%TEMP%\<random>.dll` → `OpenProcess(PROCESS_CREATE_THREAD or _VM_OPERATION
    or _VM_WRITE or _VM_READ or _QUERY_INFORMATION)` → `VirtualAllocEx` for the
    path string → `WriteProcessMemory(path)` →
    `CreateRemoteThread(LoadLibraryW, path)` → wait for thread exit → check
    return value (HMODULE).
- `Source/test/inject/test_inject.lpr` — calls the above with a PID arg

Failure modes to handle gracefully:
- Target process is 32-bit (we're a 64-bit injector) → error message, don't
  try.
- Target process is from a higher integrity level (admin) → `OpenProcess`
  fails → clear error.
- Target process refuses LoadLibrary (returns NULL HMODULE) → log GetLastError
  remotely if we can.

### Phase 4 — Verify on Notepad
**Acceptance:** Open Notepad. Run `test_inject.exe <notepad-pid>`. Confirm:
1. `%TEMP%\simba_hook.log` has a fresh entry.
2. Notepad does not crash.
3. The log entry contains the expected PID and module base.

Probably done as a manual scripted run, not an automated test, given the
process-spawning involved.

### Phase 5 — (Stretch) Reflective loading
If time permits after the above lands clean, replace the
"write-to-temp-and-LoadLibrary" with proper reflective loading: walk PE
headers, allocate target-side memory, copy sections, fix relocations, resolve
imports, call DllMain manually. This avoids the temp file but is significantly
more code and is the right place to stop if running short on time.

Files (if attempted):
- `Source/simba.inject_reflective.pas` — the loader, written as a function
  block that gets `WriteProcessMemory`'d into the target and run via
  `CreateRemoteThread` with the DLL bytes as its argument.

### Phase 6 — Document next steps
A `NEXT_STEPS.md` in `docs/pascal-injection-poc/` describes what would come
after this POC:
- Inline hook engine (DDetours-style or hand-rolled w/ minimal length
  disassembler) — install hook on `wglSwapBuffers`
- D3D11 device + WGL_NV_DX_interop2 inside the hook DLL
- Shared texture export over named pipe back to Simba
- Wiring this as an opt-in third capture backend alongside DXGI

## Risks specific to this POC

| Risk | Likelihood | Mitigation |
|---|---|---|
| FPC RTL init in a DLL injected via standard LoadLibrary causes weirdness | Low | Standard LoadLibrary runs the loader normally; RTL init should work. Only reflective loading risks this. |
| Simba's `.rc` / `.res` build chain is rigid and adding a resource breaks it | Medium | Add to a sibling `.rc` if the main one is auto-generated; document explicitly. |
| Some AV/EDR on dev machine flags the injection | Medium | Test only against Notepad on dev machine; user controls Defender exclusions for Simba. |
| 32-bit target needs a 32-bit hook DLL too — out of scope for POC | n/a | Phase 4 tests against 64-bit Notepad. RuneLite is 64-bit. |

## What "success" looks like at end of this session

Minimum viable: Phase 1 + Phase 2 + at least Phase 3 partial.

Stretch: Phase 1-4 working, log file appears after Notepad injection, single
commit pushed to `pascal-injection-poc` on both forks.

Maximum: Phase 1-5 working including reflective loading, with a clean
`NEXT_STEPS.md`.

## Build commands (Win64)

Hook DLL — produces `Source/hook/simba_gl_hook.exe` (PE characteristics
mark it as a DLL despite the extension; rename to `.dll`):
```
"C:/fpcup/lazarus/lazbuild.exe" --build-mode=Default Source/hook/simba_gl_hook.lpi
move Source/hook/simba_gl_hook.exe Source/hook/simba_gl_hook.dll
```

Regenerate the embedded resource after the DLL is rebuilt:
```
"C:/fpcup/fpc/bin/x86_64-win64/windres.exe" --preprocessor="cmd /c type" \
    -i Source/hook/simba_hook.rc -o Source/hook/simba_hook.res \
    -O coff -F pe-x86-64
```

Test harness — automatically picks up the refreshed `.res` via `{$R}`:
```
"C:/fpcup/lazarus/lazbuild.exe" --build-mode=Default Source/test/inject/test_inject.lpi
```

End-to-end smoke test (PowerShell):
```
$p = Start-Process notepad.exe -PassThru
& 'Source/test/inject/test_inject.exe' $p.Id
Get-Content "$env:TEMP\simba_hook.log"
$p.CloseMainWindow()
```
