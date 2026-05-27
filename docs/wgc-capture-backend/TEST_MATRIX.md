# Phase 6 — Testing matrix

This is the human-in-the-loop testing checklist for the WGC capture
backend. Subagent code-write phases (1–5) and the automated acceptance
tests at `Source/test/wgc/` only cover a small subset of real-world
scenarios. The matrix below is what an end-user with their actual
target apps should walk through before considering this branch
production-ready.

Automated coverage so far (already passing):
- `test_winrt_helpers` (Phase 1) — WinRT plumbing round-trip
- `test_winrt_helpers_public` (Phase 1 review fixes) — same via the
  public unit API
- `test_wgc_capture` — Task Manager capture, 5 frames at ~108 FPS,
  all hashes distinct, frame_03.bmp visually correct; then a
  `SimbaNativeInterface.GetWindowImage` round-trip confirming WGC
  serves the public entry point.
- `test_wgc_capture --notepad` — classic Notepad target; confirms WGC
  successfully captures from a CPU-rendered window. Replaces the old
  `--cpu-only` short-circuit test from when GPU auto-detection was in
  place.

Below is what remains as human verification. Each row's evidence
column lists the artefact you should capture (frame hash sequence,
saved BMP, frame counter delta).

## The 11 scenarios

| # | Target | Setup | Expected behavior | What to verify |
|---|---|---|---|---|
| 1 | RuneLite, GPU plugin **OFF** | Launch RuneLite, untick "GPU" in plugin config, log in | WGC serves | Capture 5 frames during walk/idle animation. ≥4/5 distinct. BMP visually correct. |
| 2 | RuneLite, GPU plugin **ON** | Same as #1 but tick "GPU" in plugin config | WGC serves (BitBlt would freeze) | Capture 5 frames during obvious movement. ≥4/5 distinct. BMP shows live content. **This is the main user-visible win.** |
| 3 | Notepad (classic, not the UWP one) | Open Notepad, type some text | WGC (no opt-out, no auto-detection; pure replacement) | WGCFrameCount climbs; capture goes via WGC. Content live. (Automated in `--notepad` test.) |
| 4 | Chrome / Edge (hardware-accelerated canvas page) | Open a page with active canvas animation (e.g. an HTML5 game) | WGC | Capture 5 frames. ≥4/5 distinct. BMP shows live canvas. Chrome is the canonical "non-RuneLite GPU" target. |
| 5 | Standalone D3D11 / D3D12 demo or small game | Run any DX11 sample (e.g. `MiniEngine`, an indie game) | WGC | Capture 5 frames during motion. ≥4/5 distinct. |
| 6 | Minimized window | After WGCAutoOpen succeeds, minimize the target window. Wait 2s, capture 3 more frames. | WGC keeps delivering offscreen frames | The frames continue to advance (Windows composites minimized hardware-accelerated windows offscreen). `WGCFrameCount` keeps climbing. BMP shows content even when window is invisible. |
| 7 | Target dragged between monitors | Multi-monitor setup. WGCAutoOpen, then drag the target to a different monitor mid-capture. | WGC follows the window | Capture continues without dimension corruption or capture loss. May see one or two near-identical frames during the transition. |
| 8 | Apollo IDD virtual display + RuneLite GPU **ON** | The user's specific setup that motivated this whole project. Stream this machine via Apollo / Moonlight. | WGC | Both ACA in the IDE and `Target.GetImage()` from a script produce live frames. The "frozen frame" bug from BitBlt no longer reproduces. |
| 9 | Win10 1809 or earlier (WGC unavailable) | Run on a Win10 pre-1803 (`winver` ≤ 17134) machine | Simba refuses to capture, surfaces a clear error | WGCAutoOpen fails (RoGetActivationFactory returns class-not-registered for the WGC types). `WinRT_LastError()` says why. `GetWindowImage` returns False — there is no fallback. Pre-1803 is documented as an unsupported platform. |
| 10 | Win10 (any version) | Run on any Win10 build | WGC; yellow capture border visible | Capture works. The yellow capture border IS visible around the captured surface because `IGraphicsCaptureSession3` is Windows-11-only (build 22000+); Microsoft did not backport it to Win10. There is no way to suppress on Win10. |
| 11 | Win11 (any version) | Run on Win11 build 22000+ | WGC; no border | Capture works; **no yellow border** (`IGraphicsCaptureSession3.put_IsBorderRequired(False)` succeeds). |

## Test driver

`Source/test/wgc/test_wgc_capture.lpr` supports:
- Positional HWND arg: captures from that specific window.
- Default (no arg): `GetForegroundWindow` fallback.
- `--notepad` mode: finds classic Notepad, asserts WGCFrameCount climbs
  and WGCTryGetImage produces a valid frame (the pure-replacement
  expectation: WGC handles CPU-rendered windows correctly).

Use these patterns to drive scenarios 1, 2, 4, 5, 6, 7, 8 against your
specific target windows. Find HWNDs via Spy++ or PowerShell:

```powershell
Get-Process -Name RuneLite | ForEach-Object {
  Add-Type -AssemblyName System.Windows.Forms
  "$($_.Id) $($_.MainWindowHandle) $($_.MainWindowTitle)"
}
```

For RuneLite specifically, the **SunAwtCanvas** child window — not the
top-level — is what should be targeted.

## Acceptance gate for the upstream PR

For the WGC backend PR to be considered "ready for upstream review":

- Scenarios 1, 2, 3, 4, 9, 11 MUST pass on the contributor's machine.
- Scenario 8 requires the Apollo IDD setup — note it as "verified by
  maintainer in their specific environment, not reproducible in CI"
  in the PR body.
- Scenarios 5, 6, 7, 10 are nice-to-have; if any is blocked, document
  the limitation in the PR.

## Known limitations to call out in the PR body

- **Yellow capture border on all Windows 10 versions** — DWM screen
  overlay drawn around the target window while WGC is capturing. The
  border is NOT in captured frames (verified against OBS dev community
  and Microsoft docs; OBS recordings via WGC don't contain it either,
  same architectural reason). ACA / DTM / scripts read clean pixels.
  The visual is on the user's monitor only. Suppression API
  (`IGraphicsCaptureSession3.put_IsBorderRequired(False)`) is Win11
  exclusive (build 22000+); no Win10 backport, no registry/policy
  workaround. OBS hits the identical wall and ships the same code we
  do (no-op on Win10). Free Win11 upgrade removes the border
  automatically — our existing v3 QI starts succeeding.

- **Cursor included in capture** when `IsCursorCaptureEnabled` setter
  is unavailable (Win10 pre-2004). Branch already calls
  `put_IsCursorCaptureEnabled(False)` on `IGraphicsCaptureSession2`
  when available; older OSes silently fall back to the default
  (cursor included).

- **WGCAutoOpen's secondary teardown path** (when switching from
  window A to window B mid-capture) holds `GCaptureLock` while
  calling `InternalTearDownSession` — theoretical deadlock if a
  FrameArrived handler for window A is in flight and blocked on the
  same lock. The primary `WGCRelease` path was fixed for this; the
  switch path is documented as a follow-up. Has not been observed
  empirically.

## What this matrix does NOT cover

- Anti-cheat interaction. The WGC capture path is purely DWM-side; it
  does not inject or hook into the target process. From the target's
  POV nothing changes vs. running with BitBlt — there is no new
  detection vector this branch introduces.

- DRM-protected content (Netflix, Spotify Premium, Widevine-bound
  apps). WGC sessions for these will start successfully but the
  delivered frames may be all-black per the OS's content-protection
  policy. Not a regression vs. BitBlt (which also can't capture them).

- Performance under sustained 4K/multi-monitor stress. The single
  D3D11 device singleton + reused staging texture pattern should
  scale fine, but no benchmarks have been collected.
