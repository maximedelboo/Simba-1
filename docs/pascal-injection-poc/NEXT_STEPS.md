# Next steps after this POC

## What this branch proved

A Pascal-compiled DLL can be:
1. Built from Simba's tree via lazbuild (no external toolchain).
2. Embedded as `RCDATA` in another Pascal exe via `windres` + `{$R}`.
3. Extracted from that exe's resources at runtime, written to a temp file,
   and loaded into a third-party process (Notepad) via `CreateRemoteThread` +
   `LoadLibraryW`.
4. Successfully initialized inside the foreign process: FPC's RTL came up
   cleanly, `SysUtils` / `Windows` / file IO all worked, the unit's
   `initialization` and `finalization` blocks ran on the right loader threads.

End-to-end evidence: `%TEMP%\simba_hook.log` now appears after injection with
the correct target PID, TID, and module base. Target process survives both
attach and detach.

This validates the load-bearing assumption of the whole "OBS-style game
capture in pure Pascal" project: **FPC RTL works in an injected DLL with
standard LoadLibrary semantics**. The single biggest unknown at the start of
the project is now a known.

## What's left to do (high-level)

In rough order of "do this next" → "do this last":

### 1. Inline hook engine inside the DLL

The capture path needs to intercept `wglSwapBuffers` (and probably
`SwapBuffers` for completeness) in the target process. The engine needs to:

- Resolve the target function's address (`GetProcAddress` on `opengl32.dll`).
- Read the first N bytes of its prologue.
- Use a length disassembler to determine how many complete instructions cover
  at least 5 bytes (for a short JMP) or 14 bytes (for a `mov rax, imm64 / jmp
  rax` absolute jump).
- Allocate a trampoline page (`VirtualAlloc`, `PAGE_EXECUTE_READWRITE`).
- Copy the original prologue bytes to the trampoline, followed by a JMP back
  to the original function past the prologue.
- Patch the original function's first bytes with a JMP to our hook.
- `FlushInstructionCache` to be safe.

Two paths to the length disassembler:

- **Vendor DDetours** (`https://github.com/MahdiSafsafi/DDetours`, MIT,
  pure Pascal, x86 + x64). The fastest path to a working trampoline. Single
  unit, drop into `Source/hook/` or `Third-Party/`. Recommended for the POC
  extension.
- **Hand-roll a minimal LDE64 port**. ~400 lines covering enough opcodes for
  typical Win32 prologues. More work but no third-party dependency. Defer
  unless DDetours' license becomes a problem.

### 2. OpenGL ↔ D3D11 interop via WGL_NV_DX_interop2

Once the hook is firing on every `wglSwapBuffers`:

- Inside the hook, first frame only: create a D3D11 device on the same
  adapter the OpenGL context is using. Be mindful of hybrid-GPU laptops —
  if the JVM ran on the iGPU and we create our D3D11 device on the dGPU,
  the shared texture handle won't be openable on the other side.
- Create a `D3D11_RESOURCE_MISC_SHARED` texture of the GL drawable's size in
  `DXGI_FORMAT_B8G8R8A8_UNORM`.
- Call `wglDXOpenDeviceNV(d3d11Device)`, `wglDXRegisterObjectNV(...,
  GL_TEXTURE_2D, WGL_ACCESS_WRITE_DISCARD_NV)`.
- Send the DXGI shared HANDLE over the IPC channel to Simba.

Per-frame:
- `wglDXLockObjectsNV`
- Bind an FBO with the registered GL texture as color attachment 0.
- `glBlitFramebuffer(GL_BACK → COLOR_ATTACHMENT0)`.
- `wglDXUnlockObjectsNV`.
- Call the original `wglSwapBuffers` via trampoline.

### 3. IPC plumbing

- Named pipe `\\.\pipe\simba_hook_<pid>`. Hook is client, Simba is server.
- Named events: `simba_hook_ready_<pid>`, `simba_hook_stop_<pid>`.
- Keepalive mutex `simba_hook_keepalive_<pid>` — Simba holds it; hook polls
  every second and unhooks if it's gone.
- The pipe carries control messages (handle exchange, size changes, error
  reports), not pixels. Pixels live in the DXGI shared texture.

### 4. Simba-side host

In Simba (IDE + script processes):
- `Source/simba.capture_glhook.pas` mirroring `simba.capture_dxgi.pas` API:
  `GLHookAutoOpen`, `GLHookTryGetImage`, `GLHookRelease`.
- On `SetWindow`: detect if target has loaded `opengl32.dll`, fork an injector
  worker thread, wait for hook-ready event.
- On `TryGetImage`: open the shared texture handle in Simba's D3D11 device,
  `CopyResource` to a CPU-readable staging texture, Map + memcpy into
  `TImage.FData`.
- On window-change-away or process-exit: signal stop event, close handles.

### 5. Backend selection

DXGI stays the default — it's "good enough" for the common case and has no
anti-cheat surface area. GL-hook becomes an opt-in third backend for users
who explicitly want occlusion-immune capture of a GPU-rendered window AND
accept the DLL-injection trade-off. A single Simba IDE settings dropdown:
"Capture method: Auto (DXGI) / WGC / GL hook (advanced)".

### 6. Reflective DLL loader (now lower priority)

The implementer's read: do this AFTER the hook engine works, not before.

Reasoning: reflective loading is just a delivery mechanism for the same DLL.
If trampolines don't work in the target — for any reason: opengl32.dll
prologues vary, MS hot-patch prefixes interact strangely with Detours, a
particular driver has anti-tamper protection — the loader buys you nothing.
The hook engine is the bigger unknown; prove it works with standard
LoadLibrary first, then drop the temp-file artefact.

When you do build the reflective loader:
- Stephen Fewer's `ReflectiveDLLInjection` (C, public domain) is the
  canonical reference. There are Delphi ports on GitHub.
- The loader runs as a remote thread stub that takes (DllBaseAddress,
  FunctionOrdinalOrName) as its single argument.
- Pure Pascal port: ~500 lines walking PE headers, sections, relocations,
  imports, then calling DllMain. The FPC RTL setup question is moot for a
  DLL that was built with standard FPC and is being loaded by a custom
  loader — you still need to ensure the loader either calls DllMain (which
  triggers FPC's `initialization` chain) or skips it and works without RTL.
  The cleanest path is to call DllMain manually with DLL_PROCESS_ATTACH and
  let FPC's own RTL bootstrap from there.

### 7. Anti-cheat / safe-inject variant (probably skip)

OBS has an "anti-cheat compatibility" injector that uses `SetWindowsHookEx`
instead of `CreateRemoteThread`. Jagex has no kernel-mode anti-cheat for
OSRS/RuneLite, so this isn't needed for the target use case. Skip unless a
real user reports a real problem with the direct-injection path.

## Estimated effort

| Step | Effort |
|---|---|
| 1. Hook engine (with DDetours) | ~3-5 days |
| 1. Hook engine (hand-rolled disassembler) | ~2 weeks |
| 2. WGL ↔ D3D11 interop | ~3-5 days |
| 3. IPC plumbing | ~2 days |
| 4. Simba-side host | ~3-5 days |
| 5. Backend selection UI | ~1 day |
| 6. Reflective loader | ~5 days |
| Multi-GPU + driver-variant debugging | ~2-4 weeks |
| **Total to RuneLite-on-dev-machine working** | **~4-6 weeks** |
| **Total to ship-ready** | **~6-10 weeks** |

This matches the original estimate. The injection primitive being clean means
the calendar starts now, not after solving "does FPC even work in an injected
DLL".

## Files produced by this branch

```
docs/pascal-injection-poc/PLAN.md         The execution plan
docs/pascal-injection-poc/NEXT_STEPS.md   This file
Source/hook/simba_gl_hook.lpr             Library declaration
Source/hook/simba_gl_hook.lpi             Lazarus project (Win64 DLL)
Source/hook/dllmain.pas                   DllMain logger + Probe export
Source/hook/simba_hook.rc                 Resource script
Source/hook/simba_hook.res                Compiled resource (binary)
Source/hook/simba_gl_hook.dll             The built DLL (binary)
Source/simba.inject.pas                   Pascal injector
Source/test/inject/test_inject.lpr        Standalone test exe
Source/test/inject/test_inject.lpi        Test project
```

Nothing in `Source/Simba.lpr` was modified; the main Simba exe is unchanged.
Wiring the embedded resource into the actual Simba exe is part of step 4
above (Simba-side host).
