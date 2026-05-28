{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)
}
unit simba.capture_glhook_reader;

{$i simba.inc}

interface

uses
  Classes, SysUtils,
  simba.base;

// Read the most recent OpenGL frame the injected hook DLL has published
// to shared memory for Window's owning PID. Returns False if the target
// isn't hooked, if the published header hasn't been populated yet, or if
// the requested region is empty after clipping to the frame's bounds.
//
// On success, ImageData is allocated via GetMem and contains a Width x
// Height block of BGRA pixels in top-down order (already flipped by the
// hook). Caller frees with FreeMem -- matching the convention of the
// DXGI capture path it replaces.
function GLHookTryGetImage(Window: TWindowHandle;
                           X, Y, Width, Height: Integer;
                           var ImageData: PColorBGRA): Boolean;

implementation

{$IFDEF WINDOWS}

uses
  Windows;

const
  // Mirrors GLCAPTURE_MAGIC in Source/hook/dllmain.pas. ASCII 'SGLC'
  // little-endian. Any divergence between the two constants means the
  // reader will start rejecting every frame -- keep in sync.
  GLCAPTURE_MAGIC: UInt32 = $43474C53;

type
  // Mirrors TGLCaptureHeader in Source/hook/dllmain.pas. Both records
  // must stay byte-identical; the hook writes this layout into shared
  // memory and the reader interprets the same bytes.
  TGLCaptureHeader = packed record
    Magic:         UInt32;
    Width:         UInt32;
    Height:        UInt32;
    BytesPerPixel: UInt32;
    FrameCounter:  UInt64;
    Capacity:      UInt64;
    Reserved:      array[0..31] of Byte;
  end;
  PGLCaptureHeader = ^TGLCaptureHeader;

function GLHookTryGetImage(Window: TWindowHandle;
                           X, Y, Width, Height: Integer;
                           var ImageData: PColorBGRA): Boolean;
var
  Pid: DWORD;
  ShmName, LockName: WideString;
  ShmHandle, LockHandle: THandle;
  ViewPtr: Pointer;
  Hdr: PGLCaptureHeader;
  SrcPixels: PByte;
  FrameW, FrameH: Integer;
  CropX, CropY, CropW, CropH: Integer;
  RowBytes: Integer;
  WaitRes: DWORD;
  Y_: Integer;
  Src, Dst: PByte;
begin
  Result := False;
  ImageData := nil;

  if Window = 0 then Exit;
  if not IsWindow(HWND(Window)) then Exit;

  Pid := 0;
  GetWindowThreadProcessId(HWND(Window), @Pid);
  if Pid = 0 then Exit;

  // Open existing per-PID kernel objects only -- never create. If the
  // target process hasn't been hooked (non-GL host, injection failed,
  // wrong-PID window) both opens return 0 and we cleanly report False.
  ShmName  := WideString('Local\Simba_GL_Capture_')      + WideString(IntToStr(Pid));
  LockName := WideString('Local\Simba_GL_Capture_Lock_') + WideString(IntToStr(Pid));

  ShmHandle := OpenFileMappingW(FILE_MAP_READ, False, PWideChar(ShmName));
  if ShmHandle = 0 then Exit;

  LockHandle := OpenMutexW(SYNCHRONIZE, False, PWideChar(LockName));
  if LockHandle = 0 then
  begin
    CloseHandle(ShmHandle);
    Exit;
  end;

  ViewPtr := MapViewOfFile(ShmHandle, FILE_MAP_READ, 0, 0, 0);
  if ViewPtr = nil then
  begin
    CloseHandle(LockHandle);
    CloseHandle(ShmHandle);
    Exit;
  end;

  try
    // 50ms timeout matches the hook's write-side timeout. Either side
    // missing this window means we drop the frame rather than block.
    WaitRes := WaitForSingleObject(LockHandle, 50);
    if WaitRes <> WAIT_OBJECT_0 then Exit;
    try
      Hdr := PGLCaptureHeader(ViewPtr);

      // Magic + populated frame check. Magic catches both a stale
      // mapping and a header from a future-incompatible layout; the
      // width/height check catches the race between InitSharedCapture
      // and the first CaptureCurrentFrame.
      if Hdr^.Magic <> GLCAPTURE_MAGIC then Exit;
      if Hdr^.BytesPerPixel <> 4 then Exit;

      FrameW := Integer(Hdr^.Width);
      FrameH := Integer(Hdr^.Height);
      if (FrameW <= 0) or (FrameH <= 0) then Exit;

      // Clip requested region against the published frame. A request
      // entirely outside the frame becomes an empty box and we return
      // False -- same convention as DXGI.
      CropX := X;
      CropY := Y;
      CropW := Width;
      CropH := Height;
      if CropX < 0 then begin Dec(CropW, -CropX); CropX := 0; end;
      if CropY < 0 then begin Dec(CropH, -CropY); CropY := 0; end;
      if CropX + CropW > FrameW then CropW := FrameW - CropX;
      if CropY + CropH > FrameH then CropH := FrameH - CropY;
      if (CropW <= 0) or (CropH <= 0) then Exit;

      // Caller asked for `Width x Height` (the original, pre-clip
      // request). We allocate that, but only write into the top-left
      // CropW x CropH cells. Untouched cells contain whatever GetMem
      // returned; this matches DXGI's behaviour where out-of-frame
      // pixels are also unspecified.
      RowBytes := Width * SizeOf(TColorBGRA);
      GetMem(ImageData, RowBytes * Height);

      SrcPixels := PByte(ViewPtr) + SizeOf(TGLCaptureHeader);
      for Y_ := 0 to CropH - 1 do
      begin
        Src := SrcPixels + (CropY + Y_) * FrameW * 4 + CropX * 4;
        Dst := PByte(ImageData) + Y_ * RowBytes;
        Move(Src^, Dst^, CropW * 4);
      end;

      Result := True;
    finally
      ReleaseMutex(LockHandle);
    end;
  finally
    UnmapViewOfFile(ViewPtr);
    CloseHandle(LockHandle);
    CloseHandle(ShmHandle);
  end;

  // If anything above set Result := True but later allocation failed
  // (shouldn't happen with GetMem on Windows, which raises on OOM), the
  // caller would see a True with nil pointer. Belt-and-braces:
  if Result and (ImageData = nil) then
    Result := False;
end;

{$ELSE}

function GLHookTryGetImage(Window: TWindowHandle;
                           X, Y, Width, Height: Integer;
                           var ImageData: PColorBGRA): Boolean;
begin
  ImageData := nil;
  Result := False;
end;

{$ENDIF}

end.
