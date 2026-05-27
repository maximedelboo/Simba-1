# Pull request body draft

Use this verbatim (or lightly edited) as the body when opening the PR
upstream against `Villavu/Simba:simba2000`.

---

## What this adds

A Windows Graphics Capture (WGC) backend for window capture, built
**into Simba** as pure Pascal, no plugin DLL required. WGC fully
replaces GDI BitBlt as the capture path. There is no fallback and no
fast-path: `simba.nativeinterface_windows.GetWindowImage` is now a
one-line delegation to `WGCTryGetImage`.

Pre-Win10-1803 systems (from before October 2017) are unsupported.
Capture-restricted surfaces (DRM-protected video, etc.) will produce
a failed capture rather than a stale frame.

## Why

`BitBlt(GetDC(hwnd), ...)` can't read pixels from an HWND that
applications have promoted to OpenGL or DirectX. The HWND's GDI
backing isn't updated when the app `SwapBuffers` / `Present`s —
captured frames freeze on the last CPU-rendered content. This is the
"my image debug viewer shows the same frame forever after I turn on
the GPU plugin" bug that's caught me and other users.

WGC (Win10 1803+) captures via DWM at a higher layer that sees
swapchain content regardless of rendering API. It's what OBS Studio,
Discord screen-share, the Windows snipping tool, and basically every
modern Windows capture user relies on.

Before this PR:

| Setup | Capture status |
|---|---|
| RuneLite, GPU plugin off | works (BitBlt sees the AWT BufferedImage) |
| RuneLite, GPU plugin **on** | frozen on last CPU frame |
| Hardware-accelerated browser | frozen / black |
| DirectX game | frozen / black |
| Notepad | works (BitBlt is fine for CPU-only) |
| Apollo virtual display + GPU app | frozen (also IDD-specific issues with DXGI) |

After this PR (default behavior):

| Setup | Capture status |
|---|---|
| RuneLite, GPU plugin off | works (WGC) |
| RuneLite, GPU plugin **on** | works (WGC) |
| Hardware-accelerated browser | works (WGC) |
| DirectX game | works (WGC) |
| Notepad | works (WGC; slightly higher overhead than BitBlt, but consistent) |
| Apollo virtual display + GPU app | works (WGC; DXGI's IDD weakness avoided) |
| Win10 pre-1803 | unsupported — upgrade your OS |

## Architecture

Two new units in `Source/`:

- **`simba.winrt_helpers.pas`** (~280 lines) — process-wide
  reference-counted `RoInitialize` / `RoUninitialize`, an `HSTRING`
  wrapper, `WinRT_GetActivationFactory<I>` helper, `WinRT_LastError`
  / `WinRT_HRESULTToStr`. Reusable by any future Simba feature that
  needs WinRT (audio capture, clipboard, system tray, future
  monitor-capture variants, etc.). Cross-platform: compiles as
  no-op stubs on Linux/macOS.

- **`simba.capture_wgc.pas`** (~1500 lines) — hand-typed Pascal
  interface declarations for the 21 WinRT + D3D11 + DXGI types this
  backend needs (IIDs and method orders cited from
  `Windows Kits/10/Include/10.0.26100.0/`, validated at startup),
  plus `WGCAutoOpen` / `WGCTryGetImage` / `WGCRelease` and a
  `TFrameArrivedHandler` typed-delegate class implementing
  `ITypedEventHandler<Direct3D11CaptureFramePool, IInspectable>` +
  `IAgileObject` (required by the free-threaded frame pool).

Plus minimal wiring in existing files:

- **`simba.nativeinterface_windows.pas`** — `GetWindowImage` is a
  one-line delegation: `Result := WGCTryGetImage(...)`. No cascade,
  no fallback. The previous BitBlt code path and the dead-helper
  nested procedures it depended on are gone.

- **`simba.target.pas`** — `TSimbaTarget.SetWindow` calls
  `WGCAutoOpen(Window)` after binding. Fires for any process — the
  IDE and any script subprocess that points Target at a window.

- **`Source/ide/simba.ide_vars.pas`** — `SetWindowSelection` setter
  calls `WGCAutoOpen(AValue)`. IDE-side trigger for the picker
  crosshair.

## Why pure replacement (no opt-out, no auto-detection, no fallback)

Earlier iterations of this branch included:
- A `{$DEFINE SIMBA_DISABLE_WGC}` compile-time opt-out.
- A `ProcessLooksGPURendered` heuristic that walked the target's
  module list looking for `opengl32` / `d3d*` / `dxgi` DLLs and
  short-circuited WGC when none were found.
- A priority-sorted `RegisterGetWindowImageHook` chain so multiple
  capture backends could coexist behind one function-pointer table.
- A `simba.remoteinput_autopair` integration that bypassed display
  capture entirely for RuneLite SunAwtCanvas targets, sitting as the
  first leg of a three-step cascade ahead of WGC.
- A `BitBlt` fallback as the last leg of that cascade, for pre-Win10
  1803 systems and capture-restricted surfaces.

All of that has been removed. WGC is correct and fast enough for
every window kind on Win10 1803+ (the libremoteinput sub-millisecond
advantage is invisible at human timescales and to ACA/DTM/OSRS
workflows on 600ms game ticks), and Win10 1803 is from October 2017
— treating pre-1803 as an unsupported platform is reasonable in 2026.
The result is a one-line `GetWindowImage` body that anyone can audit
in 5 seconds.

## Performance

Two targeted optimizations bring the WGC path's CPU profile in line with
or below GDI BitBlt for typical Simba use:

**1. Single-memcpy capture path.** `TSimbaImage.CreateFromWindow` was
previously doing two full-image copies per call (`GFrameBuffer →
ImageData → TImage.FData`). The intermediate `ImageData` buffer is now
elided — WGC's `WGCTryGetImageInto(DstPtr, DstStride)` writes directly
into the TImage's already-allocated storage. Measured against a 652×445
Task Manager window over 5000 calls (3 runs averaged):

| Path | Total | Per call |
|---|---|---|
| Old (two memcpy + ReAllocMem + FreeMem) | ~1378 ms | ~0.276 ms |
| New (single memcpy into TImage.FData) | ~179 ms | ~0.036 ms |
| Improvement | | **~87%** |

Savings scale with capture size — the win is bigger for larger windows
because the eliminated copy was proportional to width × height.

**2. Lazy-stage on idle.** WGC's `FrameArrived` callback used to perform
its full GPU→staging→memcpy pipeline at the DWM compose rate (~60 Hz)
regardless of whether any consumer was reading. For a 1080p capture
this is ~15% of one core consumed entirely by background frame delivery.

This PR tracks the last `WGCTryGetImageInto` call timestamp. If the
FrameArrived callback fires more than 200 ms since the last consumer
read, it skips the staging/memcpy block and just releases the frame
back to the pool. The cached `GFrameBuffer` holds whatever the last
active period produced; the first consumer call after the idle returns
that, the next FrameArrived after the consumer's touch resumes
staging, and steady-state freshness returns within one DWM tick
(~16 ms).

Cold start: `WGCAutoOpen` pre-arms the timestamp to "now", giving a
200 ms warm-up window during which every FrameArrived stages a fresh
frame. Single-shot IDE consumers (image debug viewer, ACA on first
target pick) that call `GetImage` immediately after `SetWindow` get a
fresh frame on their first call.

Measured idle CPU savings (5-second pure-idle window, mean of 3 runs):

| Target | Before | After | Reduction |
|---|---|---|---|
| Task Manager 652×445 | ~6.7% of one core | ~1.5% | ~4–5× |
| Claude window 2576×1416 | ~30.5% of one core | ~0.7% | **~40×** |

After both optimizations, the WGC path uses:
- Sub-µs per call when no new frame has arrived (just a mutex lock + bounds check; the cached frame is still valid)
- ~35 µs per call when staging a fresh frame at OSRS sizes
- ~0% background CPU when idle (skipping staging for unread frames)

Net: a "bad scripter" hot loop calling `Target.GetImage()` 1000×/sec
on an OSRS-sized window pays ~3.5% of one core (vs ~28% under the
pre-optimization implementation).

Benchmark programs are checked in under `Source/test/wgc/`:
- `bench_getimage` — per-call cost
- `bench_idle` — idle-CPU comparison + post-idle resume sanity check
- `test_coldstart` — first-call-after-WGCAutoOpen regression test
- `test_window_close` — target-process-dies-during-capture survival test
- `test_resize_storm` — concurrent reader hammering + 50Hz window-resize stress test

## Robustness

Beyond the WGC plumbing itself, several real-world failure modes are handled:

- **Target window closes mid-capture**: FrameArrived's exception handler converts the resulting DXGI_ERROR to E_FAIL; the cached buffer is left untouched; `WGCTryGetImageInto` returns False until a new target is opened. Verified by `test_window_close`.
- **Target window resized during active capture**: `GFrameBufferLock` covers both the dimension-change branch in FrameArrived AND every read path; no torn frames possible. The dynamic buffer shrinks (not just grows) so switching from 4K → OSRS doesn't leave 32 MB stranded. Verified by `test_resize_storm` (~125 K reader calls/s while window resizes every 20 ms; ~16% legitimate failures from dimension transitions, ~84% successes returning consistent frames).
- **Session switch (target A → target B)**: the prior session's `IClosable.Close` calls happen OUTSIDE `GCaptureLock` (snapshot-then-close-outside-lock pattern). Theoretical AB/BA deadlock with in-flight FrameArrived for the prior target is eliminated. Same pattern as `WGCRelease`.
- **WGC fails on this OS** (pre-Win10 1803, or any class-not-registered HRESULT): every failure path emits a `[WGC]` diagnostic via Simba's standard log so the user sees what went wrong instead of just an empty capture.

## Script-callable diagnostics

Two functions exposed to `.simba` scripts via the standard import registration:

```pascal
function WGCFrameCount: Int64;   // total FrameArrived deliveries this session
function WGCLastError: String;   // most recent WGC error message, '' if none
```

Bot authors can check `WGCLastError` after a suspicious `Target.GetImage()` to diagnose capture failures programmatically.

## Cross-platform safety

`simba.winrt_helpers.pas` and `simba.capture_wgc.pas` are both
`{$IFDEF WINDOWS}` guarded with no-op `{$ELSE}` branches. Linux and
macOS builds compile and link unchanged.

## Testing

Automated, under `Source/test/wgc/`:

- `test_winrt_helpers` — combase round-trip (RoInitialize →
  WindowsCreateString → WindowsGetStringRawBuffer →
  RoGetActivationFactory(Windows.Foundation.Uri) → cleanup).
- `test_winrt_helpers_public` — same via the unit's public API.
- `test_wgc_capture` — captures 5 frames at 200ms+ intervals against
  a GPU-rendered target. Confirms ≥4/5 distinct content hashes
  (live capture, not stale). Saves frame 3 as BMP for visual
  spot-check. Then drives `SimbaNativeInterface.GetWindowImage`
  end-to-end to confirm WGC serves the call through the public
  entry point.
- `test_wgc_capture --notepad` — classic Notepad target. Confirms
  WGC successfully captures from a CPU-rendered window (replaces the
  old `--cpu-only` short-circuit test from when GPU auto-detection
  was still in place).

Manual scenarios (see `docs/wgc-capture-backend/TEST_MATRIX.md`):
RuneLite GPU on/off, Chrome, DX games, minimized windows,
multi-monitor, Apollo IDD, Win10 / Win11 variants.

## Known limitations

1. **Yellow capture border** is a DWM screen overlay drawn around the
   target window for the human user's awareness during capture. On
   Windows 11 (build 22000+) it is suppressed via
   `IGraphicsCaptureSession3.put_IsBorderRequired(False)`. On Windows 10
   it cannot be suppressed by any documented or undocumented API,
   registry key, or group policy — Microsoft version-gated the
   suppression to Win11 exclusively. OBS hits the identical wall and
   already calls the same suppression API (no-op on Win10).
   
   **Critically: the border is NOT in the captured pixel data.** It is
   a DWM overlay only. ACA / DTM / `Target.GetImage()` / any script
   that reads from `WGCTryGetImageInto` sees clean game pixels without
   any border. The visual impact is purely the user's monitor (and
   anything that captures the user's monitor — e.g., Apollo / Moonlight
   streams — will show the border because they capture DWM composition).
   Bot logic and data quality are unaffected. The free upgrade from
   Win10 to Win11 makes the border disappear automatically (our
   existing v3 QI starts succeeding).
2. **Cursor in capture** on Win10 pre-2004 (the
   `IGraphicsCaptureSession2` interface that exposes
   `put_IsCursorCaptureEnabled` is only available from there onward).
   The code QI's for v2 and calls the setter when supported; silently
   falls back to default (cursor included) otherwise.
3. **`WGCAutoOpen`'s secondary teardown path** (when switching from
   window A to window B) holds the capture lock during
   `InternalTearDownSession`. Theoretical AB/BA deadlock with an
   in-flight FrameArrived handler for the prior window. Not observed
   empirically; primary `WGCRelease` path was fixed for this; the
   switch path is a follow-up. Documented in `TEST_MATRIX.md`.

## Closes / refs

Refs the long-standing class of "frozen image when GPU plugin is on"
issues users hit with hardware-accelerated targets. No specific
existing issue number — happy to file an explanatory one if you'd
prefer the design discussion to live there.

---

## What the reviewer would need to do

To reproduce the main user-visible win on a fresh machine:

1. Check out the branch, build with `lazbuild --build-mode=Win64
   Simba.lpi`.
2. Launch RuneLite, enable the GPU plugin.
3. Open Simba, pick the SunAwtCanvas child window via the target
   crosshair, open the image debug viewer.
4. Compare to current `simba2000`: the new build shows live game
   frames; the current build freezes on the last CPU-rendered frame.
