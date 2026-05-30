{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)
}
unit simba.capture_wgc;

{$i simba.inc}

interface

uses
  Classes, SysUtils,
  simba.base;

procedure WGCAutoOpen(Window: TWindowHandle);
function WGCTryGetImage(Window: TWindowHandle; X, Y, Width, Height: Integer; var ImageData: PColorBGRA): Boolean;
function WGCTryGetImageInto(Window: TWindowHandle; X, Y, Width, Height: Integer;
                            DstPtr: PColorBGRA; DstStride: Integer): Boolean;
procedure WGCRelease();
function WGCLastError(): String;
function WGCFrameCount(): Int64;
function WGCFrameSkippedCount(): Int64;

implementation

{$IFDEF WINDOWS}

uses
  Windows, syncobjs,
  simba.winrt_helpers, simba.settings;

const
  // Constants from d3dcommon.h, d3d11.h, dxgiformat.h.
  D3D_DRIVER_TYPE_HARDWARE         = 1;
  D3D11_CREATE_DEVICE_BGRA_SUPPORT = $20;
  D3D11_SDK_VERSION                = 7;
  D3D11_USAGE_STAGING              = 3;
  D3D11_CPU_ACCESS_READ            = $20000;
  D3D11_MAP_READ                   = 1;
  DXGI_FORMAT_B8G8R8A8_UNORM       = 87;

  // dxgi.h: IDXGIDevice
  IID_IDXGIDevice: TGUID = '{54EC77FA-1377-44E6-8C32-88FD5F44C84C}';

  // ITypedEventHandler<Direct3D11CaptureFramePool, IInspectable>: parameterized-type
  // instance IID. Cross-checked against OBS's plugins/win-capture/window-capture.c.
  IID_ITypedEventHandler_FramePool: TGUID = '{51A947F7-79CF-5A3E-A3A5-7889B5BEDC3A}';

const
  // IIDs and vtable orders below are from Windows SDK 10.0.26100.0 headers
  // (cited inline above each declaration).

  // inspectable.h (line 105): MIDL_INTERFACE("AF86E2E0-B12D-4c6a-9C5A-D7AA65101E90")
  IID_IInspectable: TGUID = '{AF86E2E0-B12D-4C6A-9C5A-D7AA65101E90}';

  // Windows.Foundation.h: MIDL_INTERFACE("30d5a829-7fa4-4026-83bb-d75bae4ea99e") IClosable
  IID_IClosable: TGUID = '{30D5A829-7FA4-4026-83BB-D75BAE4EA99E}';

  // winrt/windows.graphics.capture.h (line 1156): MIDL_INTERFACE("79c3f95b-31f7-4ec2-a464-632ef5d30760")
  IID_IGraphicsCaptureItem: TGUID = '{79C3F95B-31F7-4EC2-A464-632EF5D30760}';

  // um/Windows.Graphics.Capture.Interop.h (line 15): DECLARE_INTERFACE_IID_(IGraphicsCaptureItemInterop, IUnknown, "3628E81B-3CAC-4C60-B7F4-23CE0E0C3356")
  IID_IGraphicsCaptureItemInterop: TGUID = '{3628E81B-3CAC-4C60-B7F4-23CE0E0C3356}';

  // winrt/windows.graphics.capture.h (line 983): MIDL_INTERFACE("24eb6d22-1975-422e-82e7-780dbd8ddf24")
  IID_IDirect3D11CaptureFramePool: TGUID = '{24EB6D22-1975-422E-82E7-780DBD8DDF24}';

  // winrt/windows.graphics.capture.h (line 1039): MIDL_INTERFACE("7784056a-67aa-4d53-ae54-1088d5a8ca21")
  IID_IDirect3D11CaptureFramePoolStatics: TGUID = '{7784056A-67AA-4D53-AE54-1088D5A8CA21}';

  // winrt/windows.graphics.capture.h (line 1079): MIDL_INTERFACE("589b103f-6bbc-5df5-a991-02e28b3b66d5")
  IID_IDirect3D11CaptureFramePoolStatics2: TGUID = '{589B103F-6BBC-5DF5-A991-02E28B3B66D5}';

  // winrt/windows.graphics.capture.h (line 902): MIDL_INTERFACE("fa50c623-38da-4b32-acf3-fa9734ad800e")
  IID_IDirect3D11CaptureFrame: TGUID = '{FA50C623-38DA-4B32-ACF3-FA9734AD800E}';

  // winrt/windows.graphics.capture.h (line 1316): MIDL_INTERFACE("814e42a9-f70f-4ad7-939b-fddcc6eb880d")
  IID_IGraphicsCaptureSession: TGUID = '{814E42A9-F70F-4AD7-939B-FDDCC6EB880D}';

  // winrt/windows.graphics.capture.h: MIDL_INTERFACE("2c39ae40-7d2e-5044-804e-8b6799d4cf9e")
  IID_IGraphicsCaptureSession2: TGUID = '{2C39AE40-7D2E-5044-804E-8B6799D4CF9E}';

  // winrt/windows.graphics.capture.h: MIDL_INTERFACE("f2cdd966-22ae-5ea1-9596-3a289344c3be")
  IID_IGraphicsCaptureSession3: TGUID = '{F2CDD966-22AE-5EA1-9596-3A289344C3BE}';

  // winrt/windows.graphics.directx.direct3d11.h (line 328): MIDL_INTERFACE("a37624ab-8d5f-4650-9d3e-9eae3d9bc670")
  IID_IDirect3DDevice: TGUID = '{A37624AB-8D5F-4650-9D3E-9EAE3D9BC670}';

  // winrt/windows.graphics.directx.direct3d11.h (line 365): MIDL_INTERFACE("0bf4a146-13c1-4694-bee3-7abf15eaf586")
  IID_IDirect3DSurface: TGUID = '{0BF4A146-13C1-4694-BEE3-7ABF15EAF586}';

  // um/windows.graphics.directx.direct3d11.interop.h (line 28): __declspec(uuid("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1"))
  IID_IDirect3DDxgiInterfaceAccess: TGUID = '{A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1}';

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

  // shared/dxgi.h (line 321): MIDL_INTERFACE("aec22fb8-76f3-4639-9be0-28eb43a67a2e")
  IID_IDXGIObject: TGUID = '{AEC22FB8-76F3-4639-9BE0-28EB43A67A2E}';

  // shared/dxgi.h (line 468): MIDL_INTERFACE("3d3e0379-f9de-4d58-bb6c-18d62992f1a6")
  IID_IDXGIDeviceSubObject: TGUID = '{3D3E0379-F9DE-4D58-BB6C-18D62992F1A6}';

  // shared/dxgi.h (line 958): MIDL_INTERFACE("cafcb56c-6ac3-4889-bf47-9e23bbd260ec")
  IID_IDXGISurface: TGUID = '{CAFCB56C-6AC3-4889-BF47-9E23BBD260EC}';


type
  IInspectable                       = interface;
  IClosable                          = interface;
  IGraphicsCaptureItem               = interface;
  IGraphicsCaptureItemInterop        = interface;
  IDirect3DDevice                    = interface;
  IDirect3DSurface                   = interface;
  IDirect3DDxgiInterfaceAccess       = interface;
  IDirect3D11CaptureFrame            = interface;
  IDirect3D11CaptureFramePool        = interface;
  IDirect3D11CaptureFramePoolStatics = interface;
  IDirect3D11CaptureFramePoolStatics2 = interface;
  IGraphicsCaptureSession            = interface;
  IGraphicsCaptureSession2           = interface;
  IGraphicsCaptureSession3           = interface;
  ID3D11Device                       = interface;
  ID3D11DeviceContext                = interface;
  ID3D11DeviceChild                  = interface;
  ID3D11Resource                     = interface;
  ID3D11Texture2D                    = interface;
  IDXGIObject                        = interface;
  IDXGIDeviceSubObject               = interface;
  IDXGISurface                       = interface;

type
  // Plain-data structs mirroring Windows SDK definitions; names match the
  // SDK type names verbatim.
  TSizeInt32 = record
    Width:  Int32;
    Height: Int32;
  end;
  PSizeInt32 = ^TSizeInt32;

  TTimeSpan = record
    Duration: Int64;
  end;
  PTimeSpan = ^TTimeSpan;

  TEventRegistrationToken = record
    Value: Int64;
  end;
  PEventRegistrationToken = ^TEventRegistrationToken;

  TDirectXPixelFormat = Int32;

  TDirect3DSurfaceDescription = record
    Width:        Int32;
    Height:       Int32;
    Format:       TDirectXPixelFormat;
    MultisampleDescription: record
      Count:   UInt32;
      Quality: UInt32;
    end;
  end;
  PDirect3DSurfaceDescription = ^TDirect3DSurfaceDescription;

  TD3D11_TEXTURE2D_DESC = record
    Width:          UInt32;
    Height:         UInt32;
    MipLevels:      UInt32;
    ArraySize:      UInt32;
    Format:         UInt32; // DXGI_FORMAT
    SampleDesc: record
      Count:   UInt32;
      Quality: UInt32;
    end;
    Usage:          UInt32; // D3D11_USAGE
    BindFlags:      UInt32;
    CPUAccessFlags: UInt32;
    MiscFlags:      UInt32;
  end;
  PD3D11_TEXTURE2D_DESC = ^TD3D11_TEXTURE2D_DESC;

  TD3D11_MAPPED_SUBRESOURCE = record
    pData:      Pointer;
    RowPitch:   UInt32;
    DepthPitch: UInt32;
  end;
  PD3D11_MAPPED_SUBRESOURCE = ^TD3D11_MAPPED_SUBRESOURCE;

  TDXGI_SURFACE_DESC = record
    Width:      UInt32;
    Height:     UInt32;
    Format:     UInt32; // DXGI_FORMAT
    SampleDesc: record
      Count:   UInt32;
      Quality: UInt32;
    end;
  end;
  PDXGI_SURFACE_DESC = ^TDXGI_SURFACE_DESC;

  TDXGI_MAPPED_RECT = record
    Pitch: Int32;
    pBits: PByte;
  end;
  PDXGI_MAPPED_RECT = ^TDXGI_MAPPED_RECT;


  // inspectable.h (line 105)
  IInspectable = interface(IInterface)
    ['{AF86E2E0-B12D-4C6A-9C5A-D7AA65101E90}']
    function GetIids(out iidCount: LongWord; out iids: PGUID): HRESULT; stdcall;
    function GetRuntimeClassName(out className: Pointer): HRESULT; stdcall;
    function GetTrustLevel(out trustLevel: Integer): HRESULT; stdcall;
  end;

  // Windows.Foundation.h (line 1291)
  IClosable = interface(IInspectable)
    ['{30D5A829-7FA4-4026-83BB-D75BAE4EA99E}']
    function Close(): HRESULT; stdcall;
  end;

  // windows.graphics.capture.h (line 1156)
  IGraphicsCaptureItem = interface(IInspectable)
    ['{79C3F95B-31F7-4EC2-A464-632EF5D30760}']
    function get_DisplayName(out value: Pointer{HSTRING}): HRESULT; stdcall;
    function get_Size(out value: TSizeInt32): HRESULT; stdcall;
    function add_Closed(handler: IInterface; out token: TEventRegistrationToken): HRESULT; stdcall;
    function remove_Closed(token: TEventRegistrationToken): HRESULT; stdcall;
  end;

  // Windows.Graphics.Capture.Interop.h (line 15) -- derives IUnknown directly
  IGraphicsCaptureItemInterop = interface(IInterface)
    ['{3628E81B-3CAC-4C60-B7F4-23CE0E0C3356}']
    function CreateForWindow(window: HWND; const iid: TGUID; out result): HRESULT; stdcall;
    function CreateForMonitor(monitor: HMONITOR; const iid: TGUID; out result): HRESULT; stdcall;
  end;

  // windows.graphics.capture.h (line 983)
  IDirect3D11CaptureFramePool = interface(IInspectable)
    ['{24EB6D22-1975-422E-82E7-780DBD8DDF24}']
    function Recreate(device: IDirect3DDevice; pixelFormat: TDirectXPixelFormat;
                      numberOfBuffers: Int32; size: TSizeInt32): HRESULT; stdcall;
    function TryGetNextFrame(out result: IDirect3D11CaptureFrame): HRESULT; stdcall;
    function add_FrameArrived(handler: IInterface; out token: TEventRegistrationToken): HRESULT; stdcall;
    function remove_FrameArrived(token: TEventRegistrationToken): HRESULT; stdcall;
    function CreateCaptureSession(item: IGraphicsCaptureItem; out result: IGraphicsCaptureSession): HRESULT; stdcall;
    function get_DispatcherQueue(out value: IInspectable): HRESULT; stdcall;
  end;

  // windows.graphics.capture.h (line 1039)
  IDirect3D11CaptureFramePoolStatics = interface(IInspectable)
    ['{7784056A-67AA-4D53-AE54-1088D5A8CA21}']
    function Create(device: IDirect3DDevice; pixelFormat: TDirectXPixelFormat;
                    numberOfBuffers: Int32; size: TSizeInt32;
                    out result: IDirect3D11CaptureFramePool): HRESULT; stdcall;
  end;

  // windows.graphics.capture.h (line 1079). CreateFreeThreaded delivers
  // FrameArrived on a thread pool (no DispatcherQueue required).
  IDirect3D11CaptureFramePoolStatics2 = interface(IInspectable)
    ['{589B103F-6BBC-5DF5-A991-02E28B3B66D5}']
    function CreateFreeThreaded(device: IDirect3DDevice; pixelFormat: TDirectXPixelFormat;
                                numberOfBuffers: Int32; size: TSizeInt32;
                                out result: IDirect3D11CaptureFramePool): HRESULT; stdcall;
  end;

  // windows.graphics.capture.h (line 902)
  IDirect3D11CaptureFrame = interface(IInspectable)
    ['{FA50C623-38DA-4B32-ACF3-FA9734AD800E}']
    function get_Surface(out value: IDirect3DSurface): HRESULT; stdcall;
    function get_SystemRelativeTime(out value: TTimeSpan): HRESULT; stdcall;
    function get_ContentSize(out value: TSizeInt32): HRESULT; stdcall;
  end;

  // windows.graphics.capture.h (line 1316). Close() lives on IClosable.
  IGraphicsCaptureSession = interface(IInspectable)
    ['{814E42A9-F70F-4AD7-939B-FDDCC6EB880D}']
    function StartCapture(): HRESULT; stdcall;
  end;

  // windows.graphics.capture.h. WinRT `boolean` is 1 byte (ByteBool), not Win32 BOOL.
  IGraphicsCaptureSession2 = interface(IInspectable)
    ['{2C39AE40-7D2E-5044-804E-8B6799D4CF9E}']
    function get_IsCursorCaptureEnabled(out value: ByteBool): HRESULT; stdcall;
    function put_IsCursorCaptureEnabled(value: ByteBool): HRESULT; stdcall;
  end;

  // windows.graphics.capture.h. Windows 11 only (build 22000+); Win10
  // never received this interface and always shows the yellow capture
  // border by Microsoft design.
  IGraphicsCaptureSession3 = interface(IInspectable)
    ['{F2CDD966-22AE-5EA1-9596-3A289344C3BE}']
    function get_IsBorderRequired(out value: ByteBool): HRESULT; stdcall;
    function put_IsBorderRequired(value: ByteBool): HRESULT; stdcall;
  end;

  // windows.graphics.directx.direct3d11.h (line 328)
  IDirect3DDevice = interface(IInspectable)
    ['{A37624AB-8D5F-4650-9D3E-9EAE3D9BC670}']
    function Trim(): HRESULT; stdcall;
  end;

  // windows.graphics.directx.direct3d11.h (line 365)
  IDirect3DSurface = interface(IInspectable)
    ['{0BF4A146-13C1-4694-BEE3-7ABF15EAF586}']
    function get_Description(out value: TDirect3DSurfaceDescription): HRESULT; stdcall;
  end;

  // windows.graphics.directx.direct3d11.interop.h (line 28) -- WinRT/native COM bridge
  IDirect3DDxgiInterfaceAccess = interface(IInterface)
    ['{A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1}']
    function GetInterface(const iid: TGUID; out p): HRESULT; stdcall;
  end;

  // d3d11.h (line 1395)
  ID3D11DeviceChild = interface(IInterface)
    ['{1841E5C8-16B0-489B-BCC8-44CFB0D5DEAE}']
    procedure GetDevice(out ppDevice: ID3D11Device); stdcall;
    function GetPrivateData(const guid: TGUID; var pDataSize: UInt32; pData: Pointer): HRESULT; stdcall;
    function SetPrivateData(const guid: TGUID; DataSize: UInt32; pData: Pointer): HRESULT; stdcall;
    function SetPrivateDataInterface(const guid: TGUID; pData: IInterface): HRESULT; stdcall;
  end;

  // d3d11.h (line 2251)
  ID3D11Resource = interface(ID3D11DeviceChild)
    ['{DC8E63F3-D12B-4952-B47B-5E45026A862D}']
    procedure GetType(out pResourceDimension: UInt32); stdcall;
    procedure SetEvictionPriority(EvictionPriority: UInt32); stdcall;
    function GetEvictionPriority(): UInt32; stdcall;
  end;

  // d3d11.h (line 2879)
  ID3D11Texture2D = interface(ID3D11Resource)
    ['{6F15AAF2-D208-4E89-9AB4-489535D34F9C}']
    procedure GetDesc(out pDesc: TD3D11_TEXTURE2D_DESC); stdcall;
  end;

  // d3d11.h (line 14143). Full vtable retained so slot indices match the SDK;
  // method names mirror d3d11.h for cross-reference.
  ID3D11Device = interface(IInterface)
    ['{DB6F6DDB-AC77-4E88-8253-819DF9BBF140}']
    // 0: CreateBuffer
    function CreateBuffer(pDesc: Pointer; pInitialData: Pointer; out ppBuffer: IInterface): HRESULT; stdcall;
    // 1: CreateTexture1D
    function CreateTexture1D(pDesc: Pointer; pInitialData: Pointer; out ppTexture1D: IInterface): HRESULT; stdcall;
    // 2: CreateTexture2D
    function CreateTexture2D(const pDesc: TD3D11_TEXTURE2D_DESC; pInitialData: Pointer; out ppTexture2D: ID3D11Texture2D): HRESULT; stdcall;
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
    // 34: GetFeatureLevel (returns D3D_FEATURE_LEVEL as UInt32)
    function GetFeatureLevel(): UInt32; stdcall;
    // 35: GetCreationFlags (returns UINT)
    function GetCreationFlags(): UInt32; stdcall;
    // 36: GetDeviceRemovedReason
    function GetDeviceRemovedReason(): HRESULT; stdcall;
    // 37: GetImmediateContext (void return)
    procedure GetImmediateContext(out ppImmediateContext: ID3D11DeviceContext); stdcall;
    // 38: SetExceptionMode
    function SetExceptionMode(RaiseFlags: UInt32): HRESULT; stdcall;
    // 39: GetExceptionMode (returns UINT)
    function GetExceptionMode(): UInt32; stdcall;
  end;

  // d3d11.h (line 7763). Full vtable retained so slot indices match the SDK;
  // method names mirror d3d11.h. Signatures we don't call are ABI-equivalent stubs.
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
    function  GetType_(): UInt32; stdcall;                              // d3d11.h: `GetType` (collides with ID3D11Resource.GetType)
    function  GetContextFlags(): UInt32; stdcall;
    function  FinishCommandList(RestoreDeferredContextState: LongBool;
                                out ppCommandList: IInterface): HRESULT; stdcall;
  end;

  // dxgi.h (line 321)
  IDXGIObject = interface(IInterface)
    ['{AEC22FB8-76F3-4639-9BE0-28EB43A67A2E}']
    function SetPrivateData(const Name: TGUID; DataSize: UInt32; pData: Pointer): HRESULT; stdcall;
    function SetPrivateDataInterface(const Name: TGUID; pUnknown: IInterface): HRESULT; stdcall;
    function GetPrivateData(const Name: TGUID; var pDataSize: UInt32; pData: Pointer): HRESULT; stdcall;
    function GetParent(const riid: TGUID; out ppParent): HRESULT; stdcall;
  end;

  // dxgi.h (line 468)
  IDXGIDeviceSubObject = interface(IDXGIObject)
    ['{3D3E0379-F9DE-4D58-BB6C-18D62992F1A6}']
    function GetDevice(const riid: TGUID; out ppDevice): HRESULT; stdcall;
  end;

  // dxgi.h (line 958)
  IDXGISurface = interface(IDXGIDeviceSubObject)
    ['{CAFCB56C-6AC3-4889-BF47-9E23BBD260EC}']
    function GetDesc(out pDesc: TDXGI_SURFACE_DESC): HRESULT; stdcall;
    function Map(out pLockedRect: TDXGI_MAPPED_RECT; MapFlags: UInt32): HRESULT; stdcall;
    function Unmap(): HRESULT; stdcall;
  end;

function D3D11CreateDevice(pAdapter: Pointer; DriverType: UInt32; Software: HMODULE;
  Flags: UInt32; pFeatureLevels: Pointer; FeatureLevels: UInt32; SDKVersion: UInt32;
  out ppDevice: ID3D11Device; out pFeatureLevel: UInt32;
  out ppImmediateContext: ID3D11DeviceContext): HRESULT; stdcall;
  external 'd3d11.dll' name 'D3D11CreateDevice';

function CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice: IInterface;
  out graphicsDevice: IInspectable): HRESULT; stdcall;
  external 'd3d11.dll' name 'CreateDirect3D11DeviceFromDXGIDevice';

// Lock ordering: GCaptureLock (outer, structural) -> GFrameBufferLock (inner,
// memcpy bursts). NEVER acquire the outer while holding the inner. Read paths
// (WGCTryGetImage*) take ONLY the inner so they can run concurrently with the
// FrameArrived handler's structural work.

type
  // asyncinfo.h. Marker interface; the free-threaded frame pool's
  // add_FrameArrived requires the handler to QI successfully for this.
  IAgileObject = interface(IInterface)
    ['{94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90}']
  end;

  ITypedEventHandler_FramePool = interface(IInterface)
    ['{51A947F7-79CF-5A3E-A3A5-7889B5BEDC3A}']
    function Invoke(sender: IDirect3D11CaptureFramePool;
                    args: IInspectable): HRESULT; stdcall;
  end;

  TFrameArrivedHandler = class(TInterfacedObject,
                               ITypedEventHandler_FramePool,
                               IAgileObject)
  public
    function Invoke(sender: IDirect3D11CaptureFramePool;
                    args: IInspectable): HRESULT; stdcall;
  end;

var
  GCaptureLock: TCriticalSection = nil;
  // WGC's IGraphicsCaptureItemInterop.CreateForWindow only accepts top-level
  // windows. When the user picks a child (e.g. RuneLite's SunAwtCanvas),
  // GUserWindow holds the user's handle and GCaptureWindow holds the root
  // we actually capture from; per-call coords get translated by the offsets
  // sampled at FrameArrived time (next block).
  GUserWindow: TWindowHandle = 0;
  GCaptureWindow: TWindowHandle = 0;
  GD3DDevice: ID3D11Device = nil;
  GD3DContext: ID3D11DeviceContext = nil;
  GWinRTD3DDevice: IDirect3DDevice = nil;
  GCaptureItem: IGraphicsCaptureItem = nil;
  GFramePool: IDirect3D11CaptureFramePool = nil;
  GSession: IGraphicsCaptureSession = nil;
  GFrameArrivedToken: TEventRegistrationToken;
  GFrameArrivedHandler: ITypedEventHandler_FramePool = nil;
  GStagingTexture: ID3D11Texture2D = nil;

  GFrameBufferLock: TCriticalSection = nil;
  GFrameBufferWidth: Int32 = 0;
  GFrameBufferHeight: Int32 = 0;
  GFrameBuffer: array of TColorBGRA;
  // Offset of GUserWindow within GCaptureWindow at the time the current
  // GFrameBuffer was staged. Sampled in FrameArrived so the coords match
  // the pixels, even if the user is mid-resize when WGCTryGetImageInto runs.
  GUserOffsetX: Int32 = 0;
  GUserOffsetY: Int32 = 0;
  GUserWidth:   Int32 = 0;
  GUserHeight:  Int32 = 0;

  GWGCLastError: String = '';
  GFrameCount: Int64 = 0;
  GFrameSkippedCount: Int64 = 0;

  // Drives the idle-skip in TFrameArrivedHandler.Invoke. Lockless: aligned
  // 64-bit reads/writes are atomic on x86_64.
  GLastConsumerTouchedAt: QWord = 0;


procedure WGCLogError(const Msg: String);
begin
  DebugLn(DEBUG_RED + '[WGC] ' + Msg + DEBUG_RESET);
end;

// WGC CreateForWindow requires a top-level HWND. Walks the user-supplied
// handle up to its root and reports the child's screen-space offset within
// the root. Offsets are recomputable cheaply; caller should sample them
// at FrameArrived time so they match the pixels staged in GFrameBuffer
// (the user can resize / slide a side panel between calls).
function ResolveCaptureRoot(UserWindow: TWindowHandle;
                            out RootWindow: TWindowHandle;
                            out OffsetX, OffsetY: Int32;
                            out UserW, UserH: Int32): Boolean;
var
  RootRect, ChildRect: TRect;
begin
  Result := False;
  RootWindow := 0;
  OffsetX := 0;
  OffsetY := 0;
  UserW := 0;
  UserH := 0;
  if (UserWindow = 0) or (not IsWindow(HWND(UserWindow))) then Exit;

  RootWindow := TWindowHandle(GetAncestor(HWND(UserWindow), GA_ROOT));
  if RootWindow = 0 then RootWindow := UserWindow;

  if not GetWindowRect(HWND(UserWindow), ChildRect) then Exit;
  UserW := ChildRect.Right  - ChildRect.Left;
  UserH := ChildRect.Bottom - ChildRect.Top;

  if RootWindow = UserWindow then
    Exit(True);

  if not GetWindowRect(HWND(RootWindow), RootRect) then Exit;
  OffsetX := ChildRect.Left - RootRect.Left;
  OffsetY := ChildRect.Top  - RootRect.Top;
  Result := True;
end;

// Caller MUST already hold GFrameBufferLock. Resamples the user-window
// offset within the capture root so the four GUser* globals stay in sync
// with the pixels we just staged into GFrameBuffer.
procedure SampleUserOffsetUnderLock();
var
  RootRect, ChildRect: TRect;
begin
  if (GUserWindow = 0) or (GCaptureWindow = 0) then Exit;
  if GUserWindow = GCaptureWindow then
  begin
    GUserOffsetX := 0;
    GUserOffsetY := 0;
    GUserWidth   := GFrameBufferWidth;
    GUserHeight  := GFrameBufferHeight;
    Exit;
  end;
  if not GetWindowRect(HWND(GUserWindow), ChildRect) then Exit;
  if not GetWindowRect(HWND(GCaptureWindow), RootRect) then Exit;
  GUserOffsetX := ChildRect.Left - RootRect.Left;
  GUserOffsetY := ChildRect.Top  - RootRect.Top;
  GUserWidth   := ChildRect.Right  - ChildRect.Left;
  GUserHeight  := ChildRect.Bottom - ChildRect.Top;
end;

// Caller MUST snapshot the globals under GCaptureLock and call this OUTSIDE
// the lock. The WGC runtime serialises remove_FrameArrived/IClosable.Close
// against in-flight FrameArrived handlers, and the handler takes GCaptureLock
// for its staging -- holding GCaptureLock across Close is an AB/BA deadlock.
procedure TearDownSession_NoLock(
  var LocalSession:    IGraphicsCaptureSession;
  var LocalFramePool:  IDirect3D11CaptureFramePool;
  var LocalItem:       IGraphicsCaptureItem;
  var LocalHandler:    ITypedEventHandler_FramePool;
  var LocalToken:      TEventRegistrationToken);
var
  Closable: IClosable;
begin
  if LocalFramePool <> nil then
  begin
    if LocalToken.Value <> 0 then
    begin
      LocalFramePool.remove_FrameArrived(LocalToken);
      LocalToken.Value := 0;
    end;
    if Supports(LocalFramePool, IClosable, Closable) then
      Closable.Close();
    Closable := nil;
  end;

  if LocalSession <> nil then
  begin
    if Supports(LocalSession, IClosable, Closable) then
      Closable.Close();
    Closable := nil;
  end;

  LocalHandler   := nil;
  LocalItem      := nil;
  LocalFramePool := nil;
  LocalSession   := nil;
end;

// Caller MUST hold GCaptureLock.
procedure InternalTearDownSession();
var
  Closable: IClosable;
begin
  if GSession <> nil then
  begin
    if Supports(GSession, IClosable, Closable) then
      Closable.Close();
    Closable := nil;
    GSession := nil;
  end;
  if GFramePool <> nil then
  begin
    if GFrameArrivedToken.Value <> 0 then
    begin
      GFramePool.remove_FrameArrived(GFrameArrivedToken);
      GFrameArrivedToken.Value := 0;
    end;
    if Supports(GFramePool, IClosable, Closable) then
      Closable.Close();
    Closable := nil;
    GFramePool := nil;
  end;
  GCaptureItem := nil;
  GFrameArrivedHandler := nil;
  GStagingTexture := nil;

  // Lock order: outer GCaptureLock (already held) then inner GFrameBufferLock.
  if GFrameBufferLock <> nil then
  begin
    GFrameBufferLock.Enter;
    try
      GFrameBufferWidth := 0;
      GFrameBufferHeight := 0;
      SetLength(GFrameBuffer, 0);
    finally
      GFrameBufferLock.Leave;
    end;
  end;
end;

// Caller MUST hold GCaptureLock. Populates GWGCLastError on failure.
function EnsureD3D11Device(): Boolean;
var
  HR: HRESULT;
  FeatureLevel: UInt32;
  DXGIDevice: IInterface;
  WinRTInspectable: IInspectable;
begin
  if (GD3DDevice <> nil) and (GD3DContext <> nil) and (GWinRTD3DDevice <> nil) then
    Exit(True);

  // WGC requires BGRA support on the D3D11 device.
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
    GWGCLastError := 'D3D11CreateDevice failed: ' + WinRT_HRESULTToStr(HR);
    GD3DDevice := nil;
    GD3DContext := nil;
    Exit(False);
  end;

  if GD3DDevice.QueryInterface(IID_IDXGIDevice, DXGIDevice) <> S_OK then
  begin
    GWGCLastError := 'QueryInterface(IDXGIDevice) failed on D3D11 device';
    GD3DDevice := nil;
    GD3DContext := nil;
    Exit(False);
  end;

  HR := CreateDirect3D11DeviceFromDXGIDevice(DXGIDevice, WinRTInspectable);
  DXGIDevice := nil;
  if not Succeeded(HR) then
  begin
    GWGCLastError := 'CreateDirect3D11DeviceFromDXGIDevice failed: ' + WinRT_HRESULTToStr(HR);
    GD3DDevice := nil;
    GD3DContext := nil;
    Exit(False);
  end;

  if not Supports(WinRTInspectable, IDirect3DDevice, GWinRTD3DDevice) then
  begin
    GWGCLastError := 'QueryInterface(IDirect3DDevice) failed on WinRT inspectable';
    GD3DDevice := nil;
    GD3DContext := nil;
    Exit(False);
  end;

  Result := True;
end;

procedure WGCAutoOpen(Window: TWindowHandle);
var
  InteropFactoryRaw: IInterface;
  InteropFactory: IGraphicsCaptureItemInterop;
  FramePoolStaticsRaw: IInterface;
  FramePoolStatics: IDirect3D11CaptureFramePoolStatics2;
  ItemSize: TSizeInt32;
  HR: HRESULT;
  Session2: IGraphicsCaptureSession2;
  Session3: IGraphicsCaptureSession3;
  PrevSession:     IGraphicsCaptureSession;
  PrevFramePool:   IDirect3D11CaptureFramePool;
  PrevItem:        IGraphicsCaptureItem;
  PrevHandler:     ITypedEventHandler_FramePool;
  PrevToken:       TEventRegistrationToken;
  HadPrevSession:  Boolean;
  RootWindow:      TWindowHandle;
  InitOffX, InitOffY, InitUserW, InitUserH: Int32;
begin
  // Capture.Method 0 = BitBlt: don't open a WGC session at all (avoids the
  // D3D device/frame-pool cost and the Win10 yellow capture border). Any
  // prior session is released so switching to BitBlt at runtime takes effect.
  if (SimbaSettings.Capture.Method.Value = 0) then
  begin
    WGCRelease();
    Exit;
  end;

  HadPrevSession := False;
  PrevSession    := nil;
  PrevFramePool  := nil;
  PrevItem       := nil;
  PrevHandler    := nil;
  PrevToken.Value := 0;

  // Resolve the user-supplied HWND to its top-level root. WGC's
  // CreateForWindow only accepts top-level windows; child windows (like
  // RuneLite's SunAwtCanvas) return E_INVALIDARG. We capture the root and
  // translate per-call coordinates by the offset in WGCTryGetImageInto.
  if (Window <> 0) and
     (not ResolveCaptureRoot(Window, RootWindow, InitOffX, InitOffY,
                             InitUserW, InitUserH)) then
  begin
    GCaptureLock.Enter;
    try
      GWGCLastError := 'ResolveCaptureRoot failed (invalid HWND or window has no root)';
      WGCLogError(GWGCLastError);
    finally
      GCaptureLock.Leave;
    end;
    Exit;
  end;
  if Window = 0 then
    RootWindow := 0;

  GCaptureLock.Enter;
  try
    GWGCLastError := '';

    if Window = GUserWindow then
      Exit;

    // Snapshot-then-close-outside-lock; see TearDownSession_NoLock.
    if GCaptureWindow <> 0 then
    begin
      HadPrevSession := True;
      PrevSession    := GSession;
      PrevFramePool  := GFramePool;
      PrevItem       := GCaptureItem;
      PrevHandler    := GFrameArrivedHandler;
      PrevToken      := GFrameArrivedToken;

      GSession             := nil;
      GFramePool           := nil;
      GCaptureItem         := nil;
      GFrameArrivedHandler := nil;
      GFrameArrivedToken.Value := 0;
      GStagingTexture      := nil;
      GCaptureWindow       := 0;
      GUserWindow          := 0;

      if GFrameBufferLock <> nil then
      begin
        GFrameBufferLock.Enter;
        try
          GFrameBufferWidth  := 0;
          GFrameBufferHeight := 0;
          GUserOffsetX := 0;
          GUserOffsetY := 0;
          GUserWidth   := 0;
          GUserHeight  := 0;
          SetLength(GFrameBuffer, 0);
        finally
          GFrameBufferLock.Leave;
        end;
      end;
    end;
  finally
    GCaptureLock.Leave;
  end;

  if HadPrevSession then
  begin
    TearDownSession_NoLock(PrevSession, PrevFramePool, PrevItem,
                           PrevHandler, PrevToken);
    WinRT_Uninitialize();
  end;

  GCaptureLock.Enter;
  try
   try
    GUserWindow    := Window;
    GCaptureWindow := RootWindow;
    if GFrameBufferLock <> nil then
    begin
      GFrameBufferLock.Enter;
      try
        GUserOffsetX := InitOffX;
        GUserOffsetY := InitOffY;
        GUserWidth   := InitUserW;
        GUserHeight  := InitUserH;
      finally
        GFrameBufferLock.Leave;
      end;
    end;
    if Window = 0 then
      Exit;

    if not WinRT_Initialize() then
    begin
      GWGCLastError := 'WinRT_Initialize failed: ' + WinRT_LastError();
      WGCLogError(GWGCLastError);
      GCaptureWindow := 0;
      GUserWindow := 0;
      Exit;
    end;

    if not EnsureD3D11Device() then
    begin
      WGCLogError(GWGCLastError);
      WinRT_Uninitialize();
      GCaptureWindow := 0;
      GUserWindow := 0;
      Exit;
    end;

    if not WinRT_GetActivationFactory(
         'Windows.Graphics.Capture.GraphicsCaptureItem',
         IID_IGraphicsCaptureItemInterop,
         InteropFactoryRaw) then
    begin
      GWGCLastError := 'GetActivationFactory(GraphicsCaptureItem -> Interop) failed: ' + WinRT_LastError();
      WGCLogError(GWGCLastError);
      InternalTearDownSession();
      WinRT_Uninitialize();
      GCaptureWindow := 0;
      GUserWindow := 0;
      Exit;
    end;

    if not Supports(InteropFactoryRaw, IGraphicsCaptureItemInterop, InteropFactory) then
    begin
      GWGCLastError := 'QueryInterface(IGraphicsCaptureItemInterop) failed';
      WGCLogError(GWGCLastError);
      InteropFactoryRaw := nil;
      InternalTearDownSession();
      WinRT_Uninitialize();
      GCaptureWindow := 0;
      GUserWindow := 0;
      Exit;
    end;
    InteropFactoryRaw := nil;

    // Capture the ROOT, not the user-supplied HWND. WGC rejects child
    // windows; we translate per-call coordinates back to canvas-local in
    // WGCTryGetImageInto using the offsets sampled in FrameArrived.
    HR := InteropFactory.CreateForWindow(HWND(RootWindow), IID_IGraphicsCaptureItem, GCaptureItem);
    InteropFactory := nil;
    if not Succeeded(HR) then
    begin
      // Recoverable: CreateForWindow returns E_INVALIDARG while the target is
      // transitioning (e.g. WaspLib resizing the client to fixed mode right
      // after a script sets its target). Record it for WGCLastError but do
      // NOT log -- GetWindowImage retries the open on demand and falls back
      // to BitBlt meanwhile, so a loud error here is just noise.
      GWGCLastError := 'IGraphicsCaptureItemInterop.CreateForWindow failed: ' + WinRT_HRESULTToStr(HR);
      InternalTearDownSession();
      WinRT_Uninitialize();
      GCaptureWindow := 0;
      GUserWindow := 0;
      Exit;
    end;
    if GCaptureItem = nil then
    begin
      GWGCLastError := 'CreateForWindow returned S_OK but null capture item';
      WGCLogError(GWGCLastError);
      InternalTearDownSession();
      WinRT_Uninitialize();
      GCaptureWindow := 0;
      GUserWindow := 0;
      Exit;
    end;

    HR := GCaptureItem.get_Size(ItemSize);
    if not Succeeded(HR) then
    begin
      GWGCLastError := 'IGraphicsCaptureItem.get_Size failed: ' + WinRT_HRESULTToStr(HR);
      WGCLogError(GWGCLastError);
      InternalTearDownSession();
      WinRT_Uninitialize();
      GCaptureWindow := 0;
      GUserWindow := 0;
      Exit;
    end;

    // Some windows briefly report 0 size before initial layout.
    if ItemSize.Width < 1 then ItemSize.Width := 1;
    if ItemSize.Height < 1 then ItemSize.Height := 1;

    if not WinRT_GetActivationFactory(
         'Windows.Graphics.Capture.Direct3D11CaptureFramePool',
         IID_IDirect3D11CaptureFramePoolStatics2,
         FramePoolStaticsRaw) then
    begin
      GWGCLastError := 'GetActivationFactory(Direct3D11CaptureFramePool -> Statics2) failed: ' + WinRT_LastError();
      WGCLogError(GWGCLastError);
      InternalTearDownSession();
      WinRT_Uninitialize();
      GCaptureWindow := 0;
      GUserWindow := 0;
      Exit;
    end;

    if not Supports(FramePoolStaticsRaw, IDirect3D11CaptureFramePoolStatics2, FramePoolStatics) then
    begin
      GWGCLastError := 'QueryInterface(IDirect3D11CaptureFramePoolStatics2) failed';
      WGCLogError(GWGCLastError);
      FramePoolStaticsRaw := nil;
      InternalTearDownSession();
      WinRT_Uninitialize();
      GCaptureWindow := 0;
      GUserWindow := 0;
      Exit;
    end;
    FramePoolStaticsRaw := nil;

    HR := FramePoolStatics.CreateFreeThreaded(
      GWinRTD3DDevice,
      TDirectXPixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM),
      2,
      ItemSize,
      GFramePool
    );
    FramePoolStatics := nil;
    if not Succeeded(HR) then
    begin
      GWGCLastError := 'CreateFreeThreaded(FramePool) failed: ' + WinRT_HRESULTToStr(HR);
      WGCLogError(GWGCLastError);
      InternalTearDownSession();
      WinRT_Uninitialize();
      GCaptureWindow := 0;
      GUserWindow := 0;
      Exit;
    end;

    HR := GFramePool.CreateCaptureSession(GCaptureItem, GSession);
    if not Succeeded(HR) then
    begin
      GWGCLastError := 'CreateCaptureSession failed: ' + WinRT_HRESULTToStr(HR);
      WGCLogError(GWGCLastError);
      InternalTearDownSession();
      WinRT_Uninitialize();
      GCaptureWindow := 0;
      GUserWindow := 0;
      Exit;
    end;

    GFrameArrivedHandler := TFrameArrivedHandler.Create() as ITypedEventHandler_FramePool;
    GFrameArrivedToken.Value := 0;
    HR := GFramePool.add_FrameArrived(GFrameArrivedHandler, GFrameArrivedToken);
    if not Succeeded(HR) then
    begin
      GWGCLastError := 'add_FrameArrived failed: ' + WinRT_HRESULTToStr(HR);
      WGCLogError(GWGCLastError);
      InternalTearDownSession();
      WinRT_Uninitialize();
      GCaptureWindow := 0;
      GUserWindow := 0;
      Exit;
    end;

    if Supports(GSession, IGraphicsCaptureSession2, Session2) then
    begin
      Session2.put_IsCursorCaptureEnabled(ByteBool(False));
      Session2 := nil;
    end;

    if Supports(GSession, IGraphicsCaptureSession3, Session3) then
    begin
      Session3.put_IsBorderRequired(ByteBool(False));
      Session3 := nil;
    end;

    HR := GSession.StartCapture();
    if not Succeeded(HR) then
    begin
      GWGCLastError := 'StartCapture failed: ' + WinRT_HRESULTToStr(HR);
      WGCLogError(GWGCLastError);
      InternalTearDownSession();
      WinRT_Uninitialize();
      GCaptureWindow := 0;
      GUserWindow := 0;
      Exit;
    end;

    // Warm-up: stage every frame for IDLE_SKIP_THRESHOLD_MS so single-shot
    // consumers reading right after bring-up don't see an empty image.
    GLastConsumerTouchedAt := GetTickCount64();
   except
     on E: Exception do
     begin
       GWGCLastError := 'Exception during WGC session bring-up: ' +
                        E.ClassName + ': ' + E.Message;
       WGCLogError(GWGCLastError);
       InternalTearDownSession();
       try
         WinRT_Uninitialize();
       except
       end;
       GCaptureWindow := 0;
       GUserWindow    := 0;
     end;
   end;
  finally
    GCaptureLock.Leave;
  end;
end;

// COM callback: catches Pascal exceptions and converts to E_FAIL.
function TFrameArrivedHandler.Invoke(sender: IDirect3D11CaptureFramePool;
                                     args: IInspectable): HRESULT; stdcall;
const
  // ~12 DWM compose cycles. If no consumer has read in this long, skip the
  // GPU->CPU staging + memcpy (the frame must still be pulled from the pool
  // -- pool starves otherwise).
  IDLE_SKIP_THRESHOLD_MS = 200;
var
  Frame: IDirect3D11CaptureFrame;
  Surface: IDirect3DSurface;
  SurfaceAccess: IDirect3DDxgiInterfaceAccess;
  D3DTexture: ID3D11Texture2D;
  TexDesc: TD3D11_TEXTURE2D_DESC;
  StagingDesc: TD3D11_TEXTURE2D_DESC;
  Mapped: TD3D11_MAPPED_SUBRESOURCE;
  Row: Integer;
  RowBytes: PtrUInt;
  HR: HRESULT;
  LastTouched: QWord;
  NowMs: QWord;
begin
  Result := S_OK;
  try
    if sender = nil then
      Exit;

    Frame := nil;
    HR := sender.TryGetNextFrame(Frame);
    if (not Succeeded(HR)) or (Frame = nil) then
      Exit;

    Surface := nil;
    if (Frame.get_Surface(Surface) <> S_OK) or (Surface = nil) then
      Exit;

    if not Supports(Surface, IDirect3DDxgiInterfaceAccess, SurfaceAccess) then
      Exit;
    Surface := nil;

    D3DTexture := nil;
    if (SurfaceAccess.GetInterface(IID_ID3D11Texture2D, D3DTexture) <> S_OK) or (D3DTexture = nil) then
      Exit;
    SurfaceAccess := nil;

    D3DTexture.GetDesc(TexDesc);
    if (TexDesc.Width = 0) or (TexDesc.Height = 0) then
      Exit;

    LastTouched := GLastConsumerTouchedAt;
    if LastTouched = 0 then
    begin
      InterlockedIncrement64(GFrameSkippedCount);
      Exit;
    end;
    NowMs := GetTickCount64();
    if (NowMs > LastTouched) and ((NowMs - LastTouched) > IDLE_SKIP_THRESHOLD_MS) then
    begin
      InterlockedIncrement64(GFrameSkippedCount);
      Exit;
    end;

    GCaptureLock.Enter;
    try
      // GFramePool is the session-active sentinel (nil-ed by Release under
      // GCaptureLock before its outside-the-lock teardown). GD3DDevice /
      // GD3DContext are kept across sessions so cannot serve this role.
      if (GFramePool = nil) or (GCaptureItem = nil) then
        Exit;
      if (GD3DDevice = nil) or (GD3DContext = nil) then
        Exit;

      if (GStagingTexture = nil) or
         (UInt32(GFrameBufferWidth) <> TexDesc.Width) or
         (UInt32(GFrameBufferHeight) <> TexDesc.Height) then
      begin
        GStagingTexture := nil;
        FillChar(StagingDesc, SizeOf(StagingDesc), 0);
        StagingDesc.Width := TexDesc.Width;
        StagingDesc.Height := TexDesc.Height;
        StagingDesc.MipLevels := 1;
        StagingDesc.ArraySize := 1;
        StagingDesc.Format := DXGI_FORMAT_B8G8R8A8_UNORM;
        StagingDesc.SampleDesc.Count := 1;
        StagingDesc.SampleDesc.Quality := 0;
        StagingDesc.Usage := D3D11_USAGE_STAGING;
        StagingDesc.BindFlags := 0;
        StagingDesc.CPUAccessFlags := D3D11_CPU_ACCESS_READ;
        StagingDesc.MiscFlags := 0;

        HR := GD3DDevice.CreateTexture2D(StagingDesc, nil, GStagingTexture);
        if (not Succeeded(HR)) or (GStagingTexture = nil) then
        begin
          GStagingTexture := nil;
          Exit;
        end;

        // Shrinks as well as grows so a 4K-then-small switch releases memory.
        GFrameBufferLock.Enter;
        try
          GFrameBufferWidth := Int32(TexDesc.Width);
          GFrameBufferHeight := Int32(TexDesc.Height);
          SetLength(GFrameBuffer, GFrameBufferWidth * GFrameBufferHeight);
        finally
          GFrameBufferLock.Leave;
        end;
      end;

      GD3DContext.CopyResource(GStagingTexture, D3DTexture);

      FillChar(Mapped, SizeOf(Mapped), 0);
      HR := GD3DContext.Map(GStagingTexture, 0, D3D11_MAP_READ, 0, Mapped);
      if (not Succeeded(HR)) or (Mapped.pData = nil) then
        Exit;

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
          // Snapshot user-window-within-root offset NOW, while the pixels
          // are still fresh, so a mid-resize WGCTryGetImageInto reads
          // matching coordinates and content (rather than the new offset
          // applied to the old frame).
          SampleUserOffsetUnderLock();
          InterlockedIncrement64(GFrameCount);
        finally
          GFrameBufferLock.Leave;
        end;
      finally
        GD3DContext.Unmap(GStagingTexture, 0);
      end;
    finally
      GCaptureLock.Leave;
    end;
  except
    on E: Exception do
      Result := HRESULT($80004005); // E_FAIL
  end;
end;

function WGCTryGetImageInto(Window: TWindowHandle; X, Y, Width, Height: Integer;
                            DstPtr: PColorBGRA; DstStride: Integer): Boolean;
var
  Row: Integer;
  RowBytes: PtrUInt;
  EffX, EffY: Integer;
begin
  Result := False;

  // Touch BEFORE validation: any call (even malformed) signals consumer activity.
  GLastConsumerTouchedAt := GetTickCount64();

  if Window = 0 then Exit;
  if (Width <= 0) or (Height <= 0) then Exit;
  if DstPtr = nil then Exit;
  if DstStride < Width then Exit;
  // Accept either the user-supplied HWND (e.g. a child like SunAwtCanvas)
  // or the actual capture root. Anything else is not our target.
  if (Window <> GUserWindow) and (Window <> GCaptureWindow) then Exit;

  GFrameBufferLock.Enter;
  try
    if (GFrameBufferWidth <= 0) or (GFrameBufferHeight <= 0) then
      Exit;

    // If the caller addressed by the user HWND, translate (X, Y) into
    // GFrameBuffer coords using the offsets snapshotted at FrameArrived
    // time. If they addressed the root, no translation needed.
    if Window = GUserWindow then
    begin
      EffX := X + GUserOffsetX;
      EffY := Y + GUserOffsetY;
    end
    else
    begin
      EffX := X;
      EffY := Y;
    end;

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
  finally
    GFrameBufferLock.Leave;
  end;
end;

function WGCTryGetImage(Window: TWindowHandle; X, Y, Width, Height: Integer; var ImageData: PColorBGRA): Boolean;
begin
  // ReAllocMem matches the BitBlt path's allocator.
  if (Width > 0) and (Height > 0) then
    ReAllocMem(ImageData, Width * Height * SizeOf(TColorBGRA));

  Result := WGCTryGetImageInto(Window, X, Y, Width, Height, ImageData, Width);
end;

procedure WGCRelease();
var
  HadSession: Boolean;
  LocalSession: IGraphicsCaptureSession;
  LocalFramePool: IDirect3D11CaptureFramePool;
  LocalItem: IGraphicsCaptureItem;
  LocalHandler: ITypedEventHandler_FramePool;
  LocalToken: TEventRegistrationToken;
begin
  // Snapshot-then-close-outside-lock; see TearDownSession_NoLock.
  LocalSession   := nil;
  LocalFramePool := nil;
  LocalItem      := nil;
  LocalHandler   := nil;
  LocalToken.Value := 0;

  GCaptureLock.Enter;
  try
    HadSession := (GCaptureWindow <> 0) or
                  (GSession <> nil) or (GFramePool <> nil) or (GCaptureItem <> nil);

    LocalSession   := GSession;
    LocalFramePool := GFramePool;
    LocalItem      := GCaptureItem;
    LocalHandler   := GFrameArrivedHandler;
    LocalToken     := GFrameArrivedToken;

    GSession             := nil;
    GFramePool           := nil;
    GCaptureItem         := nil;
    GFrameArrivedHandler := nil;
    GFrameArrivedToken.Value := 0;
    GCaptureWindow       := 0;
    GUserWindow          := 0;
    GStagingTexture      := nil;
    GLastConsumerTouchedAt := 0;

    if GFrameBufferLock <> nil then
    begin
      GFrameBufferLock.Enter;
      try
        GFrameBufferWidth := 0;
        GFrameBufferHeight := 0;
        GUserOffsetX := 0;
        GUserOffsetY := 0;
        GUserWidth   := 0;
        GUserHeight  := 0;
        SetLength(GFrameBuffer, 0);
      finally
        GFrameBufferLock.Leave;
      end;
    end;
    // GD3DDevice / GD3DContext / GWinRTD3DDevice retained across sessions
    // (singleton; see EnsureD3D11Device).
  finally
    GCaptureLock.Leave;
  end;

  TearDownSession_NoLock(LocalSession, LocalFramePool, LocalItem,
                         LocalHandler, LocalToken);

  if HadSession then
    WinRT_Uninitialize();
end;

function WGCLastError(): String;
begin
  if GCaptureLock = nil then
    Exit('');
  GCaptureLock.Enter;
  try
    Result := GWGCLastError;
  finally
    GCaptureLock.Leave;
  end;
end;

function WGCFrameCount(): Int64;
begin
  Result := GFrameCount;
end;

function WGCFrameSkippedCount(): Int64;
begin
  Result := GFrameSkippedCount;
end;

{$ELSE}

procedure WGCAutoOpen(Window: TWindowHandle);
begin
end;

function WGCTryGetImage(Window: TWindowHandle; X, Y, Width, Height: Integer; var ImageData: PColorBGRA): Boolean;
begin
  Result := False;
end;

function WGCTryGetImageInto(Window: TWindowHandle; X, Y, Width, Height: Integer;
                            DstPtr: PColorBGRA; DstStride: Integer): Boolean;
begin
  Result := False;
end;

procedure WGCRelease();
begin
end;

function WGCLastError(): String;
begin
  Result := '';
end;

function WGCFrameCount(): Int64;
begin
  Result := 0;
end;

function WGCFrameSkippedCount(): Int64;
begin
  Result := 0;
end;

{$ENDIF}

{$IFDEF WINDOWS}
initialization
  GCaptureLock := TCriticalSection.Create();
  GFrameBufferLock := TCriticalSection.Create();
  GFrameArrivedToken.Value := 0;

finalization
  try
    WGCRelease();
  except
  end;
  GD3DContext := nil;
  GD3DDevice := nil;
  GWinRTD3DDevice := nil;
  if GFrameBufferLock <> nil then
    FreeAndNil(GFrameBufferLock);
  if GCaptureLock <> nil then
    FreeAndNil(GCaptureLock);
{$ENDIF}

end.
