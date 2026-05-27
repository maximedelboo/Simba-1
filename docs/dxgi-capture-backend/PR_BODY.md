# Pull request body draft

Use this verbatim (or lightly edited) as the body when opening the PR
upstream against `Villavu/Simba:simba2000`.

---

## What this adds

A DXGI Desktop Duplication backend for window capture, built **into
Simba** as pure Pascal, no plugin DLL required. DXGI fully replaces
GDI BitBlt as the capture path. There is no fallback and no fast-path:
`simba.nativeinterface_windows.GetWindowImage` is now a one-line
delegation to `DXGITryGetImage`.

Pre-Win8 systems (from before October 2012) are unsupported. Capture-
restricted surfaces (HDCP / DRM-protected video, etc.) and Apollo IDD
virtual displays with GPU-rendered content will produce a failed
capture rather than a stale frame.

## Why DXGI specifically

This branch is a sibling to the WGC capture backend. WGC works on
Win10 1803+ but Microsoft draws a **yellow capture border** around
every captured window on every Windows build except Win11 22000+
(where `IGraphicsCaptureSession3.put_IsBorderRequired(False)` is
available). The border is a UX choice; it cannot be suppressed on
Win10.

DXGI Desktop Duplication has been available since Win8 and **never
draws a capture border on any Windows build**. It is the only
general-purpose Windows screen-capture API that is both (a) compatible
with GPU-rendered content and (b) silent (no UI overlay). OBS,
Discord's "display capture" mode, and Microsoft's own RDP server all
use it.

Before this PR:

| Setup | Capture status |
|---|---|
| RuneLite, GPU plugin off | works (BitBlt sees the AWT BufferedImage) |
| RuneLite, GPU plugin **on** | frozen on last CPU frame |
| Hardware-accelerated browser | frozen / black |
| DirectX game | frozen / black |
| Notepad | works (BitBlt is fine for CPU-only) |

After this PR (default behaviour):

| Setup | Capture status |
|---|---|
| RuneLite, GPU plugin off | works (DXGI, **no yellow border**) |
| RuneLite, GPU plugin **on** | works (DXGI, **no yellow border**) |
| Hardware-accelerated browser | works (DXGI) |
| DirectX game | works (DXGI) |
| Notepad | works (DXGI) |
| Apollo IDD virtual display + GPU app | **fails** — out of scope, use the WGC branch |
| Pre-Win8 | unsupported — upgrade your OS |

## Architecture

One new unit in `Source/`:

- **`simba.capture_dxgi.pas`** (~1300 lines) — hand-typed Pascal
  interface declarations for the 12 DXGI + D3D11 interfaces this
  backend needs (IIDs and method orders cited from
  `Windows Kits/10/Include/10.0.26100.0/`), the public API
  (`DXGIAutoOpen` / `DXGITryGetImage` / `DXGITryGetImageInto` /
  `DXGIRelease` / `DXGILastError` / `DXGIFrameCount`), a singleton
  D3D11 device + DXGI factory, an active `IDXGIOutputDuplication` for
  the monitor containing the target window, and the synchronous
  `AcquireNextFrame(0)` pump.

Plus minimal wiring in existing files:

- **`simba.nativeinterface_windows.pas`** — `GetWindowImage` is a
  one-line `Result := DXGITryGetImage(...)`. The 80-line BitBlt path
  (including `ApplyRootOffset`, `ApplyDesktopOffset`, the memory DC
  dance, `GetDIBits`) is gone.

- **`simba.target.pas`** — `TSimbaTarget.SetWindow` calls
  `DXGIAutoOpen(Window)` so target-changed listeners already see
  fresh frames.

- **`simba.ide_vars.pas`** — `TSimbaIDEVars.SetWindowSelection` calls
  `DXGIAutoOpen` so the IDE's window-picker primes capture before the
  user has even right-clicked into ACA / DTM / debug viewer.

- **`simba.image.pas`** — `TSimbaImage.CreateFromWindow` allocates
  `FData` directly and hands the pointer to `DXGITryGetImageInto` as
  the destination. Eliminates the intermediate `ImageData` buffer and
  the `FromData` memcpy the prior implementation paid on every call.

- **`Source/Simba.lpr`** — `simba.capture_dxgi` added to the program's
  `uses` clause so finalization runs.

## Lifecycle pattern

Same shape as the WGC branch:

1. **D3D11 device singleton.** Lazy-created on first `DXGIAutoOpen`,
   reused across sessions, released at finalization.
2. **DXGI factory + adapter / output enumeration.** Cached for as
   long as the device lives.
3. **Active duplication.** One `IDXGIOutputDuplication` for the
   monitor currently containing the target window. Switched whenever
   the window crosses to a different monitor.
4. **Synchronous frame pump.** `AcquireNextFrame(timeout=0, ...)` on
   every consumer call. `S_OK` -> `CopyResource` to staging texture,
   `Map`, memcpy the cropped sub-rect to the caller's buffer, `Unmap`,
   `ReleaseFrame`, refresh the cached frame buffer.
   `DXGI_ERROR_WAIT_TIMEOUT` -> serve the cached frame buffer.
   `DXGI_ERROR_ACCESS_LOST` -> re-acquire the duplication, retry
   once.
5. **Latest-frame buffer.** `TColorBGRA` array sized to the active
   monitor's resolution. Resized on monitor change.

No background thread. DXGI's synchronous model means the consumer's
own call drives the GPU pipeline.

## Lock ordering

* `GCaptureLock` (outer) — structural state (active duplication,
  active monitor, target window).
* `GFrameBufferLock` (inner) — `TColorBGRA` array + cached-frame
  validity flag.

Never acquired in the reverse order. The capture path takes both;
finalization snapshot-then-release pattern keeps both windows tiny.

## Differences vs the WGC branch

| Aspect | WGC | DXGI (this branch) |
|---|---|---|
| Compatibility floor | Win10 1803 (April 2018) | Win8 (October 2012) |
| Yellow capture border | Drawn on Win10, absent on Win11 22000+ | **Absent on every Windows build** |
| Capture scope | Per-window | Per-monitor (we crop) |
| Frame delivery | Asynchronous, free-threaded `FrameArrived` | Synchronous `AcquireNextFrame(0)` |
| Idle cost | Frames flow at DWM rate; mitigated by a consumer-touch idle skip | Naturally bounded by call rate; `AcquireNextFrame(0)` returns `WAIT_TIMEOUT` when nothing changed |
| Cursor in frame | Suppressed via `IGraphicsCaptureSession2.put_IsCursorCaptureEnabled(False)` | Composited; known limitation |
| Apollo IDD virtual display | Works for GPU content | Fails for GPU content |

## Known limitations

### Cursor in frame

DXGI returns the cursor composited into every frame. The WGC branch
suppresses it via `IGraphicsCaptureSession2.put_IsCursorCaptureEnabled(False)`;
DXGI has no equivalent toggle. The cursor's position is reported in
`DXGI_OUTDUPL_FRAME_INFO.PointerPosition` and the shape in
`GetFramePointerShape`, but the cursor pixels are **already in the
frame** by the time we receive it.

For typical Simba use this is rarely a failure mode (ACA users move
the crosshair to sample, then click elsewhere; DTM is cursor-agnostic;
OCR usually targets areas the user isn't pointing at). If demand
materialises, a follow-up branch can blank the cursor's bounding
rectangle in the captured buffer.

### Apollo IDD virtual displays

DXGI Desktop Duplication fails (`AcquireNextFrame` returns
`DXGI_ERROR_NOT_CURRENTLY_AVAILABLE` or similar) against Apollo's
indirect-display driver when its content is GPU-rendered. This is a
fundamental DXGI limitation against IDD adapters that don't fully
implement the duplication mode. The companion WGC branch handles this
case; users who rely on Apollo for headless / virtual-desktop botting
should prefer the WGC branch.

### Hybrid-GPU laptops

On laptops with both integrated and discrete GPUs where Windows places
some monitors on the dGPU and others on the iGPU, `DuplicateOutput`
returns `E_INVALIDARG` if the D3D11 device's adapter doesn't drive
the target monitor. This branch creates one D3D11 device against the
default adapter and reports the failure via `DXGILastError`; a more
thorough implementation would create one device per adapter and pick
the matching one per monitor. Documented as a follow-up.

## Acceptance test results

`Source/test/dxgi/test_dxgi_capture.exe <HWND>` against an animating
Task Manager:

```
DXGI capture acceptance test
----------------------------
  [info] using HWND from argv: 1118726
  [info] window title: Taakbeheer
  [info] window rect: 652x445 at (0,5)
  [ok] DXGIAutoOpen()
  [info] sleeping 500ms for first frame...
  frame 1: 652x445  hash=0x18F1CF6034021A07  DXGIFrameCount=1
  frame 2: 652x445  hash=0xF5A5CAE515F0B9A6  DXGIFrameCount=2
  frame 3: 652x445  hash=0x92CDC6700BB74D5C  DXGIFrameCount=3
  frame 4: 652x445  hash=0x0FC744DAF3E12BAC  DXGIFrameCount=4
  frame 5: 652x445  hash=0x53A4D692CD645A67  DXGIFrameCount=5
  [info] distinct hashes: 5 / 5
  [ok] wrote frame_03.bmp (652x445)
  [ok] >=4/5 distinct hashes - live moving capture confirmed
SUCCESS: DXGI capture roundtrip
```

`bench_getimage.exe`:

```
bench_getimage: 200 captures of 652x445 window
  mean:   3221 us
  median: 2936 us
  max:    5745 us
```

~3 ms median per call — comparable to BitBlt for the same window
size, no GPU stall, no swap-chain dependency.

`bench_idle.exe` (60 Hz poll rate, foreground window animating):

```
bench_idle: 5000ms wall, 162 successful + 0 failed calls, CPU 515ms (10,3% one-core)
```

`test_window_close.exe` (spawn notepad, capture, post WM_CLOSE
mid-loop):

```
Target HWND 2231214 (PID 29456)
  warmup ok
  posting WM_CLOSE at iteration 25
  0 calls returned True after WM_CLOSE
  DXGIRelease() ok
SUCCESS
```

The `IsWindow` check on every call refuses captures of destroyed
windows cleanly; the DXGI per-monitor duplication is kept open for
later reuse.

## What we deliberately did NOT do

* **Cascade / fallback to BitBlt.** The user explicitly directed pure
  replacement. Pre-Win8 systems are unsupported and the user-facing
  message is the `DXGILastError` string.
* **Hook chain / opt-in mechanism.** DXGI is THE capture path. No
  `{$DEFINE SIMBA_DISABLE_DXGI}`, no settings checkbox.
* **GPU auto-detection short-circuit.** No "use BitBlt for
  CPU-rendered windows because it's faster". DXGI works for both;
  the small overhead difference doesn't justify the conditional
  complexity.
* **Cursor blanking.** Documented as v1 known limitation.
* **Multi-adapter D3D11 devices.** Single-device, default-driver
  adapter only. Hybrid-GPU laptop edge case documented.

## How to test

1. `lazbuild --build-mode=Win64 Source/Simba.lpi` (must build clean).
2. Open Simba, point its window picker at a GPU-rendered window (e.g.
   RuneLite with GPU plugin on). Open the debug image viewer or
   ACA / DTM. **Verify the captured image updates in real-time AND
   no yellow border is drawn around the source window** — the latter
   is the user-visible signal that DXGI engaged instead of WGC.
3. Drag the target window to a second monitor. Verify capture
   continues with no error / no stale frame.
4. Close the target window. Verify Simba doesn't crash; subsequent
   capture calls return empty images.
