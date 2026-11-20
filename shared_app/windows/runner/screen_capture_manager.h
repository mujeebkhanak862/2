// screen_capture_manager.h
#ifndef DEVICE_AGENT_SCREEN_CAPTURE_MANAGER_H_
#define DEVICE_AGENT_SCREEN_CAPTURE_MANAGER_H_

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>

#include <windows.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <vector>

// Native side of `ChannelNames.screenCapture` + `ChannelNames.screenLiveStream`
// for Windows, using the Windows.Graphics.Capture API (Win10 1903+, built
// on C++/WinRT). Matches Android's ScreenCaptureHandler.kt /
// ScreenCaptureService.kt contract: requestPermission / captureScreenshot /
// stopStream + a continuous JPEG-frame EventChannel.
class ScreenCaptureManager {
 public:
  static void Register(flutter::FlutterEngine* engine, HWND window_handle);
  ~ScreenCaptureManager();

  // Item 83: frame arrived (thread-pool) -> window message -> yahan (platform
  // thread) event sink par bheja jata hai. Sirf subclass proc call karta hai.
  void FlushPendingFrame();

 private:
  ScreenCaptureManager(flutter::FlutterEngine* engine, HWND window_handle);

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Windows.Graphics.Capture ke liye koi separate "consent dialog" nahi
  // hota jaisa Android MediaProjection mein — jab pehli baar capture start
  // hoti hai to OS khud ek yellow border/indicator dikhata hai
  // (Section 6.6 item 2 ka Windows-equivalent). requestPermission yahan
  // sirf capture-session ready karta hai (device/driver support check).
  bool EnsureSessionStarted();
  std::vector<uint8_t> CaptureLatestJpeg(int wait_ms, int max_width);
  void TeardownSession();
  void StartStream();
  void StopStream();
  void OnFrameArrived(
      winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool const& sender,
      winrt::Windows::Foundation::IInspectable const&);

  HWND window_handle_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;

  winrt::Windows::Graphics::Capture::GraphicsCaptureItem capture_item_{nullptr};
  winrt::Windows::Graphics::Capture::GraphicsCaptureSession capture_session_{nullptr};
  winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool frame_pool_{nullptr};
  winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice d3d_device_{nullptr};

  std::atomic<bool> streaming_{false};
  std::atomic<bool> session_ready_{false};
  std::atomic<bool> capture_started_{false};
  std::mutex mutex_;          // session lifecycle
  std::mutex capture_mutex_;  // frame pool access (platform thread + frame thread)

  // Stream frames: frame thread JPEG banata hai, platform thread bhejta hai.
  std::mutex pending_mutex_;
  std::vector<uint8_t> pending_jpeg_;
  std::atomic<bool> frame_post_pending_{false};
  ULONGLONG last_stream_tick_ = 0;
  winrt::event_token frame_token_{};
};

#endif  // DEVICE_AGENT_SCREEN_CAPTURE_MANAGER_H_
