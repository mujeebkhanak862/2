// clipboard_manager.cpp
#include "clipboard_manager.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

namespace {
constexpr char kChannel[] = "device_agent/clipboard";

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return L"";
  int size = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                  static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring wide(size, 0);
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()),
                       wide.data(), size);
  return wide;
}

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return "";
  int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                  static_cast<int>(wide.size()), nullptr, 0,
                                  nullptr, nullptr);
  std::string utf8(size, 0);
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()),
                       utf8.data(), size, nullptr, nullptr);
  return utf8;
}

bool ReadClipboardText(HWND owner, std::string* out) {
  if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) return false;
  if (!OpenClipboard(owner)) return false;

  HANDLE handle = GetClipboardData(CF_UNICODETEXT);
  if (handle == nullptr) {
    CloseClipboard();
    return false;
  }
  wchar_t* text = static_cast<wchar_t*>(GlobalLock(handle));
  if (text == nullptr) {
    CloseClipboard();
    return false;
  }
  *out = WideToUtf8(text);
  GlobalUnlock(handle);
  CloseClipboard();
  return true;
}

bool WriteClipboardText(HWND owner, const std::string& text) {
  if (!OpenClipboard(owner)) return false;
  EmptyClipboard();

  std::wstring wide = Utf8ToWide(text);
  size_t bytes = (wide.size() + 1) * sizeof(wchar_t);

  HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (mem == nullptr) {
    CloseClipboard();
    return false;
  }
  void* dest = GlobalLock(mem);
  if (dest == nullptr) {  // item 83: null deref se bachne ke liye
    GlobalFree(mem);
    CloseClipboard();
    return false;
  }
  memcpy(dest, wide.c_str(), bytes);
  GlobalUnlock(mem);

  // SetClipboardData succeed hote hi `mem` ka ownership clipboard le leta
  // hai — humein khud free nahi karna.
  bool ok = SetClipboardData(CF_UNICODETEXT, mem) != nullptr;
  if (!ok) GlobalFree(mem);

  CloseClipboard();
  return ok;
}
}  // namespace

void ClipboardManagerNative::Register(flutter::FlutterEngine* engine,
                                       HWND window_handle) {
  auto channel = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kChannel,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [channel, window_handle](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "readText") {
          std::string text;
          if (ReadClipboardText(window_handle, &text)) {
            result->Success(flutter::EncodableValue(text));
          } else {
            result->Success();  // clipboard empty ya text nahi — null
          }
        } else if (call.method_name() == "writeText") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          std::string text;
          if (args) {
            auto it = args->find(flutter::EncodableValue("text"));
            if (it != args->end()) {
              if (auto v = std::get_if<std::string>(&it->second)) text = *v;
            }
          }
          bool ok = WriteClipboardText(window_handle, text);
          result->Success(flutter::EncodableValue(ok));
        } else {
          result->NotImplemented();
        }
      });
}
