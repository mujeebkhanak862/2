// input_manager.cpp
#include "input_manager.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <chrono>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace {
constexpr char kChannel[] = "device_agent/input";

// Pixel coordinates ko SendInput ke absolute-mouse range (0..65535,
// poore virtual desktop ke against) mein convert karta hai — taaki
// multi-monitor setups par bhi sahi jagah click ho.
POINT ToAbsolute(double x, double y) {
  int vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
  int vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
  int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
  int vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);

  POINT p;
  p.x = static_cast<LONG>(((x - vx) * 65535) / (vw > 0 ? vw : 1));
  p.y = static_cast<LONG>(((y - vy) * 65535) / (vh > 0 ? vh : 1));
  return p;
}

bool SendMouseMoveAbsolute(double x, double y) {
  POINT p = ToAbsolute(x, y);
  INPUT input{};
  input.type = INPUT_MOUSE;
  input.mi.dx = p.x;
  input.mi.dy = p.y;
  input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
  // Item 83: SendInput ka return value pehle ignore hota tha. UIPI (elevated
  // window ke saamne) ya secure desktop par yeh 0 deta hai — aur hum
  // chup-chaap "success" bata dete the.
  return SendInput(1, &input, sizeof(INPUT)) == 1;
}

bool SendMouseButton(bool down, bool left = true) {
  INPUT input{};
  input.type = INPUT_MOUSE;
  input.mi.dwFlags = left
      ? (down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP)
      : (down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP);
  return SendInput(1, &input, sizeof(INPUT)) == 1;
}

bool Tap(double x, double y) {
  if (!SendMouseMoveAbsolute(x, y)) return false;
  if (!SendMouseButton(true)) return false;
  return SendMouseButton(false);
}

bool Swipe(double x1, double y1, double x2, double y2, int duration_ms) {
  // Item 83: yeh platform (UI) thread par sleep karta hai — lamba duration
  // poori app freeze kar sakta tha, isliye cap.
  if (duration_ms < 0) duration_ms = 0;
  if (duration_ms > 2000) duration_ms = 2000;
  const int steps = 20;
  bool ok = SendMouseMoveAbsolute(x1, y1);
  if (!ok) return false;
  if (!SendMouseButton(true)) return false;
  for (int i = 1; i <= steps; i++) {
    double t = static_cast<double>(i) / steps;
    double x = x1 + (x2 - x1) * t;
    double y = y1 + (y2 - y1) * t;
    ok = SendMouseMoveAbsolute(x, y) && ok;
    std::this_thread::sleep_for(
        std::chrono::milliseconds(duration_ms / steps));
  }
  // Button hamesha release karo (warna mouse "pressed" atka rah jata).
  bool released = SendMouseButton(false);
  return ok && released;
}

// UTF-16 codepoints ke liye KEYEVENTF_UNICODE — layout-independent, isliye
// kisi bhi language/keyboard layout par kaam karta hai.
bool TypeText(const std::wstring& text) {
  bool all_ok = true;
  for (wchar_t ch : text) {
    INPUT inputs[2]{};
    inputs[0].type = INPUT_KEYBOARD;
    inputs[0].ki.wScan = ch;
    inputs[0].ki.dwFlags = KEYEVENTF_UNICODE;

    inputs[1].type = INPUT_KEYBOARD;
    inputs[1].ki.wScan = ch;
    inputs[1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;

    if (SendInput(2, inputs, sizeof(INPUT)) != 2) all_ok = false;
    // 10ms/char pe 10000 chars = 100s UI freeze tha; 2ms kaafi hai.
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  return all_ok;
}

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return L"";
  int size = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                  static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring wide(size, 0);
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()),
                       wide.data(), size);
  return wide;
}
}  // namespace

void InputManager::Register(flutter::FlutterEngine* engine, HWND) {
  auto channel = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kChannel,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [channel](const flutter::MethodCall<flutter::EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments());

        auto get_double = [&](const char* key, double def = 0.0) -> double {
          if (!args) return def;
          auto it = args->find(flutter::EncodableValue(key));
          if (it == args->end()) return def;
          if (auto v = std::get_if<double>(&it->second)) return *v;
          if (auto v = std::get_if<int>(&it->second)) return *v;
          return def;
        };

        if (call.method_name() == "tap") {
          result->Success(flutter::EncodableValue(Tap(get_double("x"), get_double("y"))));
        } else if (call.method_name() == "swipe") {
          result->Success(flutter::EncodableValue(
              Swipe(get_double("x1"), get_double("y1"), get_double("x2"),
                    get_double("y2"),
                    static_cast<int>(get_double("duration_ms", 200)))));
        } else if (call.method_name() == "typeText") {
          std::string text;
          if (args) {
            auto it = args->find(flutter::EncodableValue("text"));
            if (it != args->end()) {
              if (auto v = std::get_if<std::string>(&it->second)) text = *v;
            }
          }
          result->Success(flutter::EncodableValue(TypeText(Utf8ToWide(text))));
        } else if (call.method_name() == "isEnabled") {
          // Windows mein koi separate enable-toggle nahi hoti — desktop
          // app apne session mein hamesha input bhej sakti hai.
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "openAccessibilitySettings") {
          // Android-only concept — Windows par no-op (already enabled).
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}
