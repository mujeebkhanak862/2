// lock_state_manager.cpp
#include "lock_state_manager.h"

#include <flutter/standard_method_codec.h>

namespace {
constexpr char kMethodChannel[] = "device_agent/lock_state";
constexpr char kEventChannel[] = "device_agent/lock_state_events";
}  // namespace

LockStateManager* LockStateManager::active_instance_ = nullptr;

void LockStateManager::Register(flutter::FlutterEngine* engine) {
  // Deliberately leaked (lives for the process lifetime) — same pattern
  // as the other managers (e.g. ScreenCaptureManager::Register).
  new LockStateManager(engine);
}

LockStateManager::LockStateManager(flutter::FlutterEngine* engine) {
  active_instance_ = this;

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
            // Listener attach hote hi turant current value bhejte hain
            // (Android LockStateHandler ke jaisa hi contract), phir
            // polling shuru karte hain future changes ke liye.
            last_state_ = ComputeState();
            event_sink_->Success(flutter::EncodableValue(last_state_));
            StartPolling();
            return nullptr;
          },
          [this](const flutter::EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            StopPolling();
            event_sink_ = nullptr;
            return nullptr;
          }));
}

LockStateManager::~LockStateManager() {
  StopPolling();
  if (active_instance_ == this) active_instance_ = nullptr;
}

void LockStateManager::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "currentState") {
    result->Success(flutter::EncodableValue(ComputeState()));
  } else {
    result->NotImplemented();
  }
}

std::string LockStateManager::ComputeState() {
  // Dekhein header comment — `OpenInputDesktop` fail (ACCESS_DENIED) ho
  // to matlab secure desktop (lock screen) active hai.
  HDESK desktop = OpenInputDesktop(0, FALSE, DESKTOP_SWITCHDESKTOP);
  if (desktop == nullptr) {
    return "ONLINE_LOCKED";
  }
  CloseDesktop(desktop);
  return "ONLINE_UNLOCKED";
}

void LockStateManager::StartPolling() {
  if (timer_id_ != 0) return;  // already polling
  timer_id_ = SetTimer(nullptr, 0, kPollIntervalMs, &LockStateManager::TimerProc);
}

void LockStateManager::StopPolling() {
  if (timer_id_ == 0) return;
  KillTimer(nullptr, timer_id_);
  timer_id_ = 0;
}

void CALLBACK LockStateManager::TimerProc(HWND /*hwnd*/, UINT /*message*/,
                                           UINT_PTR /*timer_id*/,
                                           DWORD /*elapsed_ms*/) {
  LockStateManager* self = active_instance_;
  if (self == nullptr || !self->event_sink_) return;

  const std::string state = ComputeState();
  // Sirf tab bhejte hain jab asal mein badla ho — server/UI ko har 2
  // second ek hi state repeat karke spam nahi karte.
  if (state != self->last_state_) {
    self->last_state_ = state;
    self->event_sink_->Success(flutter::EncodableValue(state));
  }
}
