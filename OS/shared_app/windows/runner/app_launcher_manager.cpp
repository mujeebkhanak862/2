// app_launcher_manager.cpp
#include "app_launcher_manager.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <shlobj.h>
#include <shellapi.h>

#include <filesystem>
#include <memory>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {
constexpr char kChannel[] = "device_agent/app_launcher";

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

bool IsKnownStartMenuApp(const std::string& identifier);

// Item 12 (security fix): pehle `ShellExecuteW` kisi bhi path/URL/exe ko
// chala deta tha (`apps` scope = arbitrary execution). Ab sirf woh
// identifiers (Start Menu .lnk paths) allowed hain jo `listInstalledApps`
// ne khud diye the.
bool LaunchByPath(const std::string& identifier) {
  if (!IsKnownStartMenuApp(identifier)) return false;
  std::wstring wide_path = Utf8ToWide(identifier);
  HINSTANCE result = ShellExecuteW(nullptr, L"open", wide_path.c_str(),
                                    nullptr, nullptr, SW_SHOWNORMAL);
  return reinterpret_cast<INT_PTR>(result) > 32;  // per ShellExecute docs
}

void CollectShortcuts(const fs::path& dir, std::vector<std::pair<std::string, std::string>>* out) {
  std::error_code ec;
  if (!fs::exists(dir, ec)) return;
  for (auto& entry : fs::recursive_directory_iterator(
           dir, fs::directory_options::skip_permission_denied, ec)) {
    if (entry.is_regular_file() && entry.path().extension() == L".lnk") {
      std::string name = WideToUtf8(entry.path().stem().wstring());
      std::string path = WideToUtf8(entry.path().wstring());
      out->emplace_back(path, name);
    }
  }
}

std::vector<std::pair<std::string, std::string>> ListStartMenuApps() {
  std::vector<std::pair<std::string, std::string>> apps;

  for (auto folder_id : {FOLDERID_CommonPrograms, FOLDERID_Programs}) {
    wchar_t* path = nullptr;
    if (SUCCEEDED(SHGetKnownFolderPath(folder_id, 0, nullptr, &path))) {
      CollectShortcuts(fs::path(path), &apps);
      CoTaskMemFree(path);
    }
  }
  return apps;
}

bool IsKnownStartMenuApp(const std::string& identifier) {
  if (identifier.empty()) return false;
  const std::wstring wanted = Utf8ToWide(identifier);
  for (const auto& entry : ListStartMenuApps()) {
    if (_wcsicmp(Utf8ToWide(entry.first).c_str(), wanted.c_str()) == 0) {
      return true;
    }
  }
  return false;
}
}  // namespace

void AppLauncherManager::Register(flutter::FlutterEngine* engine) {
  auto channel = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kChannel,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [channel](const flutter::MethodCall<flutter::EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        auto get_string = [&](const char* key) -> std::string {
          if (!args) return "";
          auto it = args->find(flutter::EncodableValue(key));
          if (it == args->end()) return "";
          if (auto v = std::get_if<std::string>(&it->second)) return *v;
          return "";
        };

        if (call.method_name() == "launchApp") {
          bool ok = LaunchByPath(get_string("identifier"));
          if (ok) {
            result->Success(flutter::EncodableValue(true));
          } else {
            result->Error("LAUNCH_FAILED", "App launch nahi ho saki");
          }
        } else if (call.method_name() == "isAppInstalled") {
          // Item 12: sirf listed Start Menu apps "installed" maane jaate hain.
          result->Success(flutter::EncodableValue(
              IsKnownStartMenuApp(get_string("identifier"))));
        } else if (call.method_name() == "listInstalledApps") {
          flutter::EncodableList list;
          for (auto& [path, name] : ListStartMenuApps()) {
            flutter::EncodableMap m;
            m[flutter::EncodableValue("identifier")] = flutter::EncodableValue(path);
            m[flutter::EncodableValue("name")] = flutter::EncodableValue(name);
            list.push_back(flutter::EncodableValue(m));
          }
          result->Success(flutter::EncodableValue(list));
        } else {
          result->NotImplemented();
        }
      });
}
