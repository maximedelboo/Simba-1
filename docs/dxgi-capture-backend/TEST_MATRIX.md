# DXGI capture backend — test matrix

What was verified before the PR went out, and what remains owned by
the user / reviewers to check on their hardware.

## Automated tests (in `Source/test/dxgi/`)

| Program | What it verifies | Pass criteria | Last status |
|---|---|---|---|
| `test_dxgi_capture.exe <HWND>` | End-to-end capture lifecycle against a real target HWND | 5 frames captured, 4+/5 distinct hashes against an animating target, BMP written, clean Release | PASS (Task Manager target, 5/5 distinct) |
| `test_window_close.exe` | Capture survives target-window destruction | Spawn notepad, post WM_CLOSE mid-loop, no crash, post-close captures fail fast | PASS (0 false-True calls after WM_CLOSE) |
| `bench_idle.exe` | CPU cost at realistic ACA/DTM poll rate (60 Hz) | < 20% one-core when foreground window has typical motion | PASS (10.3% one-core on dev box) |
| `bench_getimage.exe` | Per-call latency for full-window capture | Median < 10 ms for a 652x445 window | PASS (median 2.9 ms) |

## Manual scenarios

| Scenario | Expectation | Notes |
|---|---|---|
| RuneLite, GPU plugin **OFF** | Live capture, **no yellow border** | The "no border" is the user-visible signal that DXGI is engaged (WGC would draw one on Win10) |
| RuneLite, GPU plugin **ON** | Live capture, no yellow border | The whole point of this branch |
| Hardware-accelerated browser (Chrome / Edge canvas) | Live capture | Same regression class as RuneLite GPU plugin |
| Notepad (classic) | Live capture when window content changes | DXGI's per-monitor model means we see whatever the OS composites; static Notepad produces identical frames, expected |
| DirectX game in windowed mode | Live capture | |
| Window dragged from monitor A to monitor B | Capture continues on the new monitor without manual reset | Internal switch logic re-opens `IDXGIOutputDuplication` on the new `IDXGIOutput1` |
| Monitor disconnect / reconnect mid-capture | Recover within one frame after reconnect | `DXGI_ERROR_ACCESS_LOST` path re-acquires once; subsequent failures bubble up as `DXGILastError` |
| Display mode change (rotation, DPI, resolution) | Recover within one frame | Same `ACCESS_LOST` recovery path |
| Target window minimised | Capture returns frames of whatever DWM composites at the window's last screen rect (typically the desktop / next-Z-order window) | DXGI is per-monitor; minimised windows aren't "captured" in the WGC sense. Document for users. |
| Target window destroyed | `IsWindow` check refuses subsequent calls; no crash; subsequent `DXGIAutoOpen` on a new HWND succeeds | Verified by `test_window_close.exe` |
| Locked screen / Ctrl-Alt-Del / UAC | `AcquireNextFrame` returns `DXGI_ERROR_ACCESS_LOST` continuously while the secure desktop is up, recovers automatically when the user returns | Expected DXGI behaviour |
| RDP session | Works; `IDXGIOutput1` is bound to the RDP framebuffer | |

## Known limitations (deliberately not fixed in v1)

* **Cursor in frame.** DXGI composites the cursor into the captured
  pixels. WGC has `IGraphicsCaptureSession2.put_IsCursorCaptureEnabled(False)`;
  DXGI has no equivalent. Strategy A (blank the cursor's bounding rect
  in the cached buffer) is implementable as a follow-up; for v1 we
  document and ship.
* **Apollo IDD virtual display with GPU-rendered content.**
  `DuplicateOutput` against the Apollo IDD output returns
  `DXGI_ERROR_NOT_FOUND` or `DXGI_ERROR_UNSUPPORTED`; users who rely on
  Apollo for headless botting should prefer the WGC branch.
* **Hybrid GPU laptops.** Single D3D11 device on the default-driver
  adapter; if the target monitor is owned by a different adapter,
  `DuplicateOutput` returns `E_INVALIDARG`. `DXGILastError` will read
  "No IDXGIOutput1 found for HMONITOR ... on the D3D11 device's
  adapter (hybrid-GPU mismatch?)". Follow-up: per-adapter D3D11
  device pool.
* **HDCP / DRM-protected surfaces.** Pixels come back as black or
  the frame is rejected entirely. Same behaviour as WGC, same
  behaviour as any other capture API for this content class.

## Exit codes for the automated runner

`test_dxgi_capture.exe`:

| Code | Meaning |
|---|---|
| 0 | SUCCESS — capture roundtrip works, distinct hashes (assuming animating target), BMP valid |
| 1 | DXGIAutoOpen failed; check `DXGILastError` |
| 2 | First-frame capture never succeeded (most often: hybrid-GPU mismatch, or HDCP-protected content) |
| 3 | All 5 frames identical (capture is "live" only in name; target may be static — re-run with a Task Manager target) |
| 4 | BMP write failed |

`test_window_close.exe`:

| Code | Meaning |
|---|---|
| 0 | SUCCESS |
| 1 | Setup failure (couldn't spawn / find notepad) |
| 2 | Pascal exception during stress (caught by try/except) |
| 3 | Capture kept succeeding for too long after target destruction (stale-handle should fail fast) |
