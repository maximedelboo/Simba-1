# Phase 7 — Inline hook engine

Builds the trampoline + patch primitive described in NEXT_STEPS.md §1. All
work happens inside the existing `simba_gl_hook.dll`. **Nothing is patched
into RuneLite during this phase** — the engine is validated against an
in-DLL self-test target. Whether to install on real `wglSwapBuffers` is a
phase-8 question.

Scope = three SDD tasks (7.1, 7.2, 7.3) executed in order. Each gets
implementer + spec-compliance review + code-quality review.

## Task 7.1 — Hook engine core

**Goal:** A reusable primitive that patches a function with an absolute
14-byte jump and produces a callable trampoline preserving the original.

**File:** `Source/hook/hook_engine.pas`

**Public API:**
```pascal
type
  THookHandle = record
    Target: Pointer;        // address of patched function
    Trampoline: Pointer;    // call this to invoke original behavior
    OrigBytes: array[0..13] of Byte;  // for uninstall
    Installed: Boolean;
  end;

function HookEngine_Install(Target, Replacement: Pointer;
                            const ExpectedPrologue: array of Byte;
                            out Handle: THookHandle;
                            out errMsg: string): Boolean;

function HookEngine_Uninstall(var Handle: THookHandle;
                              out errMsg: string): Boolean;
```

**Behavior:**
1. **Validate prologue.** If `Length(ExpectedPrologue) > 0`, compare the
   first N bytes at `Target` against `ExpectedPrologue`. On mismatch, error
   out cleanly without modifying anything. (Caller passes 5 bytes for
   wglSwapBuffers — the safety check against future Windows updates.)
2. **Allocate trampoline.** `VirtualAlloc(nil, 64, MEM_COMMIT or
   MEM_RESERVE, PAGE_EXECUTE_READWRITE)`. 64 bytes is plenty (14 bytes of
   copied prologue + 14 bytes of return jump + 36 bytes of padding).
3. **Build trampoline.** Copy 14 bytes from `Target` to trampoline. Then
   append the 14-byte absolute jump `48 B8 <imm64 = Target+14> FF E0`
   ("movabs rax, addr; jmp rax").
4. **Save original bytes** into `Handle.OrigBytes` for uninstall.
5. **Patch target.** `VirtualProtect(Target, 14, PAGE_EXECUTE_READWRITE,
   oldProt)`. Write the 14-byte absolute jump `48 B8 <imm64 =
   Replacement> FF E0`. Restore protection. `FlushInstructionCache(GetCurrentProcess(),
   Target, 14)`.
6. **Populate handle** and return True.

**`HookEngine_Uninstall`** is the reverse: VirtualProtect → write back
`OrigBytes` → restore protection → FlushInstructionCache → VirtualFree
trampoline → zero the handle.

**Error reporting:** match `Source/simba.inject.pas` style —
`<which call> failed (code N): <SysErrorMessage(N)>`. Never raise from
inside the engine; errors flow through `errMsg`.

**No external dependencies** beyond `Windows` and `SysUtils`. No DDetours,
no length disassembler, no third-party code.

**Implementation note:** the JMP bytes `48 B8 ?? ?? ?? ?? ?? ?? ?? ?? FF
E0` are exactly 12 bytes. We pad to 14 with two `90` NOPs to make the patch
size deterministic. (Alternative: `48 B8 imm64; FF E0` is 12, then 2 NOPs
to reach 14 — either works. Pick one and document it.)

Actually correcting myself: `48 B8 imm64` is 10 bytes (`48 B8` + 8-byte
imm), and `FF E0` is 2 bytes — so total is 12 bytes. To make a stable
14-byte patch, append two `90` NOPs at the end of the patch. The
trampoline likewise uses a 14-byte jump (12 bytes + 2 NOPs) for symmetry,
though it could be 12.

## Task 7.2 — In-DLL self-test (no injection)

**Goal:** Prove the hook engine works by hooking a function inside the
DLL itself, invoking the hook, and verifying both the patched path
(returns hook value) and the trampoline path (returns original value).

**File:** add to `Source/hook/dllmain.pas`

**Implementation:**
1. Define `TestTarget(x: Integer): Integer` — returns `x + 42`. Compile
   with `{$O-}` to disable optimization so we get a stable, hookable
   prologue. Verify (by adding logging of the first 5 bytes) that its
   prologue has at least 14 bytes of non-RIP-relative instructions; if
   FPC generates something hostile (e.g. a tail-call or RIP-relative
   access), write the function in inline assembly to force a known-safe
   prologue.
2. Define `TestReplacement(x: Integer): Integer` — returns `x + 99`.
3. Define `TestHookEngine(): string` that:
   - Calls `TestTarget(10)` once, expects 52.
   - Calls `HookEngine_Install(@TestTarget, @TestReplacement, [], H, err)`.
   - On install failure, returns `'FAIL: install: ' + err`.
   - Calls `TestTarget(10)` again, expects 109.
   - Calls the trampoline (`PTrampolineFn(H.Trampoline)(10)`) — expects 52.
   - Calls `HookEngine_Uninstall(H, err)`.
   - Calls `TestTarget(10)` once more, expects 52.
   - Returns `'PASS'` on full success or a diagnostic string on any mismatch.
4. Wire `TestHookEngine()` into the existing `Probe` export so
   `rundll32 simba_gl_hook.dll,Probe` runs the test and logs the result.

**Acceptance:** Loading the DLL via rundll32 produces a `PASS` line in
`%TEMP%\simba_hook.log`. Failure produces a diagnostic line identifying
which check failed.

## Task 7.3 — wglSwapBuffers hook prep (NO INSTALL)

**Goal:** Write the code that *would* install a hook on `wglSwapBuffers`,
gated behind a runtime opt-in. Default behavior: log the planned patch
without applying it. This validates the install plumbing against the real
target's address without touching RuneLite's binary.

**File:** add to `Source/hook/dllmain.pas`

**Implementation:**
1. Define `WglSwapBuffersHook(hdc: HDC): BOOL; stdcall;` — for now, just
   calls the trampoline and logs every 60th frame (so the log doesn't get
   spammed at 60 fps).
2. Define `PrepareWglHook()` that runs after env reporting in the
   `initialization` block:
   - Get the address of `wglSwapBuffers`.
   - Read its first 14 bytes.
   - Compare against `EXPECTED_PROLOGUE = [$48, $89, $5C, $24, $08]` (the
     5-byte sanity check captured in earlier phases).
   - On mismatch, log `'wgl_hook: prologue mismatch — refusing to install'`
     with both expected and actual bytes.
   - On match, log `'wgl_hook: prologue OK, install code ready'`. **Do NOT
     install** unless an env var `SIMBA_HOOK_INSTALL=1` is set, in which
     case proceed to call `HookEngine_Install` and log the result.
3. The runtime opt-in (env var check) keeps the default safe — RuneLite
   won't be modified unless the user explicitly opts in for testing.

**Acceptance:**
- Injecting into RuneLite without `SIMBA_HOOK_INSTALL=1` produces the
  `prologue OK, install code ready` log line.
- Injecting with `SIMBA_HOOK_INSTALL=1` actually installs the hook (this
  is the user's call to test; the implementer does NOT run this test).
- The implementer's testing is limited to: build cleanly, inject into
  Notepad (where wglSwapBuffers won't be present), verify graceful
  handling (the `if HasOpenGL then` branch in PrepareWglHook simply
  doesn't run).

## SDD process for each task

1. Dispatch fresh implementer subagent with full task text + context. It
   asks questions, then implements, tests (build cleanly, run self-test
   where applicable), commits **nothing** (the controller commits).
2. Dispatch fresh spec-compliance reviewer with the task spec + the
   implementer's diff. Reviewer answers: "does the code match the spec,
   nothing extra, nothing missing?" Implementer fixes spec gaps, reviewer
   re-reviews until clean.
3. Dispatch fresh code-quality reviewer with the diff + project
   conventions. Reviewer answers: "any bugs, security issues, style
   violations, missing error handling?" Implementer fixes, reviewer
   re-reviews until clean.
4. Controller commits the task as one commit on `pascal-injection-poc`.
5. Move to next task.

After all three tasks: dispatch a final code-reviewer for the entire
phase against the merged set of changes.

## Out of scope for this phase

- **Actually installing the wgl hook on RuneLite by default** — task 7.3
  is gated behind an env var explicitly to avoid this.
- **D3D11 / WGL interop** — phase 8.
- **IPC** — phase 9.
- **Anything in `Source/Simba.lpr`** — the main exe stays untouched.

## Estimated effort

- 7.1: ~150 LoC, ~30 min implementation, ~15 min reviews
- 7.2: ~70 LoC, ~20 min implementation, ~10 min reviews
- 7.3: ~50 LoC, ~15 min implementation, ~10 min reviews
- Total: ~270 LoC, ~2 hours wall-clock including review loops
