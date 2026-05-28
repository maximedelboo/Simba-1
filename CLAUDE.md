# CLAUDE.md

Context for future Claude sessions working on this Simba fork. Read this
before doing anything substantive.

## TL;DR

This is a fork of [Villavu/Simba](https://github.com/Villavu/Simba) (the
Pascal/FPC-built IDE used for OSRS automation). The fork explores
**alternative window-capture backends** to replace the default GDI `BitBlt`
path, which is fundamentally broken for any window using OpenGL / DX /
Vulkan — including RuneLite with its GPU plugin enabled.

Multiple capture approaches have been built out as parallel branches.
**`pascal-injection-poc` is the current state of the art**: a pure-Pascal
DLL injected into RuneLite that inline-hooks `wglSwapBuffers`, captures
the framebuffer with `glReadPixels`, and exposes it via named shared
memory for Simba to read.

## Repo on disk

- Working dir: `C:\Users\maxim\Documents\projects\sima2k conversion\Simba-2.0`
- Two forks tracked as remotes:
  - `fork` → `https://github.com/maximedelboo/Simba-remoteinput-autopair.git`
  - `upstream-fork` → `https://github.com/maximedelboo/Simba-1.git`
- `origin` → `https://github.com/Villavu/Simba.git` (upstream, read-only)
- Always push to both `fork` and `upstream-fork`.

## Branch landscape

| Branch | What | Status |
|---|---|---|
| `simba2000` | Baseline before any capture work | Frozen reference |
| `wgc-capture-backend` | Windows.Graphics.Capture (pure Pascal WinRT) | Works but has yellow border on Win10 (Microsoft gated `IsBorderRequired` to Win11) |
| `dxgi-capture-backend` | DXGI Desktop Duplication (pure Pascal) | Works on all Win10+, no border, no cursor, but per-monitor so overlapping windows contaminate the capture |
| `ide-remoteinput-autopair` | Auto-loads libremoteinput JNI for SunAwtCanvas targets | Works for RuneLite only; rejected upstream historically |
| **`pascal-injection-poc`** | **Pascal-native DLL injection + inline `wglSwapBuffers` hook + shared-memory readback** | **CURRENT WORK; fully functional against RuneLite** |

Each branch has its own design doc tree under `docs/<branch-name>/`.

## Branch ancestry

```
main (Villavu/Simba upstream)
  │
  ├── simba2000           (frozen reference)
  │
  ├── ide-remoteinput-autopair  (libremoteinput JNI auto-pair)
  │
  └── wgc-capture-backend       (WinRT WGC)
       │
       └── dxgi-capture-backend (DXGI desktop duplication)
            │
            └── pascal-injection-poc  ← we are here
```

`pascal-injection-poc` doesn't include the `ide-remoteinput-autopair`
work. The two are orthogonal: an RI plugin can be script-loaded on top
of `pascal-injection-poc` and they coexist without conflict (see
"Coexistence with the RI plugin" section below).

---

# Current state: `pascal-injection-poc`

## Architecture

```
RuneLite render thread (in RuneLite.exe)
    │
    │  wglSwapBuffers() ──► our inline hook (15-byte abs-jmp patch)
    │                       │
    │                       ├─ glGetIntegerv not used (was a bug)
    │                       ├─ wnd = WindowFromDC(hdc)
    │                       ├─ GetClientRect(wnd) → W, H  (stable across swaps)
    │                       ├─ WaitForSingleObject(GShmLock, 50ms)
    │                       ├─ glReadBuffer(GL_BACK)
    │                       ├─ glReadPixels(0,0,W,H, GL_BGRA, GL_UNSIGNED_BYTE → shmem+64)
    │                       ├─ in-place vertical flip (GL bottom-up → Windows top-down)
    │                       ├─ shmem header: Width, Height, InterlockedIncrement(FrameCounter)
    │                       ├─ ReleaseMutex
    │                       └─ trampoline → real wglSwapBuffers
    │
    │ frame goes to DWM ──► screen
    
Simba.exe (separate process)
    │
    │ User picks target → SetWindowSelection / TSimbaTarget.SetWindow
    │                       │
    │                       └─ GLHookAutoInject(window)
    │                            ├─ GetWindowThreadProcessId → PID
    │                            ├─ self-injection guard, dedup against GInjectedPids
    │                            └─ InjectDllFromResource(PID, 'HOOK64', err)
    │                                 ├─ FindResource(HOOK64 RCDATA) → DLL bytes
    │                                 ├─ Write to %TEMP%\simba_hook_<guid>.dll
    │                                 ├─ OpenProcess + VirtualAllocEx + WriteProcessMemory(path)
    │                                 └─ CreateRemoteThread(LoadLibraryW, path)
    │
    │ Target.GetImage() → GetWindowImage → GLHookTryGetImage(window)
    │                                       ├─ OpenMutex(Local\Simba_GL_Capture_Lock_<PID>)
    │                                       ├─ OpenFileMapping(Local\Simba_GL_Capture_<PID>)
    │                                       ├─ Wait(mutex, 50ms)
    │                                       ├─ verify 'SGLC' magic, read W, H
    │                                       ├─ allocate ImageData via GetMem
    │                                       ├─ memcpy cropped region row-by-row
    │                                       └─ release mutex, unmap, close handles
```

## Shared memory protocol

Named per-PID resources:
- File mapping: `Local\Simba_GL_Capture_<PID>` (4 MiB + 64-byte header)
- Mutex: `Local\Simba_GL_Capture_Lock_<PID>`

Header layout (first 64 bytes of the mapping):
```
offset  size  field
   0     4    Magic: u32 = 0x43474C53 ('SGLC' little-endian)
   4     4    Width: u32
   8     4    Height: u32
  12     4    BytesPerPixel: u32 = 4
  16     8    FrameCounter: u64 (atomic, ++ on each hook write)
  24     8    Capacity: u64 (bytes available for pixel data)
  32    32    reserved (zero-init)
  64    ...   BGRA pixel data, top-down (flipped on write)
```

Capacity is fixed at 4 MiB at install — enough for ~1024×1024 BGRA. If
RuneLite's client area exceeds this we clamp height. No reallocation
logic.

## Hook engine internals

`Source/hook/hook_engine.pas` — ~280-line pure-Pascal inline hooker.

**Patch encoding** (15 bytes, exactly `HOOK_PATCH_SIZE`):
```
48 B8 <imm64>  movabs rax, imm64     (10 bytes)
FF E0          jmp rax               (2 bytes)
90 90 90       padding NOPs          (3 bytes)
```

Sized at **15, not 14** — see commit `c092c796`. The first four
instructions of `opengl32!wglSwapBuffers` are:
```
48 89 5C 24 08   mov [rsp+0x08], rbx  (5 bytes)
48 89 74 24 10   mov [rsp+0x10], rsi  (5 bytes)
57               push rdi             (1 byte)
48 83 EC 40      sub rsp, 0x40        (4 bytes)
                                      ─────────
                                      15 bytes total
```
A 14-byte patch cuts `sub rsp, 0x40` mid-instruction → corrupted
trampoline → first-frame crash. **Do not lower `HOOK_PATCH_SIZE`.**

**TOCTOU fix**: `Handle.Trampoline` is populated **before**
`WriteAbsJump(Target, Replacement)` — otherwise a concurrent render-thread
call could dispatch into the replacement function before the trampoline
pointer is visible, causing a nil deref crash. Lines 199-205 of
`hook_engine.pas`.

**No general-purpose disassembler**. We rely on the caller passing
`ExpectedPrologue` so the engine refuses to install if the first 5 bytes
don't match. For `wglSwapBuffers` that's `48 89 5C 24 08`. If a future
Windows update changes this, install fails safely instead of corrupting
opengl32.

**No RIP-relative fixup**. We document that the first 15 bytes of the
target MUST contain only relocatable instructions (no `lea reg, [rip+...]`,
no `call rel32`, etc.). Currently true for `wglSwapBuffers`. Spec
reviewer flagged this; we accepted as a precondition.

## Capture size: GetClientRect, NOT GL_VIEWPORT

`glGetIntegerv(GL_VIEWPORT)` is **wrong** — RuneLite mutates the viewport
multiple times per logical frame to render UI sub-surfaces (chat, action
bars). Whichever was active at swap time wins; we'd get inconsistent
fragment sizes (saw 146×28 in one bench).

Correct: `WindowFromDC(hdc)` + `GetClientRect(wnd, rc)` gives the
framebuffer drawable size, stable across all swaps on the same context.
See commit `90b61b3e`.

## Auto-injection wiring

Simba auto-injects when a window is selected as the target. Two
chokepoints, both call `GLHookAutoInject(window)`:

1. **`Source/simba.target.pas` `TSimbaTarget.SetWindow`** — script-side
   (`Target.SetWindow(...)` in Lape).
2. **`Source/ide/simba.ide_vars.pas` `SetWindowSelection`** — IDE-side
   (user picks via eyedropper).

`GLHookAutoInject` (in `Source/simba.capture_glhook.pas`):
- Self-injection guard (PID = GetCurrentProcessId → no-op)
- Idempotency: tracks injected PIDs in a unit-scope array guarded by a
  TCriticalSection
- **Only records PID on success** — transient failures (OpenProcess access
  denied because Simba isn't elevated yet) don't permanently blacklist
- Never raises; errors logged via `DebugLn` with `DEBUG_RED`/`DEBUG_RESET`
- Finalization does **NOT** free the critical section — OS cleans up at
  process exit, avoids TOCTOU race with concurrent script-thread calls

## DXGI is unwired (but not deleted)

`Source/simba.capture_dxgi.pas` and
`Source/script/imports/simba.import_capture_dxgi.pas` remain on disk but
are no longer in any `uses` clause. Removed from:
- `Source/Simba.lpr`
- `Source/simba.target.pas`
- `Source/ide/simba.ide_vars.pas`
- `Source/script/simba.script_imports.pas`

`Source/simba.nativeinterface_windows.pas` `GetWindowImage` now delegates
to `GLHookTryGetImage` only. Targets without a running hook return
False/empty.

## File map

```
docs/pascal-injection-poc/
  PLAN.md           Original POC execution plan (Phase 1-6)
  PHASE_7_PLAN.md   Hook engine + self-test + wglSwapBuffers prep
  NEXT_STEPS.md     What's done vs what's left (Phase 1 marked DONE)

Source/hook/                              The injected DLL
  simba_gl_hook.lpr                       library declaration
  simba_gl_hook.lpi                       Lazarus project (Win64 DLL)
  dllmain.pas                             logging, env reporter, in-DLL
                                          self-test, wgl_hook (the meat)
  hook_engine.pas                         inline trampoline + 15-byte abs-jmp
  simba_hook.rc                           HOOK64 RCDATA "simba_gl_hook.dll"
  simba_hook.res                          compiled binary (TRACKED in git)

Source/                                   Simba host side
  simba.inject.pas                        Pascal injector
                                          (CreateRemoteThread + LoadLibraryW)
  simba.capture_glhook.pas                GLHookAutoInject wired into target setters
  simba.capture_glhook_reader.pas         GLHookTryGetImage shmem reader
  simba.capture_dxgi.pas                  DEAD — unwired but on disk
  simba.nativeinterface_windows.pas       GetWindowImage → GLHookTryGetImage
  simba.target.pas                        TSimbaTarget.SetWindow chokepoint
  Simba.lpr                               {$R hook/simba_hook.res} + uses

Source/ide/
  simba.ide_vars.pas                      SetWindowSelection chokepoint

Source/test/inject/                       Test harnesses
  test_inject.lpr                         Standalone PID → inject CLI
  test_targetsetter.simba                 Lape script: Target.SetWindow(HWND)
  test_capture.simba                      Lape script: GetImage + save BMP
  bench_capture.simba                     Lape script: 200 GetImage timings
```

---

# Performance characteristics

Measured against live RuneLite, 798×535 capture, on a single dev box.

| Metric | Value |
|---|---|
| `Target.GetImage()` avg | **1.55 – 1.80 ms** |
| `Target.GetImage()` min | 1.15 ms |
| `Target.GetImage()` max (mutex contention) | 4.7 – 7.1 ms |
| Theoretical sustained rate | ~600 fps |
| RuneLite per-frame overhead in the hook | ~2-3 ms (glReadPixels + flip + mutex) |
| RuneLite working-set delta after injection | +3.4 MB |
| Simba working set during 200-call bench | ~26 MB (flat — Lape frees TImages) |

Compare DXGI (now unwired) which was ~2.9 ms median for a smaller
652×445 capture: our hook is faster for a bigger frame.

The ~2-3 ms hook overhead per render-thread frame is **12-18% of a 60 fps
budget**. RuneLite hits 60 fps comfortably on most hardware; not yet
tested under load on weaker GPUs.

---

# Build toolchain

- **FPC 3.2.4-rc1-69-gd3a5f442ee** at `C:/fpcup/fpc/bin/x86_64-win64/`
- **Lazarus** at `C:/fpcup/lazarus/`
- All builds target **Win64 only**. RuneLite is 64-bit; we never need 32-bit.

## Building the hook DLL

Lazarus quirk: it always produces `simba_gl_hook.exe` even with
`{$ApplicationType GUI}` / library mode. PE header is correctly marked
`IMAGE_FILE_DLL`. Rename after build.

```bash
cd "C:/Users/maxim/Documents/projects/sima2k conversion/Simba-2.0/Source/hook"
"C:/fpcup/lazarus/lazbuild.exe" --build-mode=Default simba_gl_hook.lpi
mv -f simba_gl_hook.exe simba_gl_hook.dll
"C:/fpcup/fpc/bin/x86_64-win64/windres.exe" \
    --preprocessor="cmd /c type" \
    -i simba_hook.rc -o simba_hook.res \
    -O coff -F pe-x86-64
```

`windres` quirk: without `--preprocessor="cmd /c type"` it tries to spawn
`cpp` which isn't shipped with FPC. The `cmd /c type` trick passes the
.rc file through unfiltered.

`windres` MUST be invoked from inside `Source/hook/` — relative paths
with spaces choke the `cmd /c type` preprocessor when invoked from a
different cwd.

## Building Simba

**Always kill any running Simba first** — lazbuild can't relink a running
exe:
```bash
powershell -NoProfile -Command "Get-Process -Name 'Simba-Win64' -ErrorAction SilentlyContinue | Where-Object { \$_.Path -like '*sima2k conversion*' } | Stop-Process -Force"
```

Then:
```bash
cd "C:/Users/maxim/Documents/projects/sima2k conversion/Simba-2.0/Source"
"C:/fpcup/lazarus/lazbuild.exe" --build-mode=Win64 Simba.lpi
```

Build takes ~13 seconds. Output to `Simba-Win64.exe` at repo root.

The `{$R hook/simba_hook.res}` directive in `Source/Simba.lpr` embeds the
hook DLL as `HOOK64` RCDATA. Path is relative to `Source/`.

## Building test_inject

```bash
cd "C:/Users/maxim/Documents/projects/sima2k conversion/Simba-2.0"
"C:/fpcup/lazarus/lazbuild.exe" --build-mode=Default Source/test/inject/test_inject.lpi
```

`test_inject.lpr` includes `{$R ..\..\hook\simba_hook.res}` so it embeds
the same DLL. Rebuild after the hook DLL changes.

---

# Testing

## Quick smoke test (rundll32)

Tests the hook DLL in isolation — no injection, no RuneLite:
```bash
powershell -NoProfile -Command "Remove-Item -Force -ErrorAction SilentlyContinue \"$env:TEMP\simba_hook.log\"; rundll32.exe 'C:\Users\maxim\Documents\projects\sima2k conversion\Simba-2.0\Source\hook\simba_gl_hook.dll',Probe; Start-Sleep -Milliseconds 800; Get-Content \"$env:TEMP\simba_hook.log\""
```

Look for `hook_engine_test: PASS` — the in-DLL self-test patches a
function in our own DLL, verifies hooked + trampoline both work, uninstalls.

## End-to-end against live RuneLite

```bash
# 1. Start RuneLite normally (Jagex Launcher).
# 2. Update bench_capture.simba's hardcoded HWND to match.
# 3. Run Simba script that sets target and captures.

"C:/Users/maxim/Documents/projects/sima2k conversion/Simba-2.0/Simba-Win64.exe" --run \
    "C:/Users/maxim/Documents/projects/sima2k conversion/Simba-2.0/Source/test/inject/bench_capture.simba"
```

Expected output:
```
[GL-hook] injected into pid=<RUNELITE_PID>
Captured 798x535 (200 iterations)
  avg:  1.55 ms
  ...
```

The `[GL-hook] inject pid=800 failed: OpenProcess (code 5)` line is
expected — that's the script-runner's default target (a system-owned
window we can't open).

## Verifying the BMP

`test_capture.simba` saves to `%TEMP%\simba_glhook_capture.bmp`. Open it
to confirm real RuneLite content, no overlapping windows.

## Reading hook log

The injected DLL appends to `%TEMP%\simba_hook.log`. Useful entries:

- `attach` — DllMain ran on PROCESS_ATTACH
- `host_exe=...` — what process we're in
- `modules: count=N opengl32=True jvm=True d3d11=True` — module inventory
- `wglSwapBuffers=0x... prologue=<32 bytes>` — prologue dump
- `wgl_hook: prologue verified, installing (addr=0x...)` — sanity check passed
- `wgl_hook: installed (trampoline=0x...)` — hook is live
- `wgl_hook: shared capture initialized (capacity=4194304 bytes)` — shmem ready
- `wgl_hook: frame N (hdc=0x...)` — every 60 frames

Old hook DLLs from previous injections **stay mapped** until RuneLite
exits. So you'll see multiple base addresses logging concurrently. Kill
& relaunch RuneLite to clear stale hooks.

---

# Workflow conventions

## Commit style

**One-line subjects.** Look at upstream Villavu/Simba commits — they're
all one-line. Match it.

Body is optional, used only when the why isn't obvious from the diff.

Co-Authored-By trailer on Claude commits:
```
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

## Push protocol

After every commit on this branch:
```bash
git push fork pascal-injection-poc
git push upstream-fork pascal-injection-poc
```

Both forks track the same branches. Never push to `origin` (Villavu
upstream).

## Tracked vs untracked

**Tracked binaries** (yes, surprisingly):
- `Source/hook/simba_hook.res` — the windres-generated resource blob
  containing the hook DLL. ~138 KB. Tracked because regenerating requires
  the DLL to be freshly built, which requires lazbuild, which contributors
  may not have set up. Same convention as `Source/simba.res`.

**Untracked** (always):
- `Source/hook/simba_gl_hook.dll` — output of lazbuild
- `Source/hook/simba_gl_hook.exe` — Lazarus's intermediate before rename
- `Source/hook/lib/` — FPC's per-target intermediate
- `*.exe`, `*.crash`, `defmods.ini`, `fpcup.ini`, `settings.ini`,
  `fpcup.log`

When committing: explicitly list files to `git add`. Never `git add .` or
`git add -A` — the repo accumulates dev-machine cruft.

## SDD (Subagent-Driven Development)

The user has set the explicit expectation: **use SDD for multi-step
implementation work**. Pattern per task:

1. Write a Phase-N plan doc (or addendum) with concrete acceptance criteria
2. Dispatch a fresh implementer subagent with full task text + scene-
   setting context (it doesn't see this conversation)
3. Wait for DONE
4. Dispatch a fresh spec-compliance reviewer subagent — verifies the
   diff matches the spec exactly, nothing missing, nothing extra
5. If gaps found, send back to implementer to fix
6. Dispatch a fresh code-quality reviewer subagent (use
   `feature-dev:code-reviewer` subagent type) — looks for bugs,
   correctness, style consistency with rest of codebase
7. If issues found, fix (small fixes inline; big ones via implementer)
8. Re-review after fixes
9. Controller (you) commits

**Each subagent gets full context in the prompt.** They don't see this
conversation. Prompts must include: file paths, line numbers, style
references, build commands, build expectations, what's in/out of scope,
what NOT to commit (the controller commits).

When the API is overloaded (529s), fall back to direct implementation
with explicit documentation of the SDD deviation. Then dispatch the
reviewers when API recovers.

## Where plans live

- Current branch's plan tree: `docs/<branch-name>/`
- Phase plans accumulate: PLAN.md → PHASE_7_PLAN.md → etc.
- NEXT_STEPS.md is the forward-looking living doc — keep it accurate as
  work lands

---

# Critical FPC / Pascal gotchas

## `Pointer(SomeFunc) := GetProcAddress(...)`

Typed procedural variables need explicit `Pointer()` cast to assign to:
```pascal
var glReadPixels: procedure(...); stdcall = nil;
// Wrong:
@glReadPixels := GetProcAddress(...);
// Right:
Pointer(glReadPixels) := GetProcAddress(...);
```

## TRect / HWND name collisions

`hwnd` and `TRect` are commonly already in scope. Use:
```pascal
var
  wnd: HWND;            // not "hwnd"
  rc: Windows.TRect;    // qualified
```

## Lazarus quirks

- `lazbuild --build-mode=Default` on a `library` project produces
  `xxx.exe` not `xxx.dll`. The PE header IS marked as DLL. Rename
  manually after build.
- `lazbuild` cannot relink a running exe. Kill Simba before rebuilding.
- `lazbuild Simba.lpi` must be invoked from `Source/` — running from
  repo root says "File not found".

## Lape (Simba's script language) gotchas

- `Wait()` doesn't exist; it's `Sleep(ms)`.
- `TImage.Free()` doesn't exist as a Lape-side method. Don't try to free
  images in scripts; Lape garbage-collects them when the variable goes
  out of scope.
- `Target.GetImage()` returns a TImage; no bounds arg captures the full
  window client area (clipped to whatever shmem reports).
- `PerformanceTime()` returns a Double in milliseconds. Use for benches.

## ObjFPC mode

All our new files use `{$mode objfpc}{$H+}`. The codebase mixes ObjFPC
and Delphi modes — match the unit you're modifying:
- `simba.inject.pas`, `simba.capture_glhook.pas`, hook DLL: ObjFPC mode
- Some older Simba units: Delphi mode

## Asm in FPC

For the hook engine self-test target functions:
```pascal
{$PUSH}{$ASMMODE INTEL}
function TestTarget(x: Integer): Integer; stdcall; assembler; nostackframe;
asm
  push rbp
  mov  rbp, rsp
  nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop  // 11 nops = 15 bytes
  mov  eax, ecx        // x in rcx per Win64 ABI
  add  eax, 42
  pop  rbp
  ret
end;
{$POP}
```

`nostackframe` is critical — otherwise FPC wraps the asm in a
prologue/epilogue that adds bytes you didn't account for.

`{$PUSH}{$ASMMODE INTEL}` / `{$POP}` — scope ASMMODE so it doesn't leak
into the rest of the unit (the linter caught us setting INTEL globally
once).

The 15-byte prologue requirement: `push rbp; mov rbp,rsp` = 4 bytes,
plus 11 nops = 15 = HOOK_PATCH_SIZE.

---

# Known limitations / unfinished items

| Issue | Severity | Notes |
|---|---|---|
| 4 MiB shmem cap | medium | RuneLite >1024×1024 client → truncated capture. Fix: reallocate mapping when client size exceeds capacity |
| `glReadPixels` synchronous | medium | Blocks RuneLite render thread ~2-3ms/frame. Fix: PBO async ring like OBS uses |
| Vertical flip in CPU | low | ~0.5-1ms per frame. Fix: GPU-side flip via FBO blit |
| Mutex per frame | low | Per-frame Wait/Release; could be lock-free with atomic counter |
| Temp DLL stays on disk | low | `%TEMP%\simba_hook_<guid>.dll` persists while RuneLite holds it. Cleans up at RL exit |
| Idempotency loss on Simba restart | low | Each Simba session re-injects into already-hooked PIDs; old hook in PID refuses 2nd install due to prologue mismatch |
| Multiple RuneLite instances accumulate hook DLLs | low | Each inject is a fresh DLL mapping; OS cleans up at process exit |
| No reflective loader | low | Currently writes DLL to %TEMP% before LoadLibraryW. Reflective loading would eliminate the disk artifact and lower AV signature surface |
| Hook DLL signed | low | Unsigned; some EDR products may flag it. Sign with cert when going to wider distribution |
| Capture body always runs | low | When a script uses the RI plugin instead of `Target.GetImage()`, the hook still wastes 2-3ms per frame doing glReadPixels nobody reads. Fix: env var or shmem flag to skip when no consumer |

---

# Anti-cheat / Jagex context

Research established (see `wgc-capture-backend` design doc for citations):

- **RuneLite is on Jagex's [Approved Client List](https://oldschool.runescape.wiki/w/Update:Third_Party_Clients_Update)**.
- **Jagex has no published kernel-mode anti-cheat for OSRS**. No EAC, no BattlEye, no Vanguard equivalent. Detection is server-side behavioral.
- **OBS Game Capture (same technique we use) routinely runs against RuneLite for streamers** — zero documented cases of bans from `graphics-hook64.dll` in the JVM module list.
- **The risk surface is**: we load an unsigned DLL into RuneLite's address space. If Jagex ever adds client-side module enumeration to their telemetry, our DLL would be visible. As of 2026 there's no evidence they do.
- **Bigger risk is what scripts DO** with the captured pixels (automation) — that's the actual ban vector and predates this hook by 20 years.

Default user-facing posture in the README (when we write it): **opt-in,
clearly labeled, with a "this loads a DLL into RuneLite, here's what
it does" disclosure**. Currently the auto-inject happens silently when
the user sets a window target — that's fine for the POC, needs UI before
shipping to wider audience.

---

# Coexistence with the RI plugin

`pascal-injection-poc` doesn't include the `ide-remoteinput-autopair`
work. But the libremoteinput script-plugin ecosystem (`{$loadlib
libremoteinput-loader.dll}` in WaspLib scripts) is **fully orthogonal**
to what we built:

| Path | Mechanism | Where pixels come from |
|---|---|---|
| `Target.GetImage()` | Our hook in shared memory | Our `glReadPixels` on render thread |
| `RIClient.GetImage()` | libremoteinput JNI plugin | libremoteinput's own `glReadPixels` |

Both can be active simultaneously without conflict:
- Different functions hooked (we patch `wglSwapBuffers`; RI just calls
  `glReadPixels` directly via JNI on demand — no inline hook)
- Different shmem namespaces (`Local\Simba_GL_Capture_<PID>` vs RI's own
  pipe/IPC)
- Different thread contexts (we're on render thread; RI is on whatever
  thread the plugin schedules)

Performance hit: when a script uses RI's path, our hook is doing
`glReadPixels` every frame for nothing. ~2-3ms wasted per RuneLite
frame. Acceptable for now; documented under known limitations.

---

# Other capture-backend trade-offs

This is the cumulative knowledge from researching alternatives. Useful
when justifying decisions or evaluating new options.

| Approach | Yellow border (Win10) | Survives occlusion | GPU-window-compatible | No cursor | DLL injection needed | Anti-cheat surface |
|---|---|---|---|---|---|---|
| GDI BitBlt | no | yes | **no** (black on OpenGL) | n/a | no | none |
| `PrintWindow + PW_RENDERFULLCONTENT` | no | yes | **no** for OpenGL (DComp tree walker only) | n/a | no | none |
| Magnification API | no | no (screen-region) | yes | yes | no | minimal |
| WGC (Windows.Graphics.Capture) | **yes** (Win10 only) | yes | yes | optional | no | none |
| DXGI Desktop Duplication | no | **no** (per-monitor) | yes | yes (cursor stripped) | no | none |
| **GL hook (this branch)** | **no** | **yes** | **yes** | **yes** | **yes** | low (per Jagex research) |
| OBS Game Capture (reference impl) | no | yes | yes | yes | yes | well-tested |

The GL-hook path is the only one that gets all four upsides
simultaneously. The cost is DLL injection.

---

# Future work (rough order)

1. **Settings UI** — IDE checkbox "Auto-inject capture hook into targets",
   default ON for GL-rendered windows, default OFF for vanilla BitBlt
   targets.
2. **Capacity auto-resize** — when client area exceeds 4 MiB, allocate
   bigger shmem mapping. Hook signals Simba via a "capacity changed"
   counter; Simba re-opens the mapping.
3. **PBO async readback** — pipeline `glReadPixels` through 3 PBOs so
   render thread isn't blocked on GPU→CPU. ~3ms saved per frame.
4. **GPU-side vertical flip** — render to an inverted FBO instead of
   CPU-flipping. ~0.5-1ms saved per frame.
5. **Reflective loader** — skip the temp file, manually map the DLL into
   the target via PE-header parsing. Smaller footprint, less AV signature.
6. **Linux equivalent** — `LD_PRELOAD` + `glXSwapBuffers` hook would
   work the same way on Linux RuneLite.
7. **RI plugin merger** — bring `ide-remoteinput-autopair`'s work into
   this branch so RI users get auto-pair AND our hook coexist by default.
8. **Wider testing matrix** — different RuneLite plugin loadouts, HiDPI
   displays, multi-monitor, RDP / TightVNC sessions, Apollo IDD
   (probably won't work), virtual GPU drivers.
9. **Upstream PR** — file a draft issue on Villavu/Simba about pure-Pascal
   GL capture, get maintainer engagement before opening PR.

---

# Quick reference: how to do common things

**Pick up where the last session left off:**
```bash
cd "C:/Users/maxim/Documents/projects/sima2k conversion/Simba-2.0"
git status
git log --oneline -10
```

**Rebuild everything from clean:**
```bash
# Kill running Simba
powershell -NoProfile -Command "Get-Process -Name 'Simba-Win64' -ErrorAction SilentlyContinue | Stop-Process -Force"

# Hook DLL
cd Source/hook
"C:/fpcup/lazarus/lazbuild.exe" --build-mode=Default simba_gl_hook.lpi
mv -f simba_gl_hook.exe simba_gl_hook.dll
"C:/fpcup/fpc/bin/x86_64-win64/windres.exe" --preprocessor="cmd /c type" -i simba_hook.rc -o simba_hook.res -O coff -F pe-x86-64
cd ../..

# Simba
cd Source
"C:/fpcup/lazarus/lazbuild.exe" --build-mode=Win64 Simba.lpi
cd ..

# Optional: test_inject
"C:/fpcup/lazarus/lazbuild.exe" --build-mode=Default Source/test/inject/test_inject.lpi
```

**Run a quick capture verification against RuneLite:**
```bash
# Edit Source/test/inject/test_capture.simba to set the correct HWND first
"C:/Users/maxim/Documents/projects/sima2k conversion/Simba-2.0/Simba-Win64.exe" --run \
    "C:/Users/maxim/Documents/projects/sima2k conversion/Simba-2.0/Source/test/inject/test_capture.simba"
ls -la "/c/Users/maxim/AppData/Local/Temp/simba_glhook_capture.bmp"
```

**Check hook log:**
```bash
powershell -NoProfile -Command "Get-Content \"$env:TEMP\simba_hook.log\" -Wait -Tail 20"
```

**Find current RuneLite PID + HWND:**
```bash
powershell -NoProfile -Command "Get-Process -Name RuneLite | Where-Object { \$_.MainWindowTitle -eq 'RuneLite' } | Format-Table Id, MainWindowHandle -AutoSize"
```

**Force a fresh inject (clear stale hooks):**
```bash
powershell -NoProfile -Command "Get-Process -Name RuneLite | Stop-Process -Force; Start-Sleep -Seconds 2; Start-Process 'C:\Users\maxim\AppData\Local\RuneLite\RuneLite.exe'"
# Wait ~30s for Jagex Launcher to spin RuneLite back up
```

---

# Commits on `pascal-injection-poc`

In reverse chronological order at time of writing:

```
90b61b3e  Use HDC client rect, not GL_VIEWPORT, for capture size
2582502d  GL pixel readback via shared memory; drop DXGI from capture path
95915477  Auto-inject hook DLL when Simba target window is set
c092c796  Full-send wglSwapBuffers hook; HOOK_PATCH_SIZE 14 -> 15
235a3d2f  Inline hook engine with in-DLL self-test and gated wglSwapBuffers prep
9328a04c  Dump wglSwapBuffers prologue from live RuneLite; minimal hook spec written
b1fad50f  Hook DLL reports host environment, validated against live RuneLite
253bf969  Pascal-native DLL injection POC
```

Each commit's title is one line per upstream convention. Bodies (where
present) explain the why.
