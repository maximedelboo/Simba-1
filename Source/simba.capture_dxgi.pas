{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)
}
unit simba.capture_dxgi;

{$i simba.inc}

interface

uses
  Classes, SysUtils,
  simba.base;

procedure DXGIAutoOpen(Window: TWindowHandle);
function DXGITryGetImage(Window: TWindowHandle; X, Y, Width, Height: Integer; var ImageData: PColorBGRA): Boolean;
function DXGITryGetImageInto(Window: TWindowHandle; X, Y, Width, Height: Integer;
                             DstPtr: PColorBGRA; DstStride: Integer): Boolean;
procedure DXGIRelease();
function DXGILastError(): String;
function DXGIFrameCount(): Int64;

implementation

{$IFDEF WINDOWS}

uses
  Windows, syncobjs;

const
  // d3d11.h / d3dcommon.h / dxgiformat.h constants.
  D3D_DRIVER_TYPE_HARDWARE         = 1;
  D3D11_CREATE_DEVICE_BGRA_SUPPORT = $20;
  D3D11_SDK_VERSION                = 7;
  D3D11_USAGE_STAGING              = 3;
  D3D11_CPU_ACCESS_READ            = $20000;
  D3D11_MAP_READ                   = 1;
  DXGI_FORMAT_B8G8R8A8_UNORM       = 87;

  // dxgi.h HRESULTs we recognise on AcquireNextFrame.
  DXGI_ERROR_WAIT_TIMEOUT          = HRESULT($887A0027);
  DXGI_ERROR_ACCESS_LOST           = HRESULT($887A0026);
  DXGI_ERROR_NOT_FOUND             = HRESULT($887A0002);
  DXGI_ERROR_INVALID_CALL          = HRESULT($887A0001);

const
  // IIDs and vtable orders below are taken from Windows SDK 10.0.26100.0
  // headers (cited inline above each declaration).

  // shared/dxgi.h (line 321): MIDL_INTERFACE("aec22fb8-76f3-4639-9be0-28eb43a67a2e")
  IID_IDXGIObject: TGUID = '{AEC22FB8-76F3-4639-9BE0-28EB43A67A2E}';

  // shared/dxgi.h (line 468): MIDL_INTERFACE("3d3e0379-f9de-4d58-bb6c-18d62992f1a6")
  IID_IDXGIDeviceSubObject: TGUID = '{3D3E0379-F9DE-4D58-BB6C-18D62992F1A6}';

  // shared/dxgi.h (line 606): MIDL_INTERFACE("035f3ab4-482e-4e50-b41f-8a7f8bd8960b")
  IID_IDXGIResource: TGUID = '{035F3AB4-482E-4E50-B41F-8A7F8BD8960B}';

  // shared/dxgi.h (line 1325): MIDL_INTERFACE("2411e7e1-12ac-4ccf-bd14-9798e8534dc0")
  IID_IDXGIAdapter: TGUID = '{2411E7E1-12AC-4CCF-BD14-9798E8534DC0}';

  // shared/dxgi.h (line 1503): MIDL_INTERFACE("ae02eedb-c735-4690-8d52-5a8dc20213aa")
  IID_IDXGIOutput: TGUID = '{AE02EEDB-C735-4690-8D52-5A8DC20213AA}';

  // shared/dxgi.h (line 2101): MIDL_INTERFACE("7b7166ec-21c7-44ae-b21a-c9ae321ae369")
  IID_IDXGIFactory: TGUID = '{7B7166EC-21C7-44AE-B21A-C9AE321AE369}';

  // shared/dxgi.h (line 2313): MIDL_INTERFACE("54ec77fa-1377-44e6-8c32-88fd5f44c84c")
  IID_IDXGIDevice: TGUID = '{54EC77FA-1377-44E6-8C32-88FD5F44C84C}';

  // shared/dxgi.h (line 2553): MIDL_INTERFACE("770aae78-f26f-4dba-a829-253c83d1b387")
  IID_IDXGIFactory1: TGUID = '{770AAE78-F26F-4DBA-A829-253C83D1B387}';

  // shared/dxgi.h (line 2750): MIDL_INTERFACE("29038f61-3839-4626-91fd-086879011a05")
  IID_IDXGIAdapter1: TGUID = '{29038F61-3839-4626-91FD-086879011A05}';

  // shared/dxgi1_2.h (line 292): MIDL_INTERFACE("191cfac3-a341-470d-b26e-a864f428319c")
  IID_IDXGIOutputDuplication: TGUID = '{191CFAC3-A341-470D-B26E-A864F428319C}';

  // shared/dxgi1_2.h (line 2312): MIDL_INTERFACE("00cddea8-939b-4b83-a340-a685226666cc")
  IID_IDXGIOutput1: TGUID = '{00CDDEA8-939B-4B83-A340-A685226666CC}';

  // um/d3d11.h (line 14143): MIDL_INTERFACE("db6f6ddb-ac77-4e88-8253-819df9bbf140")
  IID_ID3D11Device: TGUID = '{DB6F6DDB-AC77-4E88-8253-819DF9BBF140}';

  // um/d3d11.h (line 7763): MIDL_INTERFACE("c0bfa96c-e089-44fb-8eaf-26f8796190da")
  IID_ID3D11DeviceContext: TGUID = '{C0BFA96C-E089-44FB-8EAF-26F8796190DA}';

  // um/d3d11.h (line 1395): MIDL_INTERFACE("1841e5c8-16b0-489b-bcc8-44cfb0d5deae")
  IID_ID3D11DeviceChild: TGUID = '{1841E5C8-16B0-489B-BCC8-44CFB0D5DEAE}';

  // um/d3d11.h (line 2251): MIDL_INTERFACE("dc8e63f3-d12b-4952-b47b-5e45026a862d")
  IID_ID3D11Resource: TGUID = '{DC8E63F3-D12B-4952-B47B-5E45026A862D}';

  // um/d3d11.h (line 2879): MIDL_INTERFACE("6f15aaf2-d208-4e89-9ab4-489535d34f9c")
  IID_ID3D11Texture2D: TGUID = '{6F15AAF2-D208-4E89-9AB4-489535D34F9C}';


type
  IDXGIObject              = interface;
  IDXGIDeviceSubObject     = interface;
  IDXGIResource            = interface;
  IDXGIDevice              = interface;
  IDXGIAdapter             = interface;
  IDXGIAdapter1            = interface;
  IDXGIOutput              = interface;
  IDXGIOutput1             = interface;
  IDXGIOutputDuplication   = interface;
  IDXGIFactory             = interface;
  IDXGIFactory1            = interface;
  ID3D11Device             = interface;
  ID3D11DeviceContext      = interface;
  ID3D11DeviceChild        = interface;
  ID3D11Resource           = interface;
  ID3D11Texture2D          = interface;

  // shared/dxgicommon.h (line 11): DXGI_RATIONAL.
  TDXGI_RATIONAL = record
    Numerator:   UInt32;
    Denominator: UInt32;
  end;
  PDXGI_RATIONAL = ^TDXGI_RATIONAL;

  // shared/dxgicommon.h (line 21): DXGI_SAMPLE_DESC.
  TDXGI_SAMPLE_DESC = record
    Count:   UInt32;
    Quality: UInt32;
  end;
  PDXGI_SAMPLE_DESC = ^TDXGI_SAMPLE_DESC;

  // shared/dxgitype.h (line 83): DXGI_MODE_DESC. DXGI_FORMAT, scanline and
  // scaling enums are widened to UInt32.
  TDXGI_MODE_DESC = record
    Width:            UInt32;
    Height:           UInt32;
    RefreshRate:      TDXGI_RATIONAL;
    Format:           UInt32; // DXGI_FORMAT
    ScanlineOrdering: UInt32; // DXGI_MODE_SCANLINE_ORDER
    Scaling:          UInt32; // DXGI_MODE_SCALING
  end;
  PDXGI_MODE_DESC = ^TDXGI_MODE_DESC;

  // shared/dxgi.h (line 226): DXGI_OUTPUT_DESC.
  TDXGI_OUTPUT_DESC = record
    DeviceName:         array[0..31] of WideChar;
    DesktopCoordinates: TRect;
    AttachedToDesktop:  LongBool;
    Rotation:           UInt32; // DXGI_MODE_ROTATION
    Monitor:            HMONITOR;
  end;
  PDXGI_OUTPUT_DESC = ^TDXGI_OUTPUT_DESC;

  // shared/dxgi.h (line 2516): DXGI_ADAPTER_DESC1.
  TDXGI_ADAPTER_DESC1 = record
    Description:           array[0..127] of WideChar;
    VendorId:              UInt32;
    DeviceId:              UInt32;
    SubSysId:              UInt32;
    Revision:              UInt32;
    DedicatedVideoMemory:  PtrUInt;
    DedicatedSystemMemory: PtrUInt;
    SharedSystemMemory:    PtrUInt;
    AdapterLuid:           record LowPart: UInt32; HighPart: Int32; end;
    Flags:                 UInt32;
  end;
  PDXGI_ADAPTER_DESC1 = ^TDXGI_ADAPTER_DESC1;

  // shared/dxgi1_2.h (line 234): DXGI_OUTDUPL_DESC.
  TDXGI_OUTDUPL_DESC = record
    ModeDesc:                    TDXGI_MODE_DESC;
    Rotation:                    UInt32; // DXGI_MODE_ROTATION
    DesktopImageInSystemMemory:  LongBool;
  end;
  PDXGI_OUTDUPL_DESC = ^TDXGI_OUTDUPL_DESC;

  // shared/dxgi1_2.h (line 241): DXGI_OUTDUPL_POINTER_POSITION.
  TDXGI_OUTDUPL_POINTER_POSITION = record
    Position: TPoint;
    Visible:  LongBool;
  end;
  PDXGI_OUTDUPL_POINTER_POSITION = ^TDXGI_OUTDUPL_POINTER_POSITION;

  // shared/dxgi1_2.h (line 264): DXGI_OUTDUPL_FRAME_INFO.
  TDXGI_OUTDUPL_FRAME_INFO = record
    LastPresentTime:           Int64;
    LastMouseUpdateTime:       Int64;
    AccumulatedFrames:         UInt32;
    RectsCoalesced:            LongBool;
    ProtectedContentMaskedOut: LongBool;
    PointerPosition:           TDXGI_OUTDUPL_POINTER_POSITION;
    TotalMetadataBufferSize:   UInt32;
    PointerShapeBufferSize:    UInt32;
  end;
  PDXGI_OUTDUPL_FRAME_INFO = ^TDXGI_OUTDUPL_FRAME_INFO;

  // um/d3d11.h: D3D11_TEXTURE2D_DESC.
  TD3D11_TEXTURE2D_DESC = record
    Width:          UInt32;
    Height:         UInt32;
    MipLevels:      UInt32;
    ArraySize:      UInt32;
    Format:         UInt32; // DXGI_FORMAT
    SampleDesc:     TDXGI_SAMPLE_DESC;
    Usage:          UInt32; // D3D11_USAGE
    BindFlags:      UInt32;
    CPUAccessFlags: UInt32;
    MiscFlags:      UInt32;
  end;
  PD3D11_TEXTURE2D_DESC = ^TD3D11_TEXTURE2D_DESC;

  // um/d3d11.h: D3D11_MAPPED_SUBRESOURCE.
  TD3D11_MAPPED_SUBRESOURCE = record
    pData:      Pointer;
    RowPitch:   UInt32;
    DepthPitch: UInt32;
  end;
  PD3D11_MAPPED_SUBRESOURCE = ^TD3D11_MAPPED_SUBRESOURCE;


  // shared/dxgi.h (line 321): IDXGIObject.
  IDXGIObject = interface(IInterface)
    ['{AEC22FB8-76F3-4639-9BE0-28EB43A67A2E}']
    function SetPrivateData(const Name: TGUID; DataSize: UInt32; pData: Pointer): HRESULT; stdcall;
    function SetPrivateDataInterface(const Name: TGUID; pUnknown: IInterface): HRESULT; stdcall;
    function GetPrivateData(const Name: TGUID; var pDataSize: UInt32; pData: Pointer): HRESULT; stdcall;
    function GetParent(const riid: TGUID; out ppParent): HRESULT; stdcall;
  end;

  // shared/dxgi.h (line 468): IDXGIDeviceSubObject.
  IDXGIDeviceSubObject = interface(IDXGIObject)
    ['{3D3E0379-F9DE-4D58-BB6C-18D62992F1A6}']
    function GetDevice(const riid: TGUID; out ppDevice): HRESULT; stdcall;
  end;

  // shared/dxgi.h (line 606): IDXGIResource. Only QI'd-into; vtable slots
  // beyond the first three (which come from IDXGIDeviceSubObject) are not
  // called, but listed for correctness.
  IDXGIResource = interface(IDXGIDeviceSubObject)
    ['{035F3AB4-482E-4E50-B41F-8A7F8BD8960B}']
    function GetSharedHandle(out pSharedHandle: THandle): HRESULT; stdcall;
    function GetUsage(out pUsage: UInt32): HRESULT; stdcall;
    function SetEvictionPriority(EvictionPriority: UInt32): HRESULT; stdcall;
    function GetEvictionPriority(out pEvictionPriority: UInt32): HRESULT; stdcall;
  end;

  // shared/dxgi.h (line 2313): IDXGIDevice.
  IDXGIDevice = interface(IDXGIObject)
    ['{54EC77FA-1377-44E6-8C32-88FD5F44C84C}']
    function GetAdapter(out pAdapter: IDXGIAdapter): HRESULT; stdcall;
    function CreateSurface(pDesc: Pointer; NumSurfaces: UInt32; Usage: UInt32;
                           pSharedResource: Pointer; out ppSurface): HRESULT; stdcall;
    function QueryResourceResidency(ppResources: Pointer; pResidencyStatus: Pointer;
                                    NumResources: UInt32): HRESULT; stdcall;
    function SetGPUThreadPriority(Priority: Int32): HRESULT; stdcall;
    function GetGPUThreadPriority(out pPriority: Int32): HRESULT; stdcall;
  end;

  // shared/dxgi.h (line 1325): IDXGIAdapter.
  IDXGIAdapter = interface(IDXGIObject)
    ['{2411E7E1-12AC-4CCF-BD14-9798E8534DC0}']
    function EnumOutputs(Output: UInt32; out ppOutput: IDXGIOutput): HRESULT; stdcall;
    function GetDesc(out pDesc): HRESULT; stdcall;
    function CheckInterfaceSupport(const InterfaceName: TGUID; out pUMDVersion: Int64): HRESULT; stdcall;
  end;

  // shared/dxgi.h (line 2750): IDXGIAdapter1.
  IDXGIAdapter1 = interface(IDXGIAdapter)
    ['{29038F61-3839-4626-91FD-086879011A05}']
    function GetDesc1(out pDesc: TDXGI_ADAPTER_DESC1): HRESULT; stdcall;
  end;

  // shared/dxgi.h (line 1503): IDXGIOutput. Full vtable retained so slot
  // indices match d3d11.h.
  IDXGIOutput = interface(IDXGIObject)
    ['{AE02EEDB-C735-4690-8D52-5A8DC20213AA}']
    // 0: GetDesc
    function GetDesc(out pDesc: TDXGI_OUTPUT_DESC): HRESULT; stdcall;
    // 1: GetDisplayModeList
    function GetDisplayModeList(EnumFormat: UInt32; Flags: UInt32;
                                var pNumModes: UInt32; pDesc: PDXGI_MODE_DESC): HRESULT; stdcall;
    // 2: FindClosestMatchingMode
    function FindClosestMatchingMode(const pModeToMatch: TDXGI_MODE_DESC;
                                     out pClosestMatch: TDXGI_MODE_DESC;
                                     pConcernedDevice: IInterface): HRESULT; stdcall;
    // 3: WaitForVBlank
    function WaitForVBlank(): HRESULT; stdcall;
    // 4: TakeOwnership
    function TakeOwnership(pDevice: IInterface; Exclusive: LongBool): HRESULT; stdcall;
    // 5: ReleaseOwnership (void return)
    procedure ReleaseOwnership(); stdcall;
    // 6: GetGammaControlCapabilities
    function GetGammaControlCapabilities(pGammaCaps: Pointer): HRESULT; stdcall;
    // 7: SetGammaControl
    function SetGammaControl(pArray: Pointer): HRESULT; stdcall;
    // 8: GetGammaControl
    function GetGammaControl(pArray: Pointer): HRESULT; stdcall;
    // 9: SetDisplaySurface
    function SetDisplaySurface(pScanoutSurface: IInterface): HRESULT; stdcall;
    // 10: GetDisplaySurfaceData
    function GetDisplaySurfaceData(pDestination: IInterface): HRESULT; stdcall;
    // 11: GetFrameStatistics
    function GetFrameStatistics(pStats: Pointer): HRESULT; stdcall;
  end;

  // shared/dxgi1_2.h (line 2312): IDXGIOutput1. Only DuplicateOutput is
  // called; preceding slots are present to keep the vtable aligned.
  IDXGIOutput1 = interface(IDXGIOutput)
    ['{00CDDEA8-939B-4B83-A340-A685226666CC}']
    // 0 (relative to IDXGIOutput1): GetDisplayModeList1
    function GetDisplayModeList1(EnumFormat: UInt32; Flags: UInt32;
                                 var pNumModes: UInt32; pDesc: Pointer): HRESULT; stdcall;
    // 1: FindClosestMatchingMode1
    function FindClosestMatchingMode1(pModeToMatch: Pointer; pClosestMatch: Pointer;
                                      pConcernedDevice: IInterface): HRESULT; stdcall;
    // 2: GetDisplaySurfaceData1
    function GetDisplaySurfaceData1(pDestination: IInterface): HRESULT; stdcall;
    // 3: DuplicateOutput. The IUnknown is the D3D11 device.
    function DuplicateOutput(pDevice: IInterface;
                             out ppOutputDuplication: IDXGIOutputDuplication): HRESULT; stdcall;
  end;

  // shared/dxgi1_2.h (line 292): IDXGIOutputDuplication.
  IDXGIOutputDuplication = interface(IDXGIObject)
    ['{191CFAC3-A341-470D-B26E-A864F428319C}']
    // 0: GetDesc (void return)
    procedure GetDesc(out pDesc: TDXGI_OUTDUPL_DESC); stdcall;
    // 1: AcquireNextFrame
    function AcquireNextFrame(TimeoutInMilliseconds: UInt32;
                              out pFrameInfo: TDXGI_OUTDUPL_FRAME_INFO;
                              out ppDesktopResource: IDXGIResource): HRESULT; stdcall;
    // 2: GetFrameDirtyRects
    function GetFrameDirtyRects(DirtyRectsBufferSize: UInt32; pDirtyRectsBuffer: PRect;
                                out pDirtyRectsBufferSizeRequired: UInt32): HRESULT; stdcall;
    // 3: GetFrameMoveRects
    function GetFrameMoveRects(MoveRectsBufferSize: UInt32; pMoveRectBuffer: Pointer;
                               out pMoveRectsBufferSizeRequired: UInt32): HRESULT; stdcall;
    // 4: GetFramePointerShape
    function GetFramePointerShape(PointerShapeBufferSize: UInt32; pPointerShapeBuffer: Pointer;
                                  out pPointerShapeBufferSizeRequired: UInt32;
                                  pPointerShapeInfo: Pointer): HRESULT; stdcall;
    // 5: MapDesktopSurface
    function MapDesktopSurface(pLockedRect: Pointer): HRESULT; stdcall;
    // 6: UnMapDesktopSurface
    function UnMapDesktopSurface(): HRESULT; stdcall;
    // 7: ReleaseFrame
    function ReleaseFrame(): HRESULT; stdcall;
  end;

  // shared/dxgi.h (line 2101): IDXGIFactory. EnumAdapters etc. not used --
  // we use IDXGIFactory1.EnumAdapters1 -- but the vtable is here for the
  // descendant's slot alignment.
  IDXGIFactory = interface(IDXGIObject)
    ['{7B7166EC-21C7-44AE-B21A-C9AE321AE369}']
    function EnumAdapters(Adapter: UInt32; out ppAdapter: IDXGIAdapter): HRESULT; stdcall;
    function MakeWindowAssociation(WindowHandle: HWND; Flags: UInt32): HRESULT; stdcall;
    function GetWindowAssociation(out pWindowHandle: HWND): HRESULT; stdcall;
    function CreateSwapChain(pDevice: IInterface; pDesc: Pointer;
                             out ppSwapChain): HRESULT; stdcall;
    function CreateSoftwareAdapter(Module: HMODULE; out ppAdapter: IDXGIAdapter): HRESULT; stdcall;
  end;

  // shared/dxgi.h (line 2553): IDXGIFactory1.
  IDXGIFactory1 = interface(IDXGIFactory)
    ['{770AAE78-F26F-4DBA-A829-253C83D1B387}']
    function EnumAdapters1(Adapter: UInt32; out ppAdapter: IDXGIAdapter1): HRESULT; stdcall;
    function IsCurrent(): LongBool; stdcall;
  end;

  // um/d3d11.h (line 1395): ID3D11DeviceChild.
  ID3D11DeviceChild = interface(IInterface)
    ['{1841E5C8-16B0-489B-BCC8-44CFB0D5DEAE}']
    procedure GetDevice(out ppDevice: ID3D11Device); stdcall;
    function GetPrivateData(const guid: TGUID; var pDataSize: UInt32; pData: Pointer): HRESULT; stdcall;
    function SetPrivateData(const guid: TGUID; DataSize: UInt32; pData: Pointer): HRESULT; stdcall;
    function SetPrivateDataInterface(const guid: TGUID; pData: IInterface): HRESULT; stdcall;
  end;

  // um/d3d11.h (line 2251): ID3D11Resource.
  ID3D11Resource = interface(ID3D11DeviceChild)
    ['{DC8E63F3-D12B-4952-B47B-5E45026A862D}']
    procedure GetType(out pResourceDimension: UInt32); stdcall;
    procedure SetEvictionPriority(EvictionPriority: UInt32); stdcall;
    function GetEvictionPriority(): UInt32; stdcall;
  end;

  // um/d3d11.h (line 2879): ID3D11Texture2D.
  ID3D11Texture2D = interface(ID3D11Resource)
    ['{6F15AAF2-D208-4E89-9AB4-489535D34F9C}']
    procedure GetDesc(out pDesc: TD3D11_TEXTURE2D_DESC); stdcall;
  end;

  // um/d3d11.h (line 14143): ID3D11Device. Only CreateTexture2D and
  // GetImmediateContext are used; the full vtable is preserved so slot
  // indices match the SDK.
  ID3D11Device = interface(IInterface)
    ['{DB6F6DDB-AC77-4E88-8253-819DF9BBF140}']
    // 0: CreateBuffer
    function CreateBuffer(pDesc: Pointer; pInitialData: Pointer; out ppBuffer: IInterface): HRESULT; stdcall;
    // 1: CreateTexture1D
    function CreateTexture1D(pDesc: Pointer; pInitialData: Pointer; out ppTexture1D: IInterface): HRESULT; stdcall;
    // 2: CreateTexture2D
    function CreateTexture2D(const pDesc: TD3D11_TEXTURE2D_DESC; pInitialData: Pointer;
                             out ppTexture2D: ID3D11Texture2D): HRESULT; stdcall;
    // 3: CreateTexture3D
    function CreateTexture3D(pDesc: Pointer; pInitialData: Pointer; out ppTexture3D: IInterface): HRESULT; stdcall;
    // 4: CreateShaderResourceView
    function CreateShaderResourceView(pResource: ID3D11Resource; pDesc: Pointer; out ppSRView: IInterface): HRESULT; stdcall;
    // 5: CreateUnorderedAccessView
    function CreateUnorderedAccessView(pResource: ID3D11Resource; pDesc: Pointer; out ppUAView: IInterface): HRESULT; stdcall;
    // 6: CreateRenderTargetView
    function CreateRenderTargetView(pResource: ID3D11Resource; pDesc: Pointer; out ppRTView: IInterface): HRESULT; stdcall;
    // 7: CreateDepthStencilView
    function CreateDepthStencilView(pResource: ID3D11Resource; pDesc: Pointer; out ppDepthStencilView: IInterface): HRESULT; stdcall;
    // 8: CreateInputLayout
    function CreateInputLayout(pInputElementDescs: Pointer; NumElements: UInt32;
                               pShaderBytecodeWithInputSignature: Pointer; BytecodeLength: PtrUInt;
                               out ppInputLayout: IInterface): HRESULT; stdcall;
    // 9: CreateVertexShader
    function CreateVertexShader(pShaderBytecode: Pointer; BytecodeLength: PtrUInt;
                                pClassLinkage: IInterface; out ppVertexShader: IInterface): HRESULT; stdcall;
    // 10: CreateGeometryShader
    function CreateGeometryShader(pShaderBytecode: Pointer; BytecodeLength: PtrUInt;
                                  pClassLinkage: IInterface; out ppGeometryShader: IInterface): HRESULT; stdcall;
    // 11: CreateGeometryShaderWithStreamOutput
    function CreateGeometryShaderWithStreamOutput(pShaderBytecode: Pointer; BytecodeLength: PtrUInt;
                                                  pSODeclaration: Pointer; NumEntries: UInt32;
                                                  pBufferStrides: Pointer; NumStrides: UInt32;
                                                  RasterizedStream: UInt32; pClassLinkage: IInterface;
                                                  out ppGeometryShader: IInterface): HRESULT; stdcall;
    // 12: CreatePixelShader
    function CreatePixelShader(pShaderBytecode: Pointer; BytecodeLength: PtrUInt;
                               pClassLinkage: IInterface; out ppPixelShader: IInterface): HRESULT; stdcall;
    // 13: CreateHullShader
    function CreateHullShader(pShaderBytecode: Pointer; BytecodeLength: PtrUInt;
                              pClassLinkage: IInterface; out ppHullShader: IInterface): HRESULT; stdcall;
    // 14: CreateDomainShader
    function CreateDomainShader(pShaderBytecode: Pointer; BytecodeLength: PtrUInt;
                                pClassLinkage: IInterface; out ppDomainShader: IInterface): HRESULT; stdcall;
    // 15: CreateComputeShader
    function CreateComputeShader(pShaderBytecode: Pointer; BytecodeLength: PtrUInt;
                                 pClassLinkage: IInterface; out ppComputeShader: IInterface): HRESULT; stdcall;
    // 16: CreateClassLinkage
    function CreateClassLinkage(out ppLinkage: IInterface): HRESULT; stdcall;
    // 17: CreateBlendState
    function CreateBlendState(pBlendStateDesc: Pointer; out ppBlendState: IInterface): HRESULT; stdcall;
    // 18: CreateDepthStencilState
    function CreateDepthStencilState(pDepthStencilDesc: Pointer; out ppDepthStencilState: IInterface): HRESULT; stdcall;
    // 19: CreateRasterizerState
    function CreateRasterizerState(pRasterizerDesc: Pointer; out ppRasterizerState: IInterface): HRESULT; stdcall;
    // 20: CreateSamplerState
    function CreateSamplerState(pSamplerDesc: Pointer; out ppSamplerState: IInterface): HRESULT; stdcall;
    // 21: CreateQuery
    function CreateQuery(pQueryDesc: Pointer; out ppQuery: IInterface): HRESULT; stdcall;
    // 22: CreatePredicate
    function CreatePredicate(pPredicateDesc: Pointer; out ppPredicate: IInterface): HRESULT; stdcall;
    // 23: CreateCounter
    function CreateCounter(pCounterDesc: Pointer; out ppCounter: IInterface): HRESULT; stdcall;
    // 24: CreateDeferredContext
    function CreateDeferredContext(ContextFlags: UInt32; out ppDeferredContext: ID3D11DeviceContext): HRESULT; stdcall;
    // 25: OpenSharedResource
    function OpenSharedResource(hResource: THandle; const ReturnedInterface: TGUID; out ppResource): HRESULT; stdcall;
    // 26: CheckFormatSupport
    function CheckFormatSupport(Format: UInt32; out pFormatSupport: UInt32): HRESULT; stdcall;
    // 27: CheckMultisampleQualityLevels
    function CheckMultisampleQualityLevels(Format: UInt32; SampleCount: UInt32; out pNumQualityLevels: UInt32): HRESULT; stdcall;
    // 28: CheckCounterInfo (void return)
    procedure CheckCounterInfo(out pCounterInfo); stdcall;
    // 29: CheckCounter
    function CheckCounter(pDesc: Pointer; out pType: UInt32; out pActiveCounters: UInt32;
                          szName: PAnsiChar; var pNameLength: UInt32;
                          szUnits: PAnsiChar; var pUnitsLength: UInt32;
                          szDescription: PAnsiChar; var pDescriptionLength: UInt32): HRESULT; stdcall;
    // 30: CheckFeatureSupport
    function CheckFeatureSupport(Feature: UInt32; pFeatureSupportData: Pointer; FeatureSupportDataSize: UInt32): HRESULT; stdcall;
    // 31: GetPrivateData
    function GetPrivateData(const guid: TGUID; var pDataSize: UInt32; pData: Pointer): HRESULT; stdcall;
    // 32: SetPrivateData
    function SetPrivateData(const guid: TGUID; DataSize: UInt32; pData: Pointer): HRESULT; stdcall;
    // 33: SetPrivateDataInterface
    function SetPrivateDataInterface(const guid: TGUID; pData: IInterface): HRESULT; stdcall;
    // 34: GetFeatureLevel
    function GetFeatureLevel(): UInt32; stdcall;
    // 35: GetCreationFlags
    function GetCreationFlags(): UInt32; stdcall;
    // 36: GetDeviceRemovedReason
    function GetDeviceRemovedReason(): HRESULT; stdcall;
    // 37: GetImmediateContext (void return)
    procedure GetImmediateContext(out ppImmediateContext: ID3D11DeviceContext); stdcall;
    // 38: SetExceptionMode
    function SetExceptionMode(RaiseFlags: UInt32): HRESULT; stdcall;
    // 39: GetExceptionMode
    function GetExceptionMode(): UInt32; stdcall;
  end;

  // um/d3d11.h (line 7763): ID3D11DeviceContext. Only Map / Unmap /
  // CopyResource / CopySubresourceRegion are called; full vtable
  // preserved for slot alignment.
  ID3D11DeviceContext = interface(ID3D11DeviceChild)
    ['{C0BFA96C-E089-44FB-8EAF-26F8796190DA}']
    procedure VSSetConstantBuffers(StartSlot: UInt32; NumBuffers: UInt32; ppConstantBuffers: Pointer); stdcall;
    procedure PSSetShaderResources(StartSlot: UInt32; NumViews: UInt32; ppShaderResourceViews: Pointer); stdcall;
    procedure PSSetShader(pPixelShader: IInterface; ppClassInstances: Pointer; NumClassInstances: UInt32); stdcall;
    procedure PSSetSamplers(StartSlot: UInt32; NumSamplers: UInt32; ppSamplers: Pointer); stdcall;
    procedure VSSetShader(pVertexShader: IInterface; ppClassInstances: Pointer; NumClassInstances: UInt32); stdcall;
    procedure DrawIndexed(IndexCount: UInt32; StartIndexLocation: UInt32; BaseVertexLocation: Int32); stdcall;
    procedure Draw(VertexCount: UInt32; StartVertexLocation: UInt32); stdcall;
    function Map(pResource: ID3D11Resource; Subresource: UInt32; MapType: UInt32;
                 MapFlags: UInt32; out pMappedResource: TD3D11_MAPPED_SUBRESOURCE): HRESULT; stdcall;
    procedure Unmap(pResource: ID3D11Resource; Subresource: UInt32); stdcall;
    procedure PSSetConstantBuffers(StartSlot: UInt32; NumBuffers: UInt32; ppConstantBuffers: Pointer); stdcall;
    procedure IASetInputLayout(pInputLayout: IInterface); stdcall;
    procedure IASetVertexBuffers(StartSlot: UInt32; NumBuffers: UInt32; ppVertexBuffers: Pointer;
                                 pStrides: Pointer; pOffsets: Pointer); stdcall;
    procedure IASetIndexBuffer(pIndexBuffer: IInterface; Format: UInt32; Offset: UInt32); stdcall;
    procedure DrawIndexedInstanced(IndexCountPerInstance: UInt32; InstanceCount: UInt32;
                                   StartIndexLocation: UInt32; BaseVertexLocation: Int32;
                                   StartInstanceLocation: UInt32); stdcall;
    procedure DrawInstanced(VertexCountPerInstance: UInt32; InstanceCount: UInt32;
                            StartVertexLocation: UInt32; StartInstanceLocation: UInt32); stdcall;
    procedure GSSetConstantBuffers(StartSlot: UInt32; NumBuffers: UInt32; ppConstantBuffers: Pointer); stdcall;
    procedure GSSetShader(pShader: IInterface; ppClassInstances: Pointer; NumClassInstances: UInt32); stdcall;
    procedure IASetPrimitiveTopology(Topology: UInt32); stdcall;
    procedure VSSetShaderResources(StartSlot: UInt32; NumViews: UInt32; ppShaderResourceViews: Pointer); stdcall;
    procedure VSSetSamplers(StartSlot: UInt32; NumSamplers: UInt32; ppSamplers: Pointer); stdcall;
    procedure Begin_(pAsync: IInterface); stdcall;                      // d3d11.h: `Begin` (Pascal keyword)
    procedure End_(pAsync: IInterface); stdcall;                        // d3d11.h: `End` (Pascal keyword)
    function  GetData(pAsync: IInterface; pData: Pointer;
                      DataSize: UInt32; GetDataFlags: UInt32): HRESULT; stdcall;
    procedure SetPredication(pPredicate: IInterface; PredicateValue: LongBool); stdcall;
    procedure GSSetShaderResources(StartSlot: UInt32; NumViews: UInt32; ppShaderResourceViews: Pointer); stdcall;
    procedure GSSetSamplers(StartSlot: UInt32; NumSamplers: UInt32; ppSamplers: Pointer); stdcall;
    procedure OMSetRenderTargets(NumViews: UInt32; ppRenderTargetViews: Pointer; pDepthStencilView: IInterface); stdcall;
    procedure OMSetRenderTargetsAndUnorderedAccessViews(NumRTVs: UInt32; ppRenderTargetViews: Pointer;
                                                        pDepthStencilView: IInterface;
                                                        UAVStartSlot: UInt32; NumUAVs: UInt32;
                                                        ppUnorderedAccessViews: Pointer;
                                                        pUAVInitialCounts: Pointer); stdcall;
    procedure OMSetBlendState(pBlendState: IInterface; pBlendFactor: PSingle;
                              SampleMask: UInt32); stdcall;
    procedure OMSetDepthStencilState(pDepthStencilState: IInterface; StencilRef: UInt32); stdcall;
    procedure SOSetTargets(NumBuffers: UInt32; ppSOTargets: Pointer; pOffsets: Pointer); stdcall;
    procedure DrawAuto(); stdcall;
    procedure DrawIndexedInstancedIndirect(pBufferForArgs: IInterface; AlignedByteOffsetForArgs: UInt32); stdcall;
    procedure DrawInstancedIndirect(pBufferForArgs: IInterface; AlignedByteOffsetForArgs: UInt32); stdcall;
    procedure Dispatch(ThreadGroupCountX: UInt32; ThreadGroupCountY: UInt32; ThreadGroupCountZ: UInt32); stdcall;
    procedure DispatchIndirect(pBufferForArgs: IInterface; AlignedByteOffsetForArgs: UInt32); stdcall;
    procedure RSSetState(pRasterizerState: IInterface); stdcall;
    procedure RSSetViewports(NumViewports: UInt32; pViewports: Pointer); stdcall;
    procedure RSSetScissorRects(NumRects: UInt32; pRects: Pointer); stdcall;
    procedure CopySubresourceRegion(pDstResource: ID3D11Resource; DstSubresource: UInt32;
                                    DstX: UInt32; DstY: UInt32; DstZ: UInt32;
                                    pSrcResource: ID3D11Resource; SrcSubresource: UInt32;
                                    pSrcBox: Pointer); stdcall;
    procedure CopyResource(pDstResource: ID3D11Resource; pSrcResource: ID3D11Resource); stdcall;
    procedure UpdateSubresource(pDstResource: ID3D11Resource; DstSubresource: UInt32;
                                pDstBox: Pointer; pSrcData: Pointer;
                                SrcRowPitch: UInt32; SrcDepthPitch: UInt32); stdcall;
    procedure CopyStructureCount(pDstBuffer: IInterface; DstAlignedByteOffset: UInt32;
                                 pSrcView: IInterface); stdcall;
    procedure ClearRenderTargetView(pRenderTargetView: IInterface; pColorRGBA: PSingle); stdcall;
    procedure ClearUnorderedAccessViewUint(pUnorderedAccessView: IInterface; pValues: PUInt32); stdcall;
    procedure ClearUnorderedAccessViewFloat(pUnorderedAccessView: IInterface; pValues: PSingle); stdcall;
    procedure ClearDepthStencilView(pDepthStencilView: IInterface; ClearFlags: UInt32;
                                    Depth: Single; Stencil: Byte); stdcall;
    procedure GenerateMips(pShaderResourceView: IInterface); stdcall;
    procedure SetResourceMinLOD(pResource: ID3D11Resource; MinLOD: Single); stdcall;
    function  GetResourceMinLOD(pResource: ID3D11Resource): Single; stdcall;
    procedure ResolveSubresource(pDstResource: ID3D11Resource; DstSubresource: UInt32;
                                 pSrcResource: ID3D11Resource; SrcSubresource: UInt32;
                                 Format: UInt32); stdcall;
    procedure ExecuteCommandList(pCommandList: IInterface; RestoreContextState: LongBool); stdcall;
    procedure HSSetShaderResources(StartSlot: UInt32; NumViews: UInt32; ppShaderResourceViews: Pointer); stdcall;
    procedure HSSetShader(pHullShader: IInterface; ppClassInstances: Pointer; NumClassInstances: UInt32); stdcall;
    procedure HSSetSamplers(StartSlot: UInt32; NumSamplers: UInt32; ppSamplers: Pointer); stdcall;
    procedure HSSetConstantBuffers(StartSlot: UInt32; NumBuffers: UInt32; ppConstantBuffers: Pointer); stdcall;
    procedure DSSetShaderResources(StartSlot: UInt32; NumViews: UInt32; ppShaderResourceViews: Pointer); stdcall;
    procedure DSSetShader(pDomainShader: IInterface; ppClassInstances: Pointer; NumClassInstances: UInt32); stdcall;
    procedure DSSetSamplers(StartSlot: UInt32; NumSamplers: UInt32; ppSamplers: Pointer); stdcall;
    procedure DSSetConstantBuffers(StartSlot: UInt32; NumBuffers: UInt32; ppConstantBuffers: Pointer); stdcall;
    procedure CSSetShaderResources(StartSlot: UInt32; NumViews: UInt32; ppShaderResourceViews: Pointer); stdcall;
    procedure CSSetUnorderedAccessViews(StartSlot: UInt32; NumUAVs: UInt32; ppUnorderedAccessViews: Pointer;
                                        pUAVInitialCounts: Pointer); stdcall;
    procedure CSSetShader(pComputeShader: IInterface; ppClassInstances: Pointer; NumClassInstances: UInt32); stdcall;
    procedure CSSetSamplers(StartSlot: UInt32; NumSamplers: UInt32; ppSamplers: Pointer); stdcall;
    procedure CSSetConstantBuffers(StartSlot: UInt32; NumBuffers: UInt32; ppConstantBuffers: Pointer); stdcall;
    procedure VSGetConstantBuffers(StartSlot: UInt32; NumBuffers: UInt32; ppConstantBuffers: Pointer); stdcall;
    procedure PSGetShaderResources(StartSlot: UInt32; NumViews: UInt32; ppShaderResourceViews: Pointer); stdcall;
    procedure PSGetShader(out ppPixelShader: IInterface; ppClassInstances: Pointer; var pNumClassInstances: UInt32); stdcall;
    procedure PSGetSamplers(StartSlot: UInt32; NumSamplers: UInt32; ppSamplers: Pointer); stdcall;
    procedure VSGetShader(out ppVertexShader: IInterface; ppClassInstances: Pointer; var pNumClassInstances: UInt32); stdcall;
    procedure PSGetConstantBuffers(StartSlot: UInt32; NumBuffers: UInt32; ppConstantBuffers: Pointer); stdcall;
    procedure IAGetInputLayout(out ppInputLayout: IInterface); stdcall;
    procedure IAGetVertexBuffers(StartSlot: UInt32; NumBuffers: UInt32; ppVertexBuffers: Pointer;
                                 pStrides: Pointer; pOffsets: Pointer); stdcall;
    procedure IAGetIndexBuffer(out pIndexBuffer: IInterface; out Format: UInt32; out Offset: UInt32); stdcall;
    procedure GSGetConstantBuffers(StartSlot: UInt32; NumBuffers: UInt32; ppConstantBuffers: Pointer); stdcall;
    procedure GSGetShader(out ppGeometryShader: IInterface; ppClassInstances: Pointer; var pNumClassInstances: UInt32); stdcall;
    procedure IAGetPrimitiveTopology(out pTopology: UInt32); stdcall;
    procedure VSGetShaderResources(StartSlot: UInt32; NumViews: UInt32; ppShaderResourceViews: Pointer); stdcall;
    procedure VSGetSamplers(StartSlot: UInt32; NumSamplers: UInt32; ppSamplers: Pointer); stdcall;
    procedure GetPredication(out ppPredicate: IInterface; out pPredicateValue: LongBool); stdcall;
    procedure GSGetShaderResources(StartSlot: UInt32; NumViews: UInt32; ppShaderResourceViews: Pointer); stdcall;
    procedure GSGetSamplers(StartSlot: UInt32; NumSamplers: UInt32; ppSamplers: Pointer); stdcall;
    procedure OMGetRenderTargets(NumViews: UInt32; ppRenderTargetViews: Pointer; out ppDepthStencilView: IInterface); stdcall;
    procedure OMGetRenderTargetsAndUnorderedAccessViews(NumRTVs: UInt32; ppRenderTargetViews: Pointer;
                                                       out ppDepthStencilView: IInterface;
                                                       UAVStartSlot: UInt32; NumUAVs: UInt32;
                                                       ppUnorderedAccessViews: Pointer); stdcall;
    procedure OMGetBlendState(out ppBlendState: IInterface; pBlendFactor: Pointer; out pSampleMask: UInt32); stdcall;
    procedure OMGetDepthStencilState(out ppDepthStencilState: IInterface; out pStencilRef: UInt32); stdcall;
    procedure SOGetTargets(NumBuffers: UInt32; ppSOTargets: Pointer); stdcall;
    procedure RSGetState(out ppRasterizerState: IInterface); stdcall;
    procedure RSGetViewports(var pNumViewports: UInt32; pViewports: Pointer); stdcall;
    procedure RSGetScissorRects(var pNumRects: UInt32; pRects: Pointer); stdcall;
    procedure HSGetShaderResources(StartSlot: UInt32; NumViews: UInt32; ppShaderResourceViews: Pointer); stdcall;
    procedure HSGetShader(out ppHullShader: IInterface; ppClassInstances: Pointer; var pNumClassInstances: UInt32); stdcall;
    procedure HSGetSamplers(StartSlot: UInt32; NumSamplers: UInt32; ppSamplers: Pointer); stdcall;
    procedure HSGetConstantBuffers(StartSlot: UInt32; NumBuffers: UInt32; ppConstantBuffers: Pointer); stdcall;
    procedure DSGetShaderResources(StartSlot: UInt32; NumViews: UInt32; ppShaderResourceViews: Pointer); stdcall;
    procedure DSGetShader(out ppDomainShader: IInterface; ppClassInstances: Pointer; var pNumClassInstances: UInt32); stdcall;
    procedure DSGetSamplers(StartSlot: UInt32; NumSamplers: UInt32; ppSamplers: Pointer); stdcall;
    procedure DSGetConstantBuffers(StartSlot: UInt32; NumBuffers: UInt32; ppConstantBuffers: Pointer); stdcall;
    procedure CSGetShaderResources(StartSlot: UInt32; NumViews: UInt32; ppShaderResourceViews: Pointer); stdcall;
    procedure CSGetUnorderedAccessViews(StartSlot: UInt32; NumUAVs: UInt32; ppUnorderedAccessViews: Pointer); stdcall;
    procedure CSGetShader(out ppComputeShader: IInterface; ppClassInstances: Pointer; var pNumClassInstances: UInt32); stdcall;
    procedure CSGetSamplers(StartSlot: UInt32; NumSamplers: UInt32; ppSamplers: Pointer); stdcall;
    procedure CSGetConstantBuffers(StartSlot: UInt32; NumBuffers: UInt32; ppConstantBuffers: Pointer); stdcall;
    procedure ClearState(); stdcall;
    procedure Flush(); stdcall;
    function  GetType_(): UInt32; stdcall;
    function  GetContextFlags(): UInt32; stdcall;
    function  FinishCommandList(RestoreDeferredContextState: LongBool;
                                out ppCommandList: IInterface): HRESULT; stdcall;
  end;

function D3D11CreateDevice(pAdapter: Pointer; DriverType: UInt32; Software: HMODULE;
  Flags: UInt32; pFeatureLevels: Pointer; FeatureLevels: UInt32; SDKVersion: UInt32;
  out ppDevice: ID3D11Device; out pFeatureLevel: UInt32;
  out ppImmediateContext: ID3D11DeviceContext): HRESULT; stdcall;
  external 'd3d11.dll' name 'D3D11CreateDevice';

function CreateDXGIFactory1(const riid: TGUID; out ppFactory): HRESULT; stdcall;
  external 'dxgi.dll' name 'CreateDXGIFactory1';

// MonitorFromWindow / MONITOR_DEFAULTTONEAREST are in user32.dll on
// every supported Windows build (Win2000+). FPC's `windows` unit
// publishes the constant on some platforms only and the function via
// the dynamic multimon helper; we declare both verbatim to avoid the
// version-skew.
const
  MONITOR_DEFAULTTONEAREST = $00000002;

function MonitorFromWindow(hWnd: HWND; dwFlags: DWORD): HMONITOR; stdcall;
  external 'user32.dll' name 'MonitorFromWindow';


// Lock ordering: GCaptureLock (outer, structural) -> GFrameBufferLock
// (inner, memcpy + cached-frame state). NEVER acquire the outer while
// holding the inner. The consumer read path (DXGITryGetImageInto) takes
// the outer because it may need to switch monitors or recreate the
// duplication; the cached-frame serve takes the inner only.

var
  GCaptureLock: TCriticalSection = nil;
  GFrameBufferLock: TCriticalSection = nil;

  // Singletons reused across sessions (lazy-created on first AutoOpen).
  GD3DDevice:    ID3D11Device         = nil;
  GD3DContext:   ID3D11DeviceContext  = nil;
  GDXGIFactory:  IDXGIFactory1        = nil;

  // Per-session: target window + the duplication currently active for
  // its monitor.
  GUserWindow:    TWindowHandle           = 0;
  GActiveOutput:  IDXGIOutput1            = nil;
  GActiveDup:     IDXGIOutputDuplication  = nil;
  GActiveMonitor: HMONITOR                = 0;
  // DesktopCoordinates of GActiveMonitor in virtual-screen space.
  GMonitorRect:   TRect;
  // Staging texture sized to the active monitor's resolution.
  GStagingTexture: ID3D11Texture2D = nil;
  GStagingWidth:   UInt32 = 0;
  GStagingHeight:  UInt32 = 0;

  // Cached frame buffer: the last full-monitor image we staged. Served
  // on AcquireNextFrame -> DXGI_ERROR_WAIT_TIMEOUT. Sized to the active
  // monitor's resolution; per-call crop happens at memcpy time.
  GFrameBufferWidth:  Int32 = 0;
  GFrameBufferHeight: Int32 = 0;
  GFrameBuffer: array of TColorBGRA;
  GHasFrame: Boolean = False;

  GDXGILastError: String = '';
  GFrameCount: Int64 = 0;


procedure DXGILogError(const Msg: String);
begin
  DebugLn(DEBUG_RED + '[DXGI] ' + Msg + DEBUG_RESET);
end;

function DXGIHRESULTToStr(HR: HRESULT): String;
var
  Buffer: PWideChar;
  Len: DWORD;
  W: UnicodeString;
  Ch: WideChar;
begin
  Buffer := nil;
  Len := FormatMessageW(
    FORMAT_MESSAGE_FROM_SYSTEM or
    FORMAT_MESSAGE_IGNORE_INSERTS or
    FORMAT_MESSAGE_ALLOCATE_BUFFER,
    nil,
    DWORD(HR),
    0,
    PWideChar(@Buffer),
    0,
    nil
  );

  if (Len > 0) and (Buffer <> nil) then
  begin
    try
      SetString(W, Buffer, Len);
      while Length(W) > 0 do
      begin
        Ch := W[Length(W)];
        if (Ch = #10) or (Ch = #13) or (Ch = ' ') or (Ch = #9) then
          SetLength(W, Length(W) - 1)
        else
          Break;
      end;
      Result := String(W);
    finally
      LocalFree(HLOCAL(Buffer));
    end;
    if Result <> '' then
      Exit;
  end
  else if Buffer <> nil then
    LocalFree(HLOCAL(Buffer));

  // DXGI's per-error-code names; FormatMessage doesn't always know them.
  case HR of
    DXGI_ERROR_WAIT_TIMEOUT:  Result := 'DXGI_ERROR_WAIT_TIMEOUT';
    DXGI_ERROR_ACCESS_LOST:   Result := 'DXGI_ERROR_ACCESS_LOST';
    DXGI_ERROR_NOT_FOUND:     Result := 'DXGI_ERROR_NOT_FOUND';
    DXGI_ERROR_INVALID_CALL:  Result := 'DXGI_ERROR_INVALID_CALL';
  else
    Result := '0x' + IntToHex(HR, 8);
  end;
end;

// Caller MUST hold GCaptureLock. Populates GDXGILastError on failure.
function EnsureD3D11Device(): Boolean;
var
  HR: HRESULT;
  FeatureLevel: UInt32;
begin
  if (GD3DDevice <> nil) and (GD3DContext <> nil) then
    Exit(True);

  // BGRA support is required so the staging texture and the DXGI desktop
  // surface share the same format (DXGI_FORMAT_B8G8R8A8_UNORM) -- avoids
  // a CPU-side swizzle on memcpy.
  HR := D3D11CreateDevice(
    nil,
    D3D_DRIVER_TYPE_HARDWARE,
    0,
    D3D11_CREATE_DEVICE_BGRA_SUPPORT,
    nil, 0,
    D3D11_SDK_VERSION,
    GD3DDevice, FeatureLevel, GD3DContext
  );
  if not Succeeded(HR) then
  begin
    GDXGILastError := 'D3D11CreateDevice failed: ' + DXGIHRESULTToStr(HR);
    GD3DDevice := nil;
    GD3DContext := nil;
    Exit(False);
  end;

  Result := True;
end;

// Caller MUST hold GCaptureLock.
function EnsureDXGIFactory(): Boolean;
var
  HR: HRESULT;
  Raw: IInterface;
begin
  if GDXGIFactory <> nil then
    Exit(True);

  HR := CreateDXGIFactory1(IID_IDXGIFactory1, Raw);
  if not Succeeded(HR) then
  begin
    GDXGILastError := 'CreateDXGIFactory1 failed: ' + DXGIHRESULTToStr(HR);
    Exit(False);
  end;

  if not Supports(Raw, IDXGIFactory1, GDXGIFactory) then
  begin
    GDXGILastError := 'QueryInterface(IDXGIFactory1) failed';
    Raw := nil;
    Exit(False);
  end;

  Result := True;
end;

// Caller MUST hold GCaptureLock. Walks every adapter / every output on
// the active DXGI factory and returns the IDXGIOutput1 whose desc.Monitor
// matches the given HMONITOR. The adapter the output is parented by must
// be the SAME adapter that backs our D3D11 device, otherwise
// IDXGIOutput1.DuplicateOutput will fail with E_INVALIDARG (the device
// must be created on the adapter that drives the output).
//
// In practice on systems where the D3D11 default-driver adapter == the
// adapter driving every monitor (i.e. single-GPU laptops/desktops, which
// covers >99% of Simba's users) this is a no-op lookup. The mismatch
// case is documented in TEST_MATRIX.md as "future work: detect and
// recreate D3D11 on the right adapter for hybrid laptops".
function FindOutputForMonitor(MonitorHandle: HMONITOR;
                              out OutputDesc: TDXGI_OUTPUT_DESC): IDXGIOutput1;
var
  HR: HRESULT;
  AdapterIdx, OutputIdx: UInt32;
  Adapter: IDXGIAdapter1;
  Output:  IDXGIOutput;
  Output1: IDXGIOutput1;
  Desc:    TDXGI_OUTPUT_DESC;
begin
  Result := nil;
  if GDXGIFactory = nil then Exit;

  AdapterIdx := 0;
  while True do
  begin
    Adapter := nil;
    HR := GDXGIFactory.EnumAdapters1(AdapterIdx, Adapter);
    if HR = DXGI_ERROR_NOT_FOUND then Break;
    if (not Succeeded(HR)) or (Adapter = nil) then Break;

    OutputIdx := 0;
    while True do
    begin
      Output := nil;
      HR := Adapter.EnumOutputs(OutputIdx, Output);
      if HR = DXGI_ERROR_NOT_FOUND then Break;
      if (not Succeeded(HR)) or (Output = nil) then Break;

      if Supports(Output, IDXGIOutput1, Output1) then
      begin
        if Succeeded(Output1.GetDesc(Desc)) and (Desc.Monitor = MonitorHandle) then
        begin
          OutputDesc := Desc;
          Result := Output1;
          Exit;
        end;
      end;
      Output1 := nil;
      Output := nil;
      Inc(OutputIdx);
    end;
    Adapter := nil;
    Inc(AdapterIdx);
  end;
end;

// Caller MUST hold GCaptureLock. Recreates the staging texture for the
// given dimensions if needed. Also resizes GFrameBuffer under
// GFrameBufferLock.
function EnsureStaging(Width, Height: UInt32): Boolean;
var
  Desc: TD3D11_TEXTURE2D_DESC;
  HR: HRESULT;
begin
  if (GStagingTexture <> nil) and (GStagingWidth = Width) and (GStagingHeight = Height) then
    Exit(True);

  GStagingTexture := nil;
  GStagingWidth := 0;
  GStagingHeight := 0;

  FillChar(Desc, SizeOf(Desc), 0);
  Desc.Width := Width;
  Desc.Height := Height;
  Desc.MipLevels := 1;
  Desc.ArraySize := 1;
  Desc.Format := DXGI_FORMAT_B8G8R8A8_UNORM;
  Desc.SampleDesc.Count := 1;
  Desc.Usage := D3D11_USAGE_STAGING;
  Desc.CPUAccessFlags := D3D11_CPU_ACCESS_READ;

  HR := GD3DDevice.CreateTexture2D(Desc, nil, GStagingTexture);
  if (not Succeeded(HR)) or (GStagingTexture = nil) then
  begin
    GDXGILastError := 'CreateTexture2D(staging) failed: ' + DXGIHRESULTToStr(HR);
    GStagingTexture := nil;
    Exit(False);
  end;
  GStagingWidth := Width;
  GStagingHeight := Height;

  GFrameBufferLock.Enter;
  try
    GFrameBufferWidth := Int32(Width);
    GFrameBufferHeight := Int32(Height);
    SetLength(GFrameBuffer, GFrameBufferWidth * GFrameBufferHeight);
    GHasFrame := False;
  finally
    GFrameBufferLock.Leave;
  end;

  Result := True;
end;

// Caller MUST hold GCaptureLock. Tears down the active duplication and
// associated per-monitor state. The D3D11 device and DXGI factory are
// preserved (singletons).
procedure TearDownDuplication();
begin
  if GActiveDup <> nil then
  begin
    // Best-effort ReleaseFrame in case the prior call left one held.
    GActiveDup.ReleaseFrame();
    GActiveDup := nil;
  end;
  GActiveOutput := nil;
  GActiveMonitor := 0;
  GMonitorRect := TRect.Empty;
  GStagingTexture := nil;
  GStagingWidth := 0;
  GStagingHeight := 0;

  GFrameBufferLock.Enter;
  try
    GFrameBufferWidth := 0;
    GFrameBufferHeight := 0;
    SetLength(GFrameBuffer, 0);
    GHasFrame := False;
  finally
    GFrameBufferLock.Leave;
  end;
end;

// Caller MUST hold GCaptureLock. Opens a fresh IDXGIOutputDuplication
// against the supplied monitor and stages a staging texture for its
// resolution. Returns False on failure (GDXGILastError is populated).
function OpenDuplicationForMonitor(MonitorHandle: HMONITOR): Boolean;
var
  Desc:       TDXGI_OUTPUT_DESC;
  Output1:    IDXGIOutput1;
  HR:         HRESULT;
  MonW, MonH: Int32;
begin
  Result := False;
  GDXGILastError := '';

  if MonitorHandle = 0 then
  begin
    GDXGILastError := 'OpenDuplicationForMonitor: null HMONITOR';
    Exit;
  end;

  Output1 := FindOutputForMonitor(MonitorHandle, Desc);
  if Output1 = nil then
  begin
    GDXGILastError := 'No IDXGIOutput1 found for HMONITOR ' + IntToHex(PtrUInt(MonitorHandle), 16) +
                      ' on the D3D11 device''s adapter (hybrid-GPU mismatch?)';
    Exit;
  end;

  HR := Output1.DuplicateOutput(GD3DDevice, GActiveDup);
  if (not Succeeded(HR)) or (GActiveDup = nil) then
  begin
    GDXGILastError := 'IDXGIOutput1.DuplicateOutput failed: ' + DXGIHRESULTToStr(HR);
    GActiveDup := nil;
    Exit;
  end;

  GActiveOutput  := Output1;
  GActiveMonitor := MonitorHandle;
  GMonitorRect   := Desc.DesktopCoordinates;

  MonW := GMonitorRect.Right  - GMonitorRect.Left;
  MonH := GMonitorRect.Bottom - GMonitorRect.Top;
  if (MonW <= 0) or (MonH <= 0) then
  begin
    GDXGILastError := 'Active monitor reports non-positive dimensions';
    TearDownDuplication();
    Exit;
  end;

  if not EnsureStaging(UInt32(MonW), UInt32(MonH)) then
  begin
    TearDownDuplication();
    Exit;
  end;

  Result := True;
end;

procedure DXGIAutoOpen(Window: TWindowHandle);
var
  MonitorHandle: HMONITOR;
  WantWindow: TWindowHandle;
begin
  WantWindow := Window;

  if GCaptureLock = nil then
    Exit;

  GCaptureLock.Enter;
  try
   try
    GDXGILastError := '';

    // Idempotent on same-window. The duplication is monitor-scoped and
    // we re-evaluate the window's monitor on every TryGetImage anyway,
    // so AutoOpen is mostly about (a) tearing down a prior window's
    // state and (b) priming the device/factory/staging path.
    if WantWindow = GUserWindow then
      Exit;

    // Tear down whatever was active for the previous window.
    if GActiveDup <> nil then
      TearDownDuplication();

    GUserWindow := WantWindow;

    if WantWindow = 0 then
      Exit;
    if not IsWindow(HWND(WantWindow)) then
    begin
      GDXGILastError := 'AutoOpen: HWND ' + IntToHex(PtrUInt(WantWindow), 16) + ' is not a window';
      DXGILogError(GDXGILastError);
      GUserWindow := 0;
      Exit;
    end;

    if not EnsureD3D11Device() then
    begin
      DXGILogError(GDXGILastError);
      GUserWindow := 0;
      Exit;
    end;
    if not EnsureDXGIFactory() then
    begin
      DXGILogError(GDXGILastError);
      GUserWindow := 0;
      Exit;
    end;

    // Resolve the window's current monitor and open the duplication.
    // MONITOR_DEFAULTTONEAREST tolerates a window that's currently
    // off-screen (e.g. an inactive secondary that the OS clamped).
    MonitorHandle := MonitorFromWindow(HWND(WantWindow), MONITOR_DEFAULTTONEAREST);
    if not OpenDuplicationForMonitor(MonitorHandle) then
    begin
      DXGILogError(GDXGILastError);
      // Keep GUserWindow set so a later TryGetImage may retry --
      // a fresh AcquireNextFrame can race past whatever transient
      // condition fouled the initial DuplicateOutput.
    end;
   except
     on E: Exception do
     begin
       GDXGILastError := 'Exception during DXGIAutoOpen: ' +
                         E.ClassName + ': ' + E.Message;
       DXGILogError(GDXGILastError);
       TearDownDuplication();
       GUserWindow := 0;
     end;
   end;
  finally
    GCaptureLock.Leave;
  end;
end;

// Caller MUST hold GCaptureLock. Drives a single AcquireNextFrame /
// CopyResource / Map / memcpy / Unmap / ReleaseFrame cycle. Updates
// GFrameBuffer + GHasFrame on success. Returns the HRESULT verbatim
// (S_OK, DXGI_ERROR_WAIT_TIMEOUT, DXGI_ERROR_ACCESS_LOST, etc.) so the
// caller can decide whether to re-acquire / serve cache / fail.
function PumpFrame(): HRESULT;
var
  FrameInfo: TDXGI_OUTDUPL_FRAME_INFO;
  DesktopResource: IDXGIResource;
  D3DTexture: ID3D11Texture2D;
  Mapped: TD3D11_MAPPED_SUBRESOURCE;
  HR: HRESULT;
  Row: Integer;
  RowBytes: PtrUInt;
begin
  if GActiveDup = nil then
    Exit(E_FAIL);

  FillChar(FrameInfo, SizeOf(FrameInfo), 0);
  DesktopResource := nil;
  HR := GActiveDup.AcquireNextFrame(0, FrameInfo, DesktopResource);
  Result := HR;
  if (HR = DXGI_ERROR_WAIT_TIMEOUT) or
     (HR = DXGI_ERROR_ACCESS_LOST) then
    Exit;
  if (not Succeeded(HR)) or (DesktopResource = nil) then
  begin
    if DesktopResource <> nil then
    begin
      DesktopResource := nil;
      GActiveDup.ReleaseFrame();
    end;
    Exit;
  end;

  try
    if not Supports(DesktopResource, ID3D11Texture2D, D3DTexture) then
    begin
      Result := E_FAIL;
      Exit;
    end;

    if (GStagingTexture = nil) or
       (GStagingWidth = 0) or (GStagingHeight = 0) then
    begin
      Result := E_FAIL;
      Exit;
    end;

    GD3DContext.CopyResource(GStagingTexture, D3DTexture);

    FillChar(Mapped, SizeOf(Mapped), 0);
    HR := GD3DContext.Map(GStagingTexture, 0, D3D11_MAP_READ, 0, Mapped);
    if (not Succeeded(HR)) or (Mapped.pData = nil) then
    begin
      Result := HR;
      Exit;
    end;

    try
      GFrameBufferLock.Enter;
      try
        RowBytes := PtrUInt(GFrameBufferWidth) * SizeOf(TColorBGRA);
        for Row := 0 to GFrameBufferHeight - 1 do
          Move(
            (PByte(Mapped.pData) + PtrUInt(Row) * PtrUInt(Mapped.RowPitch))^,
            GFrameBuffer[Row * GFrameBufferWidth],
            RowBytes
          );
        GHasFrame := True;
        InterlockedIncrement64(GFrameCount);
      finally
        GFrameBufferLock.Leave;
      end;
    finally
      GD3DContext.Unmap(GStagingTexture, 0);
    end;

    Result := S_OK;
  finally
    D3DTexture := nil;
    DesktopResource := nil;
    GActiveDup.ReleaseFrame();
  end;
end;

// Caller MUST hold GFrameBufferLock. Copies a sub-rect from GFrameBuffer
// into DstPtr. Returns False if the rect is out of bounds or no frame
// has been staged yet.
function CopyOutCrop(EffX, EffY, Width, Height: Integer;
                    DstPtr: PColorBGRA; DstStride: Integer): Boolean;
var
  Row: Integer;
  RowBytes: PtrUInt;
begin
  Result := False;
  if not GHasFrame then Exit;
  if (GFrameBufferWidth <= 0) or (GFrameBufferHeight <= 0) then Exit;
  if (EffX < 0) or (EffY < 0) or
     (EffX + Width > GFrameBufferWidth) or
     (EffY + Height > GFrameBufferHeight) then
    Exit;

  RowBytes := PtrUInt(Width) * SizeOf(TColorBGRA);
  for Row := 0 to Height - 1 do
    Move(
      GFrameBuffer[(EffY + Row) * GFrameBufferWidth + EffX],
      PByte(DstPtr)[Row * DstStride * SizeOf(TColorBGRA)],
      RowBytes
    );
  Result := True;
end;

function DXGITryGetImageInto(Window: TWindowHandle; X, Y, Width, Height: Integer;
                             DstPtr: PColorBGRA; DstStride: Integer): Boolean;
var
  WindowRect: TRect;
  MonitorHandle: HMONITOR;
  EffX, EffY: Integer;
  HR: HRESULT;
  Retried: Boolean;
begin
  Result := False;

  if Window = 0 then Exit;
  if (Width <= 0) or (Height <= 0) then Exit;
  if DstPtr = nil then Exit;
  if DstStride < Width then Exit;

  if GCaptureLock = nil then Exit;

  GCaptureLock.Enter;
  try
   try
    if (Window <> GUserWindow) or (GUserWindow = 0) then Exit;
    if not IsWindow(HWND(Window)) then Exit;

    // Re-evaluate the window's monitor on every call. Desktop layouts
    // change (DPI, plug/unplug), and the window may have been dragged.
    MonitorHandle := MonitorFromWindow(HWND(Window), MONITOR_DEFAULTTONEAREST);
    if MonitorHandle = 0 then Exit;

    // Lazy / monitor-switch: open or re-open the duplication if needed.
    if (GActiveDup = nil) or (MonitorHandle <> GActiveMonitor) then
    begin
      if GActiveDup <> nil then
        TearDownDuplication();
      if not OpenDuplicationForMonitor(MonitorHandle) then
        Exit;
    end;

    // Sample the window-screen rect AFTER ensuring the duplication is
    // open. If the window has moved since AutoOpen we want the current
    // position translated into the current monitor's coordinate frame.
    if not GetWindowRect(HWND(Window), WindowRect) then Exit;
    EffX := WindowRect.Left + X - GMonitorRect.Left;
    EffY := WindowRect.Top  + Y - GMonitorRect.Top;

    Retried := False;
    while True do
    begin
      HR := PumpFrame();
      if HR = DXGI_ERROR_ACCESS_LOST then
      begin
        // Monitor mode/resolution/DPI changed; re-acquire once.
        if Retried then Exit;
        Retried := True;
        TearDownDuplication();
        if not OpenDuplicationForMonitor(MonitorHandle) then Exit;
        // After re-acquire the monitor rect may have changed (DPI swap);
        // recompute EffX/Y.
        if not GetWindowRect(HWND(Window), WindowRect) then Exit;
        EffX := WindowRect.Left + X - GMonitorRect.Left;
        EffY := WindowRect.Top  + Y - GMonitorRect.Top;
        Continue;
      end;
      // Anything else: success or recoverable timeout. Both serve from
      // the cached frame buffer (which PumpFrame just refreshed on
      // S_OK; on WAIT_TIMEOUT we serve the previous frame).
      Break;
    end;

    GFrameBufferLock.Enter;
    try
      Result := CopyOutCrop(EffX, EffY, Width, Height, DstPtr, DstStride);
    finally
      GFrameBufferLock.Leave;
    end;
   except
     on E: Exception do
     begin
       GDXGILastError := 'Exception during DXGITryGetImageInto: ' +
                         E.ClassName + ': ' + E.Message;
       DXGILogError(GDXGILastError);
       Result := False;
     end;
   end;
  finally
    GCaptureLock.Leave;
  end;
end;

function DXGITryGetImage(Window: TWindowHandle; X, Y, Width, Height: Integer; var ImageData: PColorBGRA): Boolean;
begin
  // ReAllocMem matches the BitBlt path's allocator -- callers FreeMem
  // the returned pointer.
  if (Width > 0) and (Height > 0) then
    ReAllocMem(ImageData, Width * Height * SizeOf(TColorBGRA));

  Result := DXGITryGetImageInto(Window, X, Y, Width, Height, ImageData, Width);
end;

procedure DXGIRelease();
begin
  if GCaptureLock = nil then Exit;
  GCaptureLock.Enter;
  try
    if GActiveDup <> nil then
      TearDownDuplication();
    GUserWindow := 0;
    GDXGILastError := '';
    // D3D11 device / DXGI factory retained across sessions (singletons).
  finally
    GCaptureLock.Leave;
  end;
end;

function DXGILastError(): String;
begin
  if GCaptureLock = nil then Exit('');
  GCaptureLock.Enter;
  try
    Result := GDXGILastError;
  finally
    GCaptureLock.Leave;
  end;
end;

function DXGIFrameCount(): Int64;
begin
  Result := GFrameCount;
end;

{$ELSE}

procedure DXGIAutoOpen(Window: TWindowHandle);
begin
end;

function DXGITryGetImage(Window: TWindowHandle; X, Y, Width, Height: Integer; var ImageData: PColorBGRA): Boolean;
begin
  Result := False;
end;

function DXGITryGetImageInto(Window: TWindowHandle; X, Y, Width, Height: Integer;
                             DstPtr: PColorBGRA; DstStride: Integer): Boolean;
begin
  Result := False;
end;

procedure DXGIRelease();
begin
end;

function DXGILastError(): String;
begin
  Result := '';
end;

function DXGIFrameCount(): Int64;
begin
  Result := 0;
end;

{$ENDIF}

{$IFDEF WINDOWS}
initialization
  GCaptureLock := TCriticalSection.Create();
  GFrameBufferLock := TCriticalSection.Create();
  GMonitorRect := TRect.Empty;

finalization
  try
    DXGIRelease();
  except
  end;
  GDXGIFactory := nil;
  GD3DContext := nil;
  GD3DDevice := nil;
  if GFrameBufferLock <> nil then
    FreeAndNil(GFrameBufferLock);
  if GCaptureLock <> nil then
    FreeAndNil(GCaptureLock);
{$ENDIF}

end.
