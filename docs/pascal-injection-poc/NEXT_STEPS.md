# Next steps after this POC

## What this branch proved

A Pascal-compiled DLL can be:
1. Built from Simba's tree via lazbuild (no external toolchain).
2. Embedded as `RCDATA` in another Pascal exe via `windres` + `{$R}`.
3. Extracted from that exe's resources at runtime, written to a temp file,
   and loaded into a third-party process via `CreateRemoteThread` +
   `LoadLibraryW`.
4. Successfully initialized inside the foreign process: FPC's RTL came up
   cleanly, `SysUtils` / `Windows` / file IO / PSAPI module enumeration all
   worked, the unit's `initialization` and `finalization` blocks ran on the
   right loader threads.

End-to-end evidence: `%TEMP%\simba_hook.log` after injection shows correct
target PID, TID, module base, host exe path, and a count of loaded modules
in the host. Target process survives both attach and detach.

**Validated against two host processes:**

| Host | Modules | opengl32 | jvm | d3d11 | Survived inject |
|---|---:|:---:|:---:|:---:|:---:|
| Notepad | 43 | False | False | False | yes |
| **RuneLite (live, GPU plugin on)** | **143** | **True** | **True** | **True** | **yes** |

For RuneLite the hook also resolved `wglSwapBuffers` to
`0x00007FFFC0140630` — the exact address the future trampoline engine
will patch. The single biggest unknown of the whole project ("does FPC
RTL come up cleanly in a JVM-hosted host?") is now a known good.

## What's left to do (high-level)

In rough order of "do this next" → "do this last":

### 1. Inline hook engine inside the DLL

The capture path needs to intercept `wglSwapBuffers` in the target process.
Concrete prologue data captured from live RuneLite (PID 14944):

```
wglSwapBuffers @ 0x00007FFFC0140630:
  48 89 5C 24 08      mov  [rsp+0x08], rbx     ; 5 bytes
  48 89 74 24 10      mov  [rsp+0x10], rsi     ; 5 bytes
  57                  push rdi                 ; 1 byte
  48 83 EC 40         sub  rsp, 0x40           ; 4 bytes
  48 8B F1            mov  rsi, rcx            ; 3 bytes  (byte 15-17)
  ...
```

The first **15 bytes are 4 complete instructions, none RIP-relative**.
Patching the first 14 bytes with an absolute `movabs rax, imm64 / jmp rax`
sequence works without needing a general-purpose length disassembler —
just verify these specific bytes match what we expect (sanity check) and
copy them verbatim to the trampoline. This is *substantially* simpler than
the design I sketched earlier.

`wglSwapLayerBuffers` (also dumped from live RuneLite) starts with:
```
  48 89 5C 24 18      mov  [rsp+0x18], rbx
  55                  push rbp
  56                  push rsi
  57                  push rdi
  48 83 EC 70         sub  rsp, 0x70
  48 8B 05 ... ...    mov  rax, [rip+disp32]   ; RIP-relative (byte 13+)
```
First 12 bytes are clean (4 complete safe instructions). Byte 13 starts a
RIP-relative instruction so a 14-byte patch would clobber its disp32 — but
12 bytes is enough for a `push imm64 / jmp [rsp]` sequence if needed, OR we
skip `wglSwapLayerBuffers` entirely and hook only `wglSwapBuffers` (which
is what LWJGL/rlawt actually use).

`SwapBuffers` in `gdi32.dll` is a thunk (`FF 25 disp32` jmp-indirect to a
real implementation) — don't hook there; opengl32 calls bypass the thunk.

**Recommended hook approach** (revised based on the prologue data):

1. Verify `wglSwapBuffers` first 5 bytes match the expected `48 89 5C 24 08`
   prologue. If not (Microsoft changed opengl32 on a newer Windows), bail
   out with a clear error rather than risk silently corrupting the
   function.
2. `VirtualProtect` 14 bytes of the function to `PAGE_EXECUTE_READWRITE`.
3. Allocate a 64-byte trampoline page (`VirtualAlloc`, `RWX`).
4. Copy the original 14 bytes verbatim to the trampoline.
5. Append a 14-byte absolute jump (`48 B8 <orig+14> FF E0`) to the
   trampoline so it returns to mid-function after running the displaced
   prologue.
6. Write a 14-byte absolute jump (`48 B8 <hook> FF E0`) over the original
   function's first 14 bytes.
7. Restore the original protection on the function.
8. `FlushInstructionCache`.

The hook function calls the trampoline (which executes the original
prologue then jumps back into the rest of the original) to continue normal
behavior, OR returns whatever's appropriate. For a capture hook the body
runs the original then does its post-swap work.

**Total LoC for this minimal engine: ~120 lines of Pascal.** No
disassembler, no DDetours dependency, no length analysis. If future
Windows updates change the prologue, the sanity check at step 1 catches
it and we bump the supported version explicitly.

The general-purpose disassembler path (DDetours or LDE64 port) is still
worth doing for robustness, but it's no longer on the critical path.

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
