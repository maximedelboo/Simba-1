# Upstream issue draft

Use this as the body of a tracking issue on `Villavu/Simba` when
opening the PR, or pair with the WGC-branch issue draft if both PRs
are sent at once.

---

## Title

Capture freezes on GPU-rendered windows (RuneLite GPU plugin, browser,
DX games) — proposing DXGI Desktop Duplication backend

## Summary

`simba.nativeinterface_windows.GetWindowImage` uses GDI `BitBlt`
against the target HWND's device context. `BitBlt` cannot read pixels
from a window whose client area is presented via OpenGL, D3D, or
Vulkan — DWM composes the swap-chain to the display while the HWND's
GDI backing keeps returning a stale frame.

User-visible symptom: target a GPU-rendered window in Simba (RuneLite
with its GPU plugin on, a hardware-accelerated browser, a small
DirectX game) and every Simba IDE tool that reads pixels (ACA, DTM
editor, debug image viewer, ShapeBox, colour picker) plus every
`Target.GetImage()` call from a script freezes on the last
CPU-rendered frame.

## Proposed fix

A pure-Pascal DXGI Desktop Duplication backend, shipped as a single
new unit `Source/simba.capture_dxgi.pas`, wired into
`TSimbaNativeInterface_Windows.GetWindowImage` as a one-line
delegation (no fallback, no cascade).

DXGI Desktop Duplication has been available since Win8 (October 2012)
and is what OBS Studio's "display capture", Discord's screen-share
with "Entire Screen" selected, and Microsoft's own RDP server use to
capture composited swap-chain content.

## Why DXGI specifically (vs the sibling WGC PR)

A parallel PR proposes Windows Graphics Capture (WGC), which solves
the same problem. The trade-off:

| | WGC | DXGI |
|---|---|---|
| Compatibility floor | Win10 1803 (Apr 2018) | Win8 (Oct 2012) |
| Yellow capture border | Drawn on Win10, absent on Win11 22000+ | **Never drawn** |
| Cursor in frame | Suppressible | Composited (v1 limitation) |
| Apollo IDD virtual displays | Works | Fails for GPU content |

The yellow border is the dealbreaker for users who don't want a UI
overlay drawn on top of the window being botted. On Win10 there is
**no way** to suppress it from WGC; Microsoft only added the
`IGraphicsCaptureSession3.put_IsBorderRequired` flag on Win11.

This PR is for users / botting scenarios where "no border" outweighs
"Apollo IDD support" and "cursor-out-of-frame".

## What lands in-tree

* `Source/simba.capture_dxgi.pas` — ~1300 lines including the hand-
  typed Pascal interface declarations (IIDs cited from the Windows
  10 SDK 10.0.26100.0 headers).
* `docs/dxgi-capture-backend/` — design plan, PR body, test matrix.
* `Source/test/dxgi/` — acceptance + stress + benchmark programs.
* Five-line edits in `simba.nativeinterface_windows.pas`,
  `simba.target.pas`, `simba.image.pas`, `simba.ide_vars.pas`,
  `Source/Simba.lpr` to wire the unit in.

No new dependencies. No plugin DLL. No compile-time opt-out.

## Open questions for the maintainers

1. Are you open to shipping **both** WGC and DXGI branches and letting
   users pick? They are complementary (no border vs Apollo / cursor
   handling). A small runtime switch (`AdvancedSettings → Capture
   backend`) would let users choose without recompiling.

2. The pre-Win8 cutoff is from 2012; we propose making that a hard
   floor and surfacing a clear `DXGILastError` rather than a stale
   frame. Acceptable?

3. The Apollo IDD limitation is real but narrow (the user explicitly
   directed it out of scope). If wider Apollo support is a hard
   requirement, the WGC branch is the right answer for that subset
   of users and we'd recommend shipping both.

## How to validate

```bash
# from Source/
"/c/fpcup/lazarus/lazbuild.exe" --build-mode=Win64 Simba.lpi
cd test/dxgi
"/c/fpcup/lazarus/lazbuild.exe" --build-mode=Default test_dxgi_capture.lpi
./test_dxgi_capture.exe <hwnd-of-an-animating-window>
```

Manual: open Simba, target a RuneLite window with the GPU plugin on,
open the debug image viewer — pixels should update live AND no yellow
border should appear around RuneLite.
