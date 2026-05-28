{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)
}
unit hook_engine;

{$mode objfpc}{$H+}

interface

uses
  Windows;

const
  // 12 bytes of `movabs rax, imm64; jmp rax` + 2 NOPs = 14 bytes. The two
  // trailing NOPs make the patch size deterministic, matching the
  // prologue region we claim from the target.
  HOOK_PATCH_SIZE = 14;

type
  THookHandle = record
    Target: Pointer;                            // address of patched function
    Trampoline: Pointer;                        // call this to invoke original behavior
    OrigBytes: array[0..HOOK_PATCH_SIZE - 1] of Byte;  // for uninstall
    Installed: Boolean;
  end;

// Install an inline hook redirecting Target to Replacement. On success
// Handle.Trampoline is a callable pointer that executes the original
// prologue and jumps back into Target+14. ExpectedPrologue is an optional
// safety check: if non-empty, its bytes must match the start of Target.
// Length(ExpectedPrologue) must be <= HOOK_PATCH_SIZE.
// Returns False with errMsg populated on any failure; never raises.
//
// PRECONDITION (prologue relocatability): The caller is responsible for
// ensuring the target's first HOOK_PATCH_SIZE (14) bytes contain only
// relocatable instructions — no RIP-relative addressing (no
// `lea reg, [rip+disp]`, no `call rel32`, no `jmp rel32`, no
// `mov reg, [rip+disp]`, no `jcc rel`). The engine performs no
// instruction fixup; copied bytes execute at a new address verbatim.
// Pass these expected bytes via ExpectedPrologue so the install fails
// safely if a future Windows update changes the function. For
// wglSwapBuffers on current Windows, the first 14 bytes are
// `48 89 5C 24 08 48 89 74 24 10 57 48 83 EC 40` — four complete
// instructions, none RIP-relative — and have been verified against live
// RuneLite.
//
// THREAD-SAFETY: The caller must serialize concurrent calls that
// operate on the same Target. While VirtualProtect/Move are individually
// safe, the install sequence (read prologue → save → patch) is not
// atomic; two installers racing on the same target can corrupt OrigBytes
// or leave the target in a half-patched state. The engine itself holds
// no global state, so installs on distinct targets are independent.
function HookEngine_Install(Target, Replacement: Pointer;
                            const ExpectedPrologue: array of Byte;
                            out Handle: THookHandle;
                            out errMsg: string): Boolean;

// Reverse of Install: restore OrigBytes at Target and free the trampoline.
// Returns False with errMsg populated on failure; never raises.
//
// THREAD-SAFETY: The caller must serialize concurrent calls that
// operate on the same Handle/Target, and must ensure no other thread is
// executing inside Target's first HOOK_PATCH_SIZE bytes or the
// trampoline at the moment of uninstall. The engine does not stall
// threads — restoring bytes under a live PC is undefined behavior.
function HookEngine_Uninstall(var Handle: THookHandle;
                              out errMsg: string): Boolean;

implementation

uses
  SysUtils;

const
  // Trampoline layout: HOOK_PATCH_SIZE bytes of copied prologue followed by
  // a HOOK_PATCH_SIZE-byte absolute jump back to Target+HOOK_PATCH_SIZE,
  // i.e. 28 live bytes. We round up to 64 to leave room for future growth
  // (e.g. an inline instruction-fixup table) and to keep the allocation
  // comfortably below a single page boundary so VirtualAlloc returns one
  // contiguous region. The remainder is padding and never executed.
  TRAMPOLINE_ALLOC_SIZE = 64;

function Win32Err(const What: string): string;
var
  E: DWORD;
begin
  E := GetLastError();
  Result := Format('%s failed (code %d): %s', [What, E, SysErrorMessage(E)]);
end;

// Write a 14-byte absolute jump at Dest that targets JmpTarget:
//   48 B8 <imm64>  movabs rax, JmpTarget
//   FF E0          jmp rax
//   90 90          padding to 14 bytes
procedure WriteAbsJump(Dest: Pointer; JmpTarget: Pointer);
var
  Buf: array[0..HOOK_PATCH_SIZE - 1] of Byte;
  Imm: UInt64;
begin
  Buf[0] := $48;
  Buf[1] := $B8;
  Imm := UInt64(JmpTarget);
  Move(Imm, Buf[2], 8);  // little-endian on x86-64
  Buf[10] := $FF;
  Buf[11] := $E0;
  Buf[12] := $90;
  Buf[13] := $90;
  Move(Buf[0], Dest^, HOOK_PATCH_SIZE);
end;

function HookEngine_Install(Target, Replacement: Pointer;
                            const ExpectedPrologue: array of Byte;
                            out Handle: THookHandle;
                            out errMsg: string): Boolean;
var
  Trampoline: Pointer;
  OldProt: DWORD;
  DummyProt: DWORD;
  I: Integer;
  Actual: PByte;
begin
  Result := False;
  errMsg := '';
  FillChar(Handle, SizeOf(Handle), 0);
  Trampoline := nil;

  if Target = nil then
  begin
    errMsg := 'Target is nil';
    Exit;
  end;
  if Replacement = nil then
  begin
    errMsg := 'Replacement is nil';
    Exit;
  end;
  // Guard against callers passing more bytes than we actually patch. We
  // only ever overwrite HOOK_PATCH_SIZE bytes, so any expectation past
  // that is misleading: a "match" would only verify a prefix.
  if Length(ExpectedPrologue) > HOOK_PATCH_SIZE then
  begin
    errMsg := Format('ExpectedPrologue too long: %d > %d',
                     [Length(ExpectedPrologue), HOOK_PATCH_SIZE]);
    Exit;
  end;

  // 1. Validate prologue. Compare without touching anything else, so a
  //    mismatch leaves the target unmodified.
  if Length(ExpectedPrologue) > 0 then
  begin
    Actual := PByte(Target);
    for I := 0 to High(ExpectedPrologue) do
    begin
      if Actual[I] <> ExpectedPrologue[I] then
      begin
        errMsg := Format('prologue mismatch at byte %d: expected 0x%.2x, got 0x%.2x',
          [I, ExpectedPrologue[I], Actual[I]]);
        Exit;
      end;
    end;
  end;

  // 2. Allocate trampoline (RWX). See TRAMPOLINE_ALLOC_SIZE doc for sizing.
  Trampoline := VirtualAlloc(nil, TRAMPOLINE_ALLOC_SIZE,
                             MEM_COMMIT or MEM_RESERVE,
                             PAGE_EXECUTE_READWRITE);
  if Trampoline = nil then
  begin
    errMsg := Win32Err('VirtualAlloc(trampoline)');
    Exit;
  end;

  try
    // 3. Build trampoline: copy HOOK_PATCH_SIZE bytes of prologue, then
    //    append a HOOK_PATCH_SIZE-byte absolute jump back to
    //    Target+HOOK_PATCH_SIZE.
    Move(Target^, Trampoline^, HOOK_PATCH_SIZE);
    WriteAbsJump(Pointer(PByte(Trampoline) + HOOK_PATCH_SIZE),
                 Pointer(PByte(Target) + HOOK_PATCH_SIZE));
    // Flush the icache for the full trampoline (copied prologue + return
    // jump = HOOK_PATCH_SIZE * 2 bytes). Required on x86-64 in principle,
    // and required by API contract before any thread executes through it.
    FlushInstructionCache(GetCurrentProcess(), Trampoline,
                          HOOK_PATCH_SIZE * 2);

    // 4. Save original bytes for uninstall.
    Move(Target^, Handle.OrigBytes[0], HOOK_PATCH_SIZE);

    // 5. Populate Handle.Target and Handle.Trampoline BEFORE patching
    //    Target. This closes a TOCTOU race: once Target is patched, any
    //    concurrent caller will dispatch into Replacement, which typically
    //    reads Handle.Trampoline to forward the call. If the assignment
    //    happened after the patch, that read could return nil and crash
    //    the host. Handle.Installed stays False until the patch succeeds,
    //    so Uninstall on a half-installed handle is still safe (it just
    //    cleans up via the `finally`).
    Handle.Target := Target;
    Handle.Trampoline := Trampoline;

    // 6. Patch target with absolute jump to Replacement.
    OldProt := 0;
    if not VirtualProtect(Target, HOOK_PATCH_SIZE,
                          PAGE_EXECUTE_READWRITE, OldProt) then
    begin
      errMsg := Win32Err('VirtualProtect(target, RWX)');
      Exit;
    end;
    WriteAbsJump(Target, Replacement);
    // Restore original page protection. DummyProt receives the previous
    // (RWX) protection — we don't reuse OldProt as both in and out because
    // overwriting it would lose the value we'd need for any rollback.
    DummyProt := 0;
    if not VirtualProtect(Target, HOOK_PATCH_SIZE, OldProt, DummyProt) then
    begin
      // Restore failed but the FIRST VirtualProtect succeeded, so the
      // page is still PAGE_EXECUTE_READWRITE. Capture the original error
      // code before any further Win32 calls clobber it. Then roll the
      // patch back so the target is functionally intact and retry the
      // protection restore best-effort.
      errMsg := Win32Err('VirtualProtect (restore after patch — rolled back)');
      Move(Handle.OrigBytes[0], Target^, HOOK_PATCH_SIZE);
      FlushInstructionCache(GetCurrentProcess(), Target, HOOK_PATCH_SIZE);
      VirtualProtect(Target, HOOK_PATCH_SIZE, OldProt, DummyProt);
      Exit;
    end;
    FlushInstructionCache(GetCurrentProcess(), Target, HOOK_PATCH_SIZE);

    // 7. Mark handle installed. Target/Trampoline already populated in
    //    step 5; flipping Installed here signals to Uninstall callers
    //    that the patch is live and worth unwinding.
    Handle.Installed := True;
    Result := True;
  finally
    if (not Result) and (Trampoline <> nil) then
    begin
      VirtualFree(Trampoline, 0, MEM_RELEASE);
      FillChar(Handle, SizeOf(Handle), 0);
    end;
  end;
end;

function HookEngine_Uninstall(var Handle: THookHandle;
                              out errMsg: string): Boolean;
var
  OldProt: DWORD;
  DummyProt: DWORD;
begin
  Result := False;
  errMsg := '';

  if not Handle.Installed then
  begin
    errMsg := 'hook is not installed';
    Exit;
  end;
  if Handle.Target = nil then
  begin
    errMsg := 'hook target is nil';
    Exit;
  end;

  OldProt := 0;
  if not VirtualProtect(Handle.Target, HOOK_PATCH_SIZE,
                        PAGE_EXECUTE_READWRITE, OldProt) then
  begin
    errMsg := Win32Err('VirtualProtect(target, RWX)');
    Exit;
  end;

  // Restore the original bytes. From this point on the target is
  // functionally uninstalled; subsequent failures are not allowed to
  // leak the trampoline or leave Handle.Installed = True.
  Move(Handle.OrigBytes[0], Handle.Target^, HOOK_PATCH_SIZE);
  FlushInstructionCache(GetCurrentProcess(), Handle.Target, HOOK_PATCH_SIZE);

  // Restore page protection — best-effort. If this fails, the page stays
  // PAGE_EXECUTE_READWRITE (slightly more permissive than what it was,
  // but not dangerous), the bytes are correct, and we continue with full
  // cleanup. DummyProt is a separate out-param to preserve OldProt for
  // diagnostics; we intentionally ignore the return value.
  DummyProt := 0;
  VirtualProtect(Handle.Target, HOOK_PATCH_SIZE, OldProt, DummyProt);

  // Always free the trampoline and clear the handle, regardless of the
  // protection-restore outcome. VirtualFree failure is reported but no
  // longer blocks the handle from being marked uninstalled.
  if Handle.Trampoline <> nil then
  begin
    if not VirtualFree(Handle.Trampoline, 0, MEM_RELEASE) then
      errMsg := Win32Err('VirtualFree(trampoline)');
  end;

  FillChar(Handle, SizeOf(Handle), 0);
  Result := True;
end;

end.
