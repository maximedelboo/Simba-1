# WGC capture backend — design and implementation plan

> **Design pivot (post-Phase-7).** The original plan called for WGC
> as an _opt-in_ capture path layered behind a priority-sorted hook
> chain, with `ProcessLooksGPURendered` short-circuiting WGC for
> CPU-only targets, plus a `{$DEFINE SIMBA_DISABLE_WGC}` compile-time
> opt-out. After Phase 7, the user explicitly directed a pure
> replacement instead: **WGC IS the capture path** for all windows on
> Win10 1803+, BitBlt is kept only as a last-resort fallback for
> pre-1803 systems and capture-restricted surfaces, and
> `libremoteinput` is integrated as a sub-millisecond specialized
> fast path for RuneLite SunAwtCanvas via JNI injection. The
> hook-chain machinery, GPU auto-detection, and `SIMBA_DISABLE_WGC`
> define are all removed. The current shape of
> `simba.nativeinterface_windows.GetWindowImage` is a tight three-
> step cascade: `RemoteInputTryGetImage` → `WGCTryGetImage` → BitBlt.
> See `PR_BODY.md` for the production design narrative and
> `TEST_MATRIX.md` for the corresponding test expectations. The
> historical phase-by-phase plan below is kept for context but parts
> of it (Phase 5 opt-out, Phase 4 auto-detection) describe a design
> that no longer ships.

> **Design pivot 2 (post-cascade).** Cut deeper: the libremoteinput
> auto-pair integration is gone (WGC handles RuneLite directly; the
> sub-millisecond latency advantage didn't justify the code surface
> in `simba.remoteinput_autopair.pas` plus the call sites and the
> first leg of the cascade). The BitBlt fallback is also gone —
> WGC requires Win10 1803+ but that's an acceptable system
> requirement in 2026 (the cutoff is from October 2017). The result
> is that `simba.nativeinterface_windows.GetWindowImage` is now a
> one-line delegation: `Result := WGCTryGetImage(...)`. No cascade,
> no fallback, no fast-path. Pre-1803 users see whatever error
> bubbles up from `WGCLastError` and are expected to upgrade.

## Problem this branch solves

Simba's default window-capture path is GDI `BitBlt` against the target
HWND's device context. This is the only general-purpose Win32 capture
API that doesn't require process-level injection, and it is what every
Simba IDE tool — ACA, DTM editor, debug image viewer, ShapeBox, color
picker — and every `Target.GetImage()` call from a script ultimately
funnels through.

GDI `BitBlt` fundamentally cannot read pixels from an HWND that has been
promoted to an OpenGL or DirectX drawable. The HWND's GDI backing store
is no longer updated when the application presents via `SwapBuffers` /
`Present` — the rendered surface lives in the GPU swapchain, which DWM
composes to the display. `BitBlt` keeps reading the stale GDI backing
indefinitely.

The user-visible symptom: target any GPU-rendered window (RuneLite with
GPU plugin on, a hardware-accelerated browser canvas, a small DX game)
and Simba captures freeze on the last CPU-rendered frame.

The companion branch `ide-remoteinput-autopair` solves this specifically
for RuneLite by auto-pairing `libremoteinput` (the JVM injection layer
already maintained by wasp-plugins). That patch is the right answer for
OSRS botting and ships in ~280 lines.

This branch solves the **general** case using **Windows Graphics
Capture** (WGC), the Win10 1803+ API that captures via DWM rather than
via the window's HDC. WGC sees the actual presented frame regardless of
which graphics API drew it — OpenGL, D3D 11/12, Vulkan, GDI, anything.
It's what OBS Studio, Discord screen-share, ShareX, the Windows
snipping tool, and basically every modern Windows capture user relies
on.

## Scope statement (what this PR aims to deliver)

* WGC-based capture as a **built-in** Simba feature — no external
  plugin DLL to install, no wasp-plugins dependency. Ships in the
  Simba binary itself, so ACA / DTM / debug-viewer work out of the
  box on GPU-rendered targets for every Simba user.

* New capture-backend selection at the `simba.nativeinterface_windows`
  layer: opt-in (or auto-detected) WGC alongside the existing BitBlt
  path. The existing `GetWindowImageHook` from the libremoteinput
  branch is generalized to a small chain of hooks so both libraries
  coexist (libremoteinput first for RuneLite; WGC second for everything
  else).

* Cross-platform graceful degradation: unit compiles on Linux/macOS as
  a no-op (WGC is Windows-only).

* `{$DEFINE SIMBA_DISABLE_WGC}` compile-time opt-out for users who
  want pure GDI BitBlt (anti-cheat caution, perf comparison, etc.).

## Scope non-goals

* Replacing BitBlt as the default. WGC is opt-in or
  auto-engaged-on-detected-GPU-window initially. Making it the default
  is a follow-up decision once stability data exists.

* Input injection. This patch is capture-only.

* Java-specific behavior. RuneLite users should keep using
  libremoteinput via the sibling branch — it has lower latency
  (`glReadPixels` is sub-millisecond vs WGC's ~16 ms compose cycle).

* Cross-platform parity. Linux's equivalent is PipeWire / xshmfence;
  macOS is `ScreenCaptureKit`. Separate projects.

## Why WGC and not DXGI / PrintWindow

| Method | Sees GPU content | Per-window | Apollo IDD survives | Complexity |
|---|---|---|---|---|
| GDI BitBlt (current) | ❌ no | ✅ | irrelevant | trivial |
| PrintWindow + PW_RENDERFULLCONTENT | partial (DX-only, OpenGL flaky) | ✅ | ✅ | trivial |
| DXGI Desktop Duplication | ✅ | ❌ (monitor only) | ❌ black on IDD | moderate (~300 lines) |
| **WGC** | ✅ | ✅ | ✅ | moderate-high (pure Pascal: ~1200 lines) |
| In-process injection (libremoteinput) | ✅ | ✅ | ✅ | very high; per-app |

DXGI fails on Apollo virtual displays for GPU content (independently
verified in the diagnostic work on the sibling branch). PrintWindow
+ PW_RENDERFULLCONTENT is unreliable for OpenGL specifically — Java
AWT's SunAwtCanvas doesn't respond to `WM_PRINT` by issuing an LWJGL
frame. WGC is the architectural winner: goes through DWM at a layer
that sees per-window swapchain content for any rendering technology
and survives virtual-display setups.

## Architecture — pure Pascal, in-tree

Three new units:

* `Source/simba.winrt_helpers.pas` — reusable WinRT plumbing:
  - `RoInitialize` / `RoUninitialize` wrappers
  - HSTRING create / delete / convert-from-Pascal-string / convert-to
  - `RoGetActivationFactory` typed wrapper
  - Base IInspectable declaration (IUnknown + 3 methods)
  - Apartment-thread management
  
  ~250 lines; the cost is paid once and reused by any future WinRT
  consumer Simba might add (Spatial.Audio, Storage.Pickers, etc.).

* `Source/simba.capture_wgc.pas` — the capture implementation:
  - Hand-typed interface declarations for the ~10 WGC + D3D11 types
    we need (IGraphicsCaptureItem, IGraphicsCaptureItemInterop,
    IDirect3D11CaptureFramePool, IDirect3D11CaptureFrame,
    IGraphicsCaptureSession, IDirect3DDevice, ID3D11Device,
    ID3D11DeviceContext, ID3D11Texture2D, IDXGISurface) with their
    IIDs and method vtable layouts
  - Frame-arrived handler class implementing
    ITypedEventHandler<Direct3D11CaptureFramePool, IInspectable>
  - Per-session state: capture item, frame pool, session, latest-frame
    staging buffer + mutex
  - Public API mirroring `simba.remoteinput_autopair.pas`:
    - `procedure WGCAutoOpen(Window: TWindowHandle);`
    - `function WGCTryGetImage(Window: TWindowHandle; X, Y, W, H: Integer; var ImageData: PColorBGRA): Boolean;`
    - `procedure WGCRelease();`
  - Registers itself with `GetWindowImageHookChain` on initialization
  
  ~900 lines including the interface declarations.

Plus minimal wiring in existing files (mirroring the libremoteinput
patch's pattern):

* `Source/simba.nativeinterface_windows.pas` — generalize the
  `GetWindowImageHook` single-pointer mechanism (added by the
  libremoteinput patch) to a small ordered chain so multiple hooks can
  coexist. ~15 lines added.

* `Source/simba.target.pas` — `TSimbaTarget.SetWindow` calls
  `WGCAutoOpen(Window)` (same chokepoint already used by libremoteinput
  for any process — IDE or script).

* `Source/ide/simba.ide_vars.pas` — `SetWindowSelection` setter calls
  `WGCAutoOpen(AValue)` (IDE-side trigger).

### Why pure Pascal even though it's more code

A C++ shim DLL would be ~300 lines of C++ instead of ~1200 lines of
Pascal. I initially proposed that route. **The right call is in-tree
Pascal even at higher line count**, because:

1. **No extra install step for end users.** A plugin DLL recreates
   exactly the friction the libremoteinput patch suffers from: scripts
   work if-and-only-if the user has installed the plugin. The IDE
   tools breaking on a fresh Simba install is the bug we're fixing —
   adding a plugin doesn't fix it for users who don't install the
   plugin.

2. **No new toolchain dependency.** Simba's CI today is pure
   Lazarus/FPC. Adding a CMake/MSVC step to build a C++ shim means
   contributors need Visual Studio installed. Doubling the build
   environment for a single feature is a high price.

3. **The WinRT bindings amortize.** Spending 250 lines on
   `simba.winrt_helpers.pas` once means future WinRT integrations
   (clipboard, audio, system tray, screenshot diagnostics, monitor
   capture variant of WGC) are cheap. The plugin path doesn't
   amortize anything.

4. **Lives or dies with Simba.** Plugins go unmaintained, get out of
   sync with target-app versions, accumulate per-OS bugs nobody else
   has the context to fix. In-tree code is fixed by anyone who works
   on Simba.

### Pure Pascal — what's actually painful, and how much

WGC is **WinRT**, which is COM-with-a-projection-layer. C++/C#/Rust
have first-class WinRT projections; FPC does not. Concretely, that
means:

| Pain point | How we handle it in pure Pascal |
|---|---|
| Hand-typed interface declarations | One-time write; covered by `simba.winrt_helpers` boilerplate + this unit's ~10 WGC/D3D11 interfaces |
| HSTRING management | Helper unit wraps `WindowsCreateString` / `WindowsDeleteString` behind a small `THString` record with `Initialize` / `Finalize` ops |
| Activation factories | Helper unit's `GetActivationFactory<I>(class_name): I` generic wrapper |
| Event delegates | Each event source = small class implementing the typed delegate interface. WGC needs ONE (FrameArrived). ~30 lines. |
| Apartment threading | All WGC calls happen on a single dedicated WinRT worker thread the unit owns. Sync bridge via mutex + latest-frame buffer. |
| D3D11 boilerplate | Manual COM calls. ~150 lines of device+texture+staging+map setup, mostly mechanical, once. |
| IID typos crashing into ntdll | Mitigated by pulling IIDs from official Microsoft headers verbatim, plus unit-test-style validation in `initialization` that asserts QueryInterface works for each IID before we depend on it. |

The cost is real but bounded. Once written, the maintenance is mostly
"someone updates Win11 SDK and a new optional method is added that we
don't use" — non-events.

### Hook design: chain not pair

The libremoteinput patch installed a single `GetWindowImageHook`
function pointer. With two consumers (libremoteinput + WGC) we
generalize to a small ordered chain:

```pascal
// in simba.nativeinterface_windows.pas
type
  TGetWindowImageHook = function(Window: TWindowHandle; X, Y, W, H: Integer; var Data: PColorBGRA): Boolean;

procedure RegisterGetWindowImageHook(Hook: TGetWindowImageHook; Priority: Integer);
```

Each registered hook gets a priority; the chain tries them
highest-first. First hook that returns True wins.

* libremoteinput registers at priority 100 (runs first for RuneLite)
* WGC registers at priority 50 (runs for any GPU window
  libremoteinput doesn't claim)
* BitBlt is the implicit final fallback in `GetWindowImage` itself

This stays small (~25 lines), avoids any specific knowledge of the
hook implementations, and is easy for upstream to review.

### Sync-vs-async bridge

WGC delivers frames asynchronously via the FrameArrived callback,
which runs on a WinRT-internal thread. Simba's `GetWindowImage` is
synchronous on the calling thread.

The unit owns:
- One latest-frame buffer (BGRA32, dynamically sized to current frame
  dimensions)
- A mutex guarding it
- An optional "new frame arrived" event for callers who want freshness

On FrameArrived: lock, copy from D3D11 staging texture into the
latest-frame buffer, signal event, unlock. ~1 ms work.

On `WGCTryGetImage`: lock, copy subrect from latest-frame buffer to
caller's output, unlock. Sub-millisecond.

Worst case caller latency: one DWM compose cycle (~16 ms at 60 Hz),
typically less.

### Auto-detection: when does WGC engage?

For Phase 3 we ship "always-on when registered" — WGC tries to open a
session for every targeted window. WGC handles non-GPU windows just
fine, the only cost is some D3D11 work per frame.

For Phase 4 we add auto-detect to avoid that cost on CPU-only windows:

1. Check whether the target window's owning process has any of
   `opengl32.dll`, `d3d9.dll`, `d3d11.dll`, `d3d12.dll`, `dxgi.dll`
   loaded (via `EnumProcessModules`). One-time check on auto-open.
   GPU-loaded → use WGC. None loaded → return False from the hook
   and let BitBlt run.

Plus a user-facing setting (Phase 4) so people can force a method.

## Phase plan (concrete milestones)

### Phase 0 — design & branch (this commit)

* Branch `wgc-capture-backend` cut from upstream `simba2000`.
* This `PLAN.md` lives at `docs/wgc-capture-backend/PLAN.md`.
* Scaffolding skeletons at `Source/simba.winrt_helpers.pas` and
  `Source/simba.capture_wgc.pas` — unit declarations with public API
  signatures and TODO bodies. Compile clean as no-ops; subsequent
  phases fill them in.

### Phase 1 — `simba.winrt_helpers.pas`

Implement the WinRT plumbing the capture unit will use:

* `RoInitialize` / `RoUninitialize` reference-counted wrappers (only
  one Init per process, last consumer's `Finalize` actually undoes)
* `THString` record with Init / Finalize / FromPascal / ToPascal
* `IInspectable` interface declaration (IID:
  `AF86E2E0-B12D-4C6A-9C5A-D7AA65101E90`) with the three GetIids /
  GetRuntimeClassName / GetTrustLevel methods
* `GetActivationFactory(className: String; const IID: TGUID; out Factory): HRESULT`
* Thread-local apartment-state tracking
* Helper to log HRESULT failure with a human-readable message

Acceptance: a small in-tree test (`Source/test/wgc/test_winrt.simba`?
or a unit-test program in Source/test/) successfully calls
`RoInitialize`, gets an activation factory for `Windows.Foundation.Uri`
(or some other innocuous WinRT class), creates an instance, releases
it. Proves the plumbing works before we touch WGC.

### Phase 2 — WGC interface declarations

Add to `simba.capture_wgc.pas`:

* Interface declarations for the ~10 WinRT types listed above, with
  IIDs and method tables matching the official Windows SDK headers
  exactly.
* Validation block in `initialization` that does a QueryInterface
  through each declared IID against a real object. Catches typos
  before they're silent crashes.

Acceptance: declarations compile, all IID QueryInterface validations
pass at startup.

### Phase 3 — capture logic

* WinRT worker thread (single, owned by the unit) that processes WGC
  calls so apartment-threading stays consistent.
* `WGCAutoOpen(Window)`:
  - If a session exists for a different window: tear it down.
  - Create a D3D11 device (lazy-init once, reused).
  - Get `IGraphicsCaptureItemInterop` activation factory.
  - Create capture item from HWND.
  - Create frame pool (BGRA8, 2 buffers).
  - Create + start capture session, register FrameArrived.
* `FrameArrivedHandler.Invoke`:
  - TryGetNextFrame → IDirect3D11CaptureFrame
  - Get surface → IDirect3DSurface → underlying ID3D11Texture2D
  - Copy to a CPU-readable staging texture (lazy-allocated on first
    frame, resized on dimension change)
  - Map staging texture → memcpy into latest-frame buffer guarded by
    mutex
  - Unmap, release frame
* `WGCTryGetImage(...)`:
  - Lock latest-frame mutex, copy subrect to caller's buffer,
    `ReAllocMem` the output to the expected size (matches BitBlt path
    convention)
* `WGCRelease()`: stop session, release frame pool, release item,
  release staging texture (D3D11 device kept for next session)

Acceptance: a bare script `begin Target.SetWindow(<hwnd-of-gpu-app>);
Target.GetImage().Save('out.png'); end.` produces a fresh,
live-updating capture of an arbitrary GPU-rendered window.

### Phase 4 — hook chain + wiring + auto-detect

* Generalize `GetWindowImageHook` to ordered registration chain.
* Update `simba.remoteinput_autopair.pas` (the libremoteinput branch's
  unit) to register via the new chain at priority 100 — done as
  prerequisite if branches merge.
* `simba.capture_wgc.pas` registers at priority 50.
* `EnumProcessModules`-based GPU-detection so WGC sits dormant for
  CPU-only windows.

Acceptance: ACA/DTM/debug-viewer work against a hardware-accelerated
browser canvas. RuneLite still uses libremoteinput when available,
WGC when not.

### Phase 5 — settings UI + opt-outs

* `{$DEFINE SIMBA_DISABLE_WGC}` compile-time guard makes the unit a
  full no-op.
* IDE settings dialog adds "Capture method: Auto / BitBlt / WGC".
  Persisted in settings.ini.

Acceptance: a user can disable WGC at compile or run time and the
behavior returns to vanilla BitBlt.

### Phase 6 — testing matrix

Per the table in the original plan: RuneLite GPU on/off,
libremoteinput present/absent, Notepad, Chrome canvas, standalone DX
game, minimized window, multi-monitor, Apollo IDD, Win10 1809
(WGC unavailable), Win10 22H2, Win11 22H2+.

### Phase 7 — PR preparation

* Squash to 3–5 logical commits (helpers unit / WGC unit / hook chain
  / settings / examples).
* Open an issue on Villavu/Simba first to confirm direction.
* Write PR description from PLAN.md.

## Estimated effort (revised for pure-Pascal)

* Phase 1 (WinRT helpers): 1 focused day. Mostly RTTI-style boilerplate
  but the apartment-threading bit is fiddly to get right.
* Phase 2 (interface declarations): half a day. Mechanical translation
  of Windows SDK headers; tedious but cookbook-able.
* Phase 3 (capture logic): 2 focused days. The interesting work.
  Mostly D3D11 staging-texture handling and the frame-pool callback.
* Phase 4 (hook chain + wiring + auto-detect): half a day.
* Phase 5 (settings UI + opt-outs): half a day.
* Phase 6 (testing matrix): 1 day.
* Phase 7 (PR polish): half a day.

Total: ~6 focused days. About 50% more than the C++-shim route, but
delivers a fully built-in feature that ships with Simba and has no
external dependency.

## Risks and known unknowns

* **FPC's COM/WinRT support is incomplete**. We may hit edge cases
  where FPC's interface machinery doesn't quite match what WinRT
  expects (e.g. delegate marshalling). Mitigation: small validation
  tests at each layer (Phase 1 acceptance test, Phase 2 IID
  validation) catch these before we build on top.

* **WGC's yellow capture border on Win10 < 22H2**. Visible during
  capture; not suppressible. Mitigation: an IDE setting to disable
  WGC on Win10 by default; Win11 users get it automatically.

* **D3D11 driver edge cases**. RDP sessions, HDR monitors, minimized
  windows. Need testing per row of Phase 6 matrix.

* **Apartment threading**. WGC needs MTA; Simba's main thread is STA
  (LCL convention). Mitigation: the unit owns a dedicated MTA worker
  thread; all WinRT calls happen on it. Pascal-side callers stay
  synchronous via the mutex-guarded latest-frame buffer.

* **Memory cost**. Each WGC session holds 2 GPU textures + 1 CPU
  staging texture + the Pascal-side buffer copy. For 1080p that's
  ~25 MB resident. Mitigation: aggressive `WGCRelease` on
  target-change-away.

* **Hook interaction with libremoteinput branch**. Both register
  `GetWindowImageHook`. Resolved by the chain mechanism described
  above. If libremoteinput branch lands first, WGC branch just adds
  itself to the chain. If they land together, the chain mechanism
  ships with the WGC branch.

## Open questions for the upstream maintainer (file as issue first)

1. **Is WGC the desired direction for built-in capture**, or should
   it be a plugin? (PR position: built-in, for the reasons in §
   "Why pure Pascal even though it's more code".)
2. **Hook chain mechanism**: small ordered registry, or just two
   function pointers tried in sequence? Recommended: chain — same
   complexity, scales to N consumers.
3. **Should WGC default-on when available**, or opt-in via settings
   only? Recommended: opt-in initially. The yellow capture border
   stays visible on every Win10 version (Microsoft made the
   suppression API Win11-exclusive); some users will prefer to keep
   BitBlt for that reason on pre-Win11 systems.
4. **PrintWindow + PW_RENDERFULLCONTENT as a third option** — skip
   or include? Recommended: skip; the OpenGL flakiness makes it a
   trap for users who try it expecting WGC-grade reliability.
5. **WinRT helpers unit reusability**: is upstream interested in
   `simba.winrt_helpers.pas` as a future-WinRT-integration enabler,
   or should it stay private to this feature? Recommended: keep it
   public; the cost is sunk regardless.

## What lives in this branch right now

* `docs/wgc-capture-backend/PLAN.md` — this document.
* `Source/simba.winrt_helpers.pas` — skeleton with declared public
  API and TODO bodies. Compiles clean.
* `Source/simba.capture_wgc.pas` — skeleton with declared public API,
  no-op implementations matching `simba.remoteinput_autopair.pas`'s
  shape. Compiles clean.

The actual implementation lives in subsequent commits, one per
phase.
