# DXGI Desktop Duplication capture backend — design and implementation plan

> Sibling design to the `wgc-capture-backend` branch. Same scope (pure
> replacement of `BitBlt` for window capture) and same philosophy
> (in-tree, pure Pascal, no plugin DLL, no compile-time opt-outs). The
> two branches differ at the Windows-API layer; user-visible behaviour
> is intended to match except for the items called out in the
> "Differences vs WGC" section below.

## Problem this branch solves

Simba's default window-capture path is GDI `BitBlt` against the target
HWND's device context. `BitBlt` cannot read pixels from a window whose
client area is presented via D3D/OpenGL/Vulkan — DWM composes the
swap-chain to the display and `BitBlt` keeps reading a stale GDI
backing store. The user-visible symptom: target a GPU-rendered window
(RuneLite with the GPU plugin on, a hardware-accelerated browser, a
small DX game) and Simba's IDE tools (ACA, DTM editor, debug image
viewer, ShapeBox, colour-picker) plus every `Target.GetImage()` call
freeze on the last CPU-rendered frame.

The `wgc-capture-backend` branch solves this with Windows Graphics
Capture. WGC works on Win10 1803+ but draws a yellow capture border
around the targeted window on every Windows build *except* Win11 22000+
(where `IGraphicsCaptureSession3.put_IsBorderRequired(False)` is
available). The border is a Microsoft UX choice; it cannot be suppressed
on Win10.

This branch ships a parallel implementation using **DXGI Desktop
Duplication** (`IDXGIOutputDuplication`). DXGI Desktop Duplication has
been available since Win8 (2012) and **never draws a capture border on
any Windows build**. It is the only general-purpose Windows screen-
capture API that is both (a) compatible with GPU-rendered content and
(b) silent (no UI overlay). OBS, Discord screen-share when the user
selects "display capture", and Microsoft's own RDP server all use it.

## Scope statement

* DXGI Desktop Duplication as the **built-in** window-capture path —
  no plugin DLL, no opt-out, no fallback path. Ships as part of the
  Simba binary; ACA / DTM / debug-image-viewer work on every window
  (GPU-rendered or CPU-rendered) for every user on Win8+.

* Cross-platform graceful degradation: unit compiles on Linux/macOS
  as a no-op (DXGI is Windows-only).

* Single squashed commit at the end matching upstream commit-message
  style.

## Scope non-goals

* Input injection. This branch is capture-only.
* Apollo IDD virtual displays. DXGI Desktop Duplication does not work
  against the Apollo virtual-display driver when its content is GPU-
  rendered; that case is owned by the WGC branch. The user explicitly
  ruled this out of scope for the DXGI branch.
* Cursor-clean captures. DXGI returns the cursor composited into the
  desktop image. v1 leaves the cursor in-frame; documented as a known
  limitation. See "Cursor handling" below.
* macOS / Linux equivalents (`ScreenCaptureKit`, PipeWire). Win-only.

## Differences vs WGC

| Aspect | WGC branch | DXGI branch |
|---|---|---|
| Compatibility floor | Win10 1803 (Apr 2018) | Win8 (Oct 2012) |
| Yellow capture border | None on Win11 22000+, **drawn** on Win10 | **Never** drawn on any Windows build |
| Capture scope | Per-window | Per-monitor (we crop) |
| Frame delivery | Asynchronous, free-threaded `FrameArrived` callback | Synchronous `AcquireNextFrame(timeout=0)` |
| Idle cost | Frames flow at DWM rate; mitigated by a consumer-touch idle skip | Naturally near-zero: `AcquireNextFrame` returns `DXGI_ERROR_WAIT_TIMEOUT` until something changes |
| Cursor in frame | Excludable via `IGraphicsCaptureSession2.put_IsCursorCaptureEnabled(False)` | Composited; v1 documented as a known limitation |
| Apollo IDD virtual display | Works for GPU-rendered content | Fails for GPU-rendered content (out of scope) |

## Architecture overview

The unit is `Source/simba.capture_dxgi.pas`. It is self-contained — no
dependency on the WGC unit, no shared helpers. The two branches are
alternative implementations of the same external API shape; if both
end up shipping concurrently the integration layer picks one.

Public API (mirrors the WGC unit's shape for callsite consistency):

```pascal
procedure DXGIAutoOpen(Window: TWindowHandle);
function  DXGITryGetImageInto(Window: TWindowHandle; X, Y, Width, Height: Integer;
                              DstPtr: PColorBGRA; DstStride: Integer): Boolean;
function  DXGITryGetImage(Window: TWindowHandle; X, Y, Width, Height: Integer;
                          var ImageData: PColorBGRA): Boolean;
procedure DXGIRelease();
function  DXGILastError(): String;
function  DXGIFrameCount(): Int64;
```

### Lifetime

* **D3D11 device singleton.** Created on first `DXGIAutoOpen`, reused
  across sessions, released only at finalization. Same pattern as
  WGC's `EnsureD3D11Device`.
* **DXGI adapter / outputs.** Enumerated from the D3D11 device's DXGI
  adapter on demand. Cached for as long as the device lives; mode
  changes drop us into the `DXGI_ERROR_ACCESS_LOST` re-acquire path.
* **Active duplication.** One `IDXGIOutputDuplication` for the
  monitor currently containing the target window. Switched whenever
  the window crosses to a different monitor.
* **Latest-frame buffer.** Same shape as WGC: a `TColorBGRA` array
  sized to the active output's resolution. Resized on monitor change
  or mode change.

### Lock ordering

Same convention as WGC:

* `GCaptureLock` (outer) — protects session/duplication structural
  state (active duplication, active monitor, target window).
* `GFrameBufferLock` (inner) — protects the `TColorBGRA` array and
  the window-within-monitor offset.

Never acquire `GCaptureLock` while holding `GFrameBufferLock`.

### Capture path (`DXGITryGetImageInto`)

DXGI Desktop Duplication is **synchronous** — there is no producer
callback. Each consumer call drives the pipeline directly:

1. Re-`GetWindowRect` to pick up any window movement since the last
   call.
2. `MonitorFromWindow` — has the window crossed monitors? If yes,
   `Release` the current `IDXGIOutputDuplication` and `DuplicateOutput`
   on the new monitor.
3. `AcquireNextFrame(timeout=0, ...)`:
   * `S_OK`: a new frame is available. `CopyResource` to a staging
     texture, `Map`, memcpy the cropped sub-rectangle (window offset
     within monitor) into the caller's destination buffer, `Unmap`,
     `ReleaseFrame`. Also cache the full-monitor frame for the
     subsequent `WAIT_TIMEOUT` path.
   * `DXGI_ERROR_WAIT_TIMEOUT`: nothing changed since the last call.
     Serve the same crop from the cached frame.
   * `DXGI_ERROR_ACCESS_LOST`: monitor mode change (rotation, DPI,
     resolution, HDR toggle). Release the duplication, re-acquire
     against the same `IDXGIOutput1`, retry once.

This means we get the idle-skip behaviour for free: `WAIT_TIMEOUT`
returns in microseconds and no GPU work happens. No producer thread
needed.

### Teardown pattern

Same as WGC: snapshot the active duplication into a local under
`GCaptureLock`, clear the globals, release the lock, then drop the
local. Releasing the duplication object while another thread is mid-
`AcquireNextFrame` is undefined; the snapshot-then-close-outside-lock
pattern keeps the structural lock window tiny.

## Interface declarations needed

Hand-typed Pascal interface declarations with IIDs cited against the
Windows 10 SDK headers
(`C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\`).

DXGI base:

* `IDXGIObject`            — `shared/dxgi.h`
* `IDXGIDeviceSubObject`   — `shared/dxgi.h`
* `IDXGIDevice`            — `shared/dxgi.h`
* `IDXGIAdapter`           — `shared/dxgi.h`
* `IDXGIAdapter1`          — `shared/dxgi.h`
* `IDXGIFactory1`          — `shared/dxgi.h`
* `IDXGIOutput`            — `shared/dxgi.h`
* `IDXGIOutput1`           — `shared/dxgi1_2.h` (provides `DuplicateOutput`)
* `IDXGIOutputDuplication` — `shared/dxgi1_2.h`
* `IDXGIResource`          — `shared/dxgi.h`
* `IDXGISurface`           — `shared/dxgi.h` (occasionally useful for diagnostics)

D3D11:

* `ID3D11Device`, `ID3D11DeviceContext`, `ID3D11Resource`,
  `ID3D11Texture2D`, `ID3D11DeviceChild` — identical to the WGC
  declarations; can be re-typed here but must stay self-contained.

Structs:

* `DXGI_OUTDUPL_DESC`, `DXGI_OUTDUPL_FRAME_INFO`,
  `DXGI_OUTDUPL_POINTER_POSITION`, `DXGI_OUTPUT_DESC`,
  `DXGI_ADAPTER_DESC1`, `DXGI_MODE_DESC`, `DXGI_RATIONAL`,
  `D3D11_TEXTURE2D_DESC`, `D3D11_MAPPED_SUBRESOURCE`.

External entry points:

* `CreateDXGIFactory1`  — `dxgi.dll`
* `D3D11CreateDevice`   — `d3d11.dll`

## Phased delivery

Mirrors the WGC plan.

### Phase 0 — scaffolding

* `docs/dxgi-capture-backend/PLAN.md` (this file).
* Skeleton `Source/simba.capture_dxgi.pas` exporting the six public
  entries with no-op stubs.
* Wire `simba.capture_dxgi` into `Source/Simba.lpr`'s `uses` clause.
* Build clean.

### Phase 1 — interface declarations + IID citations

* Type-block of all DXGI / D3D11 interfaces with verbatim IID
  citations referencing the SDK header path + line number.
* Build clean (no functional change yet).

### Phase 2 — D3D11 device + DXGI adapter / output discovery

* `EnsureD3D11Device` singleton, mirroring WGC.
* Adapter/output enumeration via the device's DXGI adapter.
* Find-monitor-for-HWND helper.

### Phase 3 — capture lifecycle

* `DXGIAutoOpen` — opens a duplication on the right monitor, snapshot-
  then-close-outside-lock for the previous duplication.
* `DXGITryGetImageInto` — drives `AcquireNextFrame(0)`, handles all
  three return cases.
* `DXGIRelease`.
* Acceptance test: capture 5 frames against an animating target,
  verify 4+/5 distinct hashes, save a BMP.

### Phase 4 — Simba integration

* `TSimbaTarget.SetWindow` calls `DXGIAutoOpen`.
* `TSimbaIDEVars.SetWindowSelection` calls `DXGIAutoOpen`.
* `TSimbaNativeInterface_Windows.GetWindowImage` delegates to
  `DXGITryGetImage` (no fallback).
* `TSimbaImage.CreateFromWindow` allocates `FData` directly and
  passes it as the destination to `DXGITryGetImageInto` —
  eliminates the intermediate memcpy.

### Phase 5 — stress + benchmarks

* Resize-storm, multi-monitor switching, target-close.
* `bench_idle` (must be naturally near-zero).
* `bench_getimage` (per-call cost).

### Phase 6 — docs

* `PR_BODY.md`, `TEST_MATRIX.md`, `UPSTREAM_ISSUE_DRAFT.md`.

### Phase 7 — squash + push

* Single commit `DXGI Desktop Duplication capture backend, replaces
  BitBlt`.
* Push to `fork` and `upstream-fork`.

## Cursor handling (known limitation, v1)

`IDXGIOutputDuplication.AcquireNextFrame` returns a frame with the
cursor already composited into the pixels. WGC can suppress this via
`IGraphicsCaptureSession2.put_IsCursorCaptureEnabled(False)`; DXGI
has no equivalent toggle — the cursor shape can be retrieved via
`GetFramePointerShape` and the position via
`DXGI_OUTDUPL_FRAME_INFO.PointerPosition`, but the cursor is **already
in the frame** by the time we get it.

Two viable implementations were considered for v1:

* **Strategy A — blank cursor region.** Read `PointerPosition` and
  overwrite the cursor's bounding rectangle with neighbouring pixels
  (or a fill colour). Imperfect — leaves a visible patch where the
  cursor was, but at least the patch is consistent across frames.
* **Strategy B — leave the cursor in frame.** Document the limitation;
  add a follow-up issue. The user's stated priority is "no yellow
  border"; for typical Simba use (ACA: user moves the crosshair away
  from the sample point before clicking; DTM: cursor irrelevant; OCR:
  text usually elsewhere on the screen), cursor-in-frame is a minor
  cosmetic issue.

v1 ships **Strategy B**. A follow-up branch can add cursor blanking if
demand materialises.

## Acceptance criteria

* `lazbuild --build-mode=Win64 Simba.lpi` builds clean.
* `Source/test/dxgi/test_dxgi_capture.exe` against Task Manager
  produces 4+/5 distinct frame hashes and a valid BMP. Exit 0.
* Idle benchmark shows acceptably low background CPU (target ≪ 1%).
* Targeting RuneLite with the GPU plugin enabled in the Simba IDE
  shows live pixels in the debug image viewer with **no yellow
  border** drawn around the window. This is the user-visible
  validation that DXGI is engaged.
* Targeting a child window (e.g. RuneLite's `SunAwtCanvas`) resolves
  to its parent monitor and per-call coordinates translate to the
  child window's screen-relative offset within that monitor.
* Single squashed commit at the end with the upstream-style message.
* Pushed to both `fork` and `upstream-fork`.
