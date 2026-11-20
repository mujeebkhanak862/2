// screen_capture_manager.cpp
#include "screen_capture_manager.h"

#include <flutter/standard_method_codec.h>
#include <wincodec.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.DirectX.h>

#include <d3d11.h>
#include <commctrl.h>
#include <wrl/client.h>
#include <algorithm>
#include <string>
#include <windows.graphics.capture.interop.h>

#pragma comment(lib, "comctl32.lib")

using namespace winrt::Windows::Graphics::Capture;
using namespace winrt::Windows::Graphics::DirectX;
using namespace winrt::Windows::Graphics::DirectX::Direct3D11;

namespace {
constexpr char kMethodChannel[] = "device_agent/screen_capture";
constexpr char kEventChannel[] = "device_agent/screen_live_stream";

// D3D11 device banata hai aur usko WinRT IDirect3DDevice mein wrap karta
// hai — GraphicsCaptureItem isi device ke against frames deta hai.
IDirect3DDevice CreateD3DDevice() {
  Microsoft::WRL::ComPtr<ID3D11Device> d3d_device;
  // Item 83: HRESULT pehle ignore hota tha (null device => crash).
  winrt::check_hresult(D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
      &d3d_device, nullptr, nullptr));

  Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
  d3d_device.As(&dxgi_device);

  winrt::com_ptr<::IInspectable> inspectable;
  winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(
      dxgi_device.Get(),
      reinterpret_cast<::IInspectable**>(winrt::put_abi(inspectable))));
  return inspectable.as<IDirect3DDevice>();
}

// HWND se GraphicsCaptureItem banane ke liye interop factory chahiye —
// yeh WinRT API standalone HWND capture ke liye is tarah expose hoti hai.
GraphicsCaptureItem CreateCaptureItemForPrimaryMonitor() {
  auto factory = winrt::get_activation_factory<
      GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
  HMONITOR monitor = MonitorFromWindow(GetDesktopWindow(), MONITOR_DEFAULTTOPRIMARY);
  GraphicsCaptureItem item{nullptr};
  winrt::check_hresult(factory->CreateForMonitor(
      monitor, winrt::guid_of<GraphicsCaptureItem>(),
      winrt::put_abi(item)));
  return item;
}

// WIC ka use karke ek BGRA texture ko JPEG bytes mein encode karta hai.
// Item 83: pehle ka encoder do bugs rakhta tha — (1) GPU texture par seedha
// `Map(D3D11_MAP_READ)` (fail hota hai; CPU read ke liye STAGING texture
// chahiye), (2) JPEG encoder 24bpp mangta hai par BGRA bytes `WritePixels`
// se likhe ja rahe the (colors/stride corrupt). Ab: staging copy ->
// WIC bitmap -> (optional downscale) -> `WriteSource` (WIC khud format
// convert karta hai).
std::vector<uint8_t> EncodeFrameAsJpeg(const Direct3D11CaptureFrame& frame,
                                        int max_width) {
  std::vector<uint8_t> out;

  auto surface = frame.Surface();
  auto access = surface.as<
      Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
  Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
  if (FAILED(access->GetInterface(IID_PPV_ARGS(&texture)))) return out;

  D3D11_TEXTURE2D_DESC desc;
  texture->GetDesc(&desc);

  Microsoft::WRL::ComPtr<ID3D11Device> device;
  texture->GetDevice(&device);
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context;
  device->GetImmediateContext(&context);

  D3D11_TEXTURE2D_DESC staging_desc = desc;
  staging_desc.Usage = D3D11_USAGE_STAGING;
  staging_desc.BindFlags = 0;
  staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  staging_desc.MiscFlags = 0;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> staging;
  if (FAILED(device->CreateTexture2D(&staging_desc, nullptr, &staging))) return out;
  context->CopyResource(staging.Get(), texture.Get());

  D3D11_MAPPED_SUBRESOURCE mapped{};
  if (FAILED(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) return out;

  Microsoft::WRL::ComPtr<IWICImagingFactory> wic;
  Microsoft::WRL::ComPtr<IWICBitmap> bitmap;
  HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic));
  if (SUCCEEDED(hr)) {
    hr = wic->CreateBitmapFromMemory(
        desc.Width, desc.Height, GUID_WICPixelFormat32bppBGRA, mapped.RowPitch,
        mapped.RowPitch * desc.Height, static_cast<BYTE*>(mapped.pData), &bitmap);
  }
  // CreateBitmapFromMemory data copy karta hai — ab unmap safe hai.
  context->Unmap(staging.Get(), 0);
  if (FAILED(hr)) return out;

  Microsoft::WRL::ComPtr<IWICBitmapSource> source = bitmap;
  UINT out_w = desc.Width, out_h = desc.Height;
  if (max_width > 0 && static_cast<int>(desc.Width) > max_width) {
    out_w = static_cast<UINT>(max_width);
    out_h = std::max<UINT>(1, static_cast<UINT>(
        static_cast<uint64_t>(desc.Height) * out_w / desc.Width));
    Microsoft::WRL::ComPtr<IWICBitmapScaler> scaler;
    if (SUCCEEDED(wic->CreateBitmapScaler(&scaler)) &&
        SUCCEEDED(scaler->Initialize(bitmap.Get(), out_w, out_h,
                                     WICBitmapInterpolationModeFant))) {
      source = scaler;
    } else {
      out_w = desc.Width;
      out_h = desc.Height;
    }
  }

  Microsoft::WRL::ComPtr<IStream> stream;
  if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) return out;
  Microsoft::WRL::ComPtr<IWICBitmapEncoder> encoder;
  if (FAILED(wic->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &encoder))) return out;
  if (FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache))) return out;

  Microsoft::WRL::ComPtr<IWICBitmapFrameEncode> frame_enc;
  Microsoft::WRL::ComPtr<IPropertyBag2> props;
  if (FAILED(encoder->CreateNewFrame(&frame_enc, &props))) return out;
  if (props) {
    PROPBAG2 option{};
    option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_R4;
    value.fltVal = max_width > 0 ? 0.6f : 0.85f;  // stream chhota, screenshot behtar
    props->Write(1, &option, &value);
  }
  if (FAILED(frame_enc->Initialize(props.Get()))) return out;
  if (FAILED(frame_enc->SetSize(out_w, out_h))) return out;
  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  frame_enc->SetPixelFormat(&format);
  if (FAILED(frame_enc->WriteSource(source.Get(), nullptr))) return out;
  if (FAILED(frame_enc->Commit()) || FAILED(encoder->Commit())) return out;

  STATSTG stats;
  if (FAILED(stream->Stat(&stats, STATFLAG_NONAME))) return out;
  ULONG size = static_cast<ULONG>(stats.cbSize.QuadPart);
  out.resize(size);
  LARGE_INTEGER zero{};
  stream->Seek(zero, STREAM_SEEK_SET, nullptr);
  ULONG read = 0;
  stream->Read(out.data(), size, &read);
  out.resize(read);
  return out;
}

// Item 83: pehle ka encoder trailing 1-2 bytes drop karta tha aur `=`
// padding nahi lagata tha — har screenshot/frame ka base64 corrupt tha.
std::string Base64EncodePadded(const std::vector<uint8_t>& data) {
  static const char* kChars =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string encoded;
  encoded.reserve(((data.size() + 2) / 3) * 4);
  size_t i = 0;
  while (i + 2 < data.size()) {
    uint32_t n = (static_cast<uint32_t>(data[i]) << 16) |
                 (static_cast<uint32_t>(data[i + 1]) << 8) | data[i + 2];
    encoded += kChars[(n >> 18) & 0x3F];
    encoded += kChars[(n >> 12) & 0x3F];
    encoded += kChars[(n >> 6) & 0x3F];
    encoded += kChars[n & 0x3F];
    i += 3;
  }
  size_t rem = data.size() - i;
  if (rem == 1) {
    uint32_t n = static_cast<uint32_t>(data[i]) << 16;
    encoded += kChars[(n >> 18) & 0x3F];
    encoded += kChars[(n >> 12) & 0x3F];
    encoded += "==";
  } else if (rem == 2) {
    uint32_t n = (static_cast<uint32_t>(data[i]) << 16) |
                 (static_cast<uint32_t>(data[i + 1]) << 8);
    encoded += kChars[(n >> 18) & 0x3F];
    encoded += kChars[(n >> 12) & 0x3F];
    encoded += kChars[(n >> 6) & 0x3F];
    encoded += '=';
  }
  return encoded;
}

constexpr UINT kFrameMessage = WM_APP + 0x41;
constexpr UINT_PTR kSubclassId = 0xDA5C;
constexpr int kStreamMaxWidth = 1280;
constexpr ULONGLONG kStreamMinIntervalMs = 125;  // ~8 fps

LRESULT CALLBACK ScreenSubclassProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp,
                                    UINT_PTR, DWORD_PTR ref) {
  if (msg == kFrameMessage) {
    reinterpret_cast<ScreenCaptureManager*>(ref)->FlushPendingFrame();
    return 0;
  }
  return DefSubclassProc(hwnd, msg, wp, lp);
}
}  // namespace

void ScreenCaptureManager::Register(flutter::FlutterEngine* engine,
                                     HWND window_handle) {
  new ScreenCaptureManager(engine, window_handle);
}

ScreenCaptureManager::ScreenCaptureManager(flutter::FlutterEngine* engine,
                                            HWND window_handle)
    : window_handle_(window_handle) {
  // Item 83: FrameArrived thread-pool thread par aata hai; Flutter ke
  // EventSink ko sirf platform thread se call karna safe hai. Isliye
  // frame ko queue karke window message se platform thread par bhejte hain.
  if (window_handle_ != nullptr) {
    SetWindowSubclass(window_handle_, ScreenSubclassProc, kSubclassId,
                      reinterpret_cast<DWORD_PTR>(this));
  }

  method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          engine->messenger(), kMethodChannel,
          &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });

  event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          engine->messenger(), kEventChannel,
          &flutter::StandardMethodCodec::GetInstance());
  event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            event_sink_ = std::move(sink);
            StartStream();
            return nullptr;
          },
          [this](const flutter::EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            StopStream();
            event_sink_ = nullptr;
            return nullptr;
          }));
}

ScreenCaptureManager::~ScreenCaptureManager() {
  StopStream();
  if (window_handle_ != nullptr) {
    RemoveWindowSubclass(window_handle_, ScreenSubclassProc, kSubclassId);
  }
}

void ScreenCaptureManager::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "requestPermission") {
    // Desktop par koi consent dialog nahi — sirf "is machine par capture
    // supported hai ya nahi" (Windows 10 1903+).
    bool supported = false;
    try {
      supported = GraphicsCaptureSession::IsSupported();
    } catch (...) {
    }
    result->Success(flutter::EncodableValue(supported));
  } else if (call.method_name() == "captureScreenshot") {
    if (!EnsureSessionStarted()) {
      result->Error("NOT_READY", "Capture session start nahi ho saka");
      return;
    }
    // Item 83: pehle `StartCapture()` sirf stream mein hota tha, isliye
    // screenshot par `TryGetNextFrame()` hamesha null aata tha (khaali
    // string "success" ban kar jati thi). Ab capture start hota hai, latest
    // frame ka wait hota hai, aur stream na chal rahi ho to session phir
    // band ho jata hai (Windows ka yellow capture border/CPU na chale).
    bool started_here = false;
    try {
      if (!capture_started_.exchange(true)) {
        capture_session_.StartCapture();
        started_here = true;
      }
    } catch (...) {
      capture_started_ = false;
      result->Error("NOT_READY", "Capture start nahi ho saka");
      return;
    }
    auto jpeg = CaptureLatestJpeg(/*wait_ms=*/1500, /*max_width=*/0);
    if (!streaming_ && started_here) TeardownSession();
    if (jpeg.empty()) {
      result->Error("NOT_READY", "Abhi tak koi frame nahi mila — dobara try karein");
      return;
    }
    result->Success(flutter::EncodableValue(Base64EncodePadded(jpeg)));
  } else if (call.method_name() == "stopStream") {
    StopStream();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

bool ScreenCaptureManager::EnsureSessionStarted() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (session_ready_) return true;
  try {
    d3d_device_ = CreateD3DDevice();
    capture_item_ = CreateCaptureItemForPrimaryMonitor();
    auto size = capture_item_.Size();
    frame_pool_ = Direct3D11CaptureFramePool::CreateFreeThreaded(
        d3d_device_, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
    capture_session_ = frame_pool_.CreateCaptureSession(capture_item_);
    session_ready_ = true;
    return true;
  } catch (...) {
    return false;
  }
}

// Pool ko drain karke sabse naya frame leta hai (pehle sirf "next" frame
// milta tha jo purana ho sakta hai); `wait_ms` tak naye frame ka intezaar.
std::vector<uint8_t> ScreenCaptureManager::CaptureLatestJpeg(int wait_ms,
                                                            int max_width) {
  std::lock_guard<std::mutex> lock(capture_mutex_);
  if (!session_ready_) return {};
  try {
    Direct3D11CaptureFrame latest{nullptr};
    const ULONGLONG deadline = GetTickCount64() + static_cast<ULONGLONG>(wait_ms);
    for (;;) {
      for (;;) {
        auto f = frame_pool_.TryGetNextFrame();
        if (!f) break;
        latest = f;
      }
      if (latest || GetTickCount64() >= deadline) break;
      Sleep(25);
    }
    if (!latest) return {};
    return EncodeFrameAsJpeg(latest, max_width);
  } catch (...) {
    return {};
  }
}

void ScreenCaptureManager::StartStream() {
  if (!EnsureSessionStarted()) return;
  streaming_ = true;
  last_stream_tick_ = 0;
  try {
    frame_token_ = frame_pool_.FrameArrived(
        {this, &ScreenCaptureManager::OnFrameArrived});
    if (!capture_started_.exchange(true)) capture_session_.StartCapture();
  } catch (...) {
    streaming_ = false;
  }
}

void ScreenCaptureManager::TeardownSession() {
  std::lock_guard<std::mutex> lock(mutex_);
  std::lock_guard<std::mutex> capture_lock(capture_mutex_);
  try {
    if (frame_pool_ && frame_token_.value != 0) {
      frame_pool_.FrameArrived(frame_token_);  // handler revoke
      frame_token_ = {};
    }
    if (capture_session_) capture_session_.Close();
    if (frame_pool_) frame_pool_.Close();
  } catch (...) {
  }
  capture_session_ = nullptr;
  frame_pool_ = nullptr;
  capture_started_ = false;
  session_ready_ = false;
}

void ScreenCaptureManager::StopStream() {
  streaming_ = false;
  TeardownSession();
  std::lock_guard<std::mutex> lock(pending_mutex_);
  pending_jpeg_.clear();
}

void ScreenCaptureManager::OnFrameArrived(
    Direct3D11CaptureFramePool const&,
    winrt::Windows::Foundation::IInspectable const&) {
  // Thread-pool thread — yahan Flutter API call NAHI hoti.
  if (!streaming_) return;

  // FPS cap: throttle hone par bhi frame consume karna padta hai warna
  // pool bhar jata hai; CaptureLatestJpeg(0) drain karke encode karta hai,
  // isliye throttle encode se PEHLE check karte hain aur sirf drain karte hain.
  ULONGLONG now = GetTickCount64();
  if (now - last_stream_tick_ < kStreamMinIntervalMs) {
    std::lock_guard<std::mutex> lock(capture_mutex_);
    try {
      if (frame_pool_) {
        for (;;) {
          auto f = frame_pool_.TryGetNextFrame();
          if (!f) break;
        }
      }
    } catch (...) {
    }
    return;
  }
  last_stream_tick_ = now;

  auto jpeg = CaptureLatestJpeg(/*wait_ms=*/0, kStreamMaxWidth);
  if (jpeg.empty()) return;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    pending_jpeg_ = std::move(jpeg);  // purana unsent frame replace (backpressure)
  }
  if (window_handle_ != nullptr && !frame_post_pending_.exchange(true)) {
    PostMessage(window_handle_, kFrameMessage, 0, 0);
  }
}

// Platform thread.
void ScreenCaptureManager::FlushPendingFrame() {
  frame_post_pending_ = false;
  std::vector<uint8_t> jpeg;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    jpeg.swap(pending_jpeg_);
  }
  if (jpeg.empty() || !streaming_ || !event_sink_) return;
  event_sink_->Success(flutter::EncodableValue(Base64EncodePadded(jpeg)));
}
