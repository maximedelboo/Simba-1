# Issue draft — file this on Villavu/Simba BEFORE opening the PR

**Title:** Built-in WGC capture path replacing BitBlt — RFC

**Body:**

Hi! I've prototyped a Windows Graphics Capture (WGC) capture backend
built into Simba and would like to gauge interest before opening a
PR.

## Problem

Simba's default window-capture path is GDI `BitBlt` against the
target HWND's device context. For any HWND that's been promoted to
an OpenGL or DirectX drawable (RuneLite's GPU plugin, hardware-
accelerated browsers, DX games, etc.), the HWND's GDI backing store
isn't updated when the app presents — `BitBlt` reads stale pixels
indefinitely. This is a fundamental Win32 architectural limit, not a
Simba bug, but it means ACA / DTM editor / debug image viewer / a
script's `Target.GetImage()` all freeze on the last CPU-rendered
frame.

I diagnosed this in depth against my own RuneLite + GPU + Apollo
virtual-display setup recently. The well-known fix-of-last-resort is
`libremoteinput` (the wasp-plugins JVM-injection layer) which
bypasses display capture entirely — but it only helps scripts that
include WaspLib's `fakeinput.simba`. The IDE tools and bare scripts
stay broken.

## Proposed direction

WGC replaces BitBlt and is the sole window-capture path. WGC
captures via DWM, sees per-window swapchain content for any
rendering technology (GL / DX / Vulkan / GDI), and survives the
Apollo IDD virtual-display gotcha that breaks DXGI desktop
duplication. `simba.nativeinterface_windows.GetWindowImage` is a
one-line delegation to `WGCTryGetImage` — no cascade, no fallback.
Pre-1803 is unsupported (cutoff is October 2017; reasonable system
requirement in 2026).

Implementation is **pure Pascal, in-tree** — no external plugin DLL,
no CMake / MSVC added to Simba's build chain. This adds ~280 lines
of reusable WinRT plumbing (`simba.winrt_helpers`) and ~1500 lines of
WGC-specific interface declarations and capture logic
(`simba.capture_wgc`). The WinRT cost is paid once; future WinRT
integrations would reuse the helpers unit.

A working prototype is at:
https://github.com/maximedelboo/Simba-1/tree/wgc-capture-backend

Design doc:
https://github.com/maximedelboo/Simba-1/blob/wgc-capture-backend/docs/wgc-capture-backend/PLAN.md

Test matrix:
https://github.com/maximedelboo/Simba-1/blob/wgc-capture-backend/docs/wgc-capture-backend/TEST_MATRIX.md

## Open questions

A few design points where I'd value your input before polishing
toward a PR:

1. **Is built-in WGC the desired direction**, or do you prefer this
   stays a wasp-plugin? My argument for in-tree is in the design doc
   (`PLAN.md` § "Why pure Pascal even though it's painful"), short
   version: plugins recreate the friction we're trying to escape
   (users without the plugin still see the broken IDE tools).

2. **Pure replacement vs hybrid**: the current shape is pure
   replacement — WGC IS the capture path, full stop. There is no
   BitBlt fallback, no CPU-only short-circuit, and no libremoteinput
   fast-path. Earlier iterations of this branch had all of those;
   the maintenance cost of parallel paths exceeded the benefit.
   Pre-Win10 1803 is treated as an unsupported platform (cutoff is
   from October 2017). Is that the right call, or do you want me
   to bring BitBlt back as a fallback?

## Performance

Two optimizations bring WGC's CPU profile in line with or below BitBlt
for typical Simba use. Details in `PR_BODY.md`; headline numbers:

- **Per-call cost** (eliminating an unnecessary intermediate copy):
  ~0.276 ms → ~0.036 ms per `Target.GetImage()` at 652×445. ~87%
  improvement.
- **Idle CPU** (lazy-staging when no consumer has read recently):
  Task Manager 652×445: ~6.7% → ~1.5% (~5×); Claude 2576×1416:
  ~30.5% → ~0.7% (~40×).
- Cold start handled via a 200 ms warm-up window on `WGCAutoOpen` so
  single-shot IDE consumers (image debug viewer, ACA on first target
  pick) don't see an empty frame.

Net: a hot loop calling `Target.GetImage()` 1000×/sec on an
OSRS-sized window costs ~3.5% of one core after these optimizations.

## Known limitations to land in the PR body

- Yellow WGC capture border on every Win10 version is a DWM screen
  overlay only — NOT included in captured frames (verified vs OBS
  community and Microsoft docs). Bot/IDE-tool data is unaffected. The
  v3 session interface that exposes `put_IsBorderRequired` is Win11
  exclusive (build 22000+); Microsoft did not backport, there is no
  registry/policy workaround. Free Win10→Win11 upgrade removes the
  border automatically.
- Cursor included in capture on Win10 pre-2004 (no
  `IGraphicsCaptureSession2.put_IsCursorCaptureEnabled`).
- `WGCAutoOpen`'s secondary teardown path holds the capture lock
  during `IClosable.Close` (theoretical deadlock, not observed
  empirically; the primary `WGCRelease` path was fixed for this).

## Effort estimate to PR-ready

Maybe 1–2 days of polish from current state, mostly testing matrix
verification on machines other than mine.

Thoughts?
