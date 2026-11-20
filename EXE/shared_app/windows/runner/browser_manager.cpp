// browser_manager.cpp
#include "browser_manager.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <shlobj.h>

#include <cstdlib>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {
constexpr char kChannel[] = "device_agent/browser";

// Registry "App Paths" se browser ka installed location dhoondta hai —
// yeh Chrome/Edge dono ke liye reliable, version-independent tareeka hai
// (hardcoded "Program Files" paths se behtar, kyunki wahan version-specific
// subfolder ho sakta hai ya user ne custom location choose ki ho).
// Item 80: pehle sirf `HKLM\\...\\App Paths` dekha jata tha. Per-user
// installs `HKCU` mein hote hain, aur kuch installs registry mein hote hi
// nahi — isliye HKLM + HKCU + well-known Program Files paths.
std::wstring ReadAppPath(HKEY root, const std::wstring& exe_name) {
  std::wstring key = L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\" + exe_name;
  HKEY hKey;
  if (RegOpenKeyExW(root, key.c_str(), 0, KEY_READ, &hKey) != ERROR_SUCCESS) {
    return L"";
  }
  wchar_t path[MAX_PATH];
  DWORD size = sizeof(path) - sizeof(wchar_t);
  DWORD type = 0;
  std::wstring result;
  if (RegQueryValueExW(hKey, nullptr, nullptr, &type,
                       reinterpret_cast<LPBYTE>(path), &size) == ERROR_SUCCESS &&
      (type == REG_SZ || type == REG_EXPAND_SZ)) {
    path[size / sizeof(wchar_t)] = L'\0';
    result = path;
  }
  RegCloseKey(hKey);
  // Registry value kabhi quotes ke saath hoti hai.
  if (result.size() >= 2 && result.front() == L'"' && result.back() == L'"') {
    result = result.substr(1, result.size() - 2);
  }
  return result;
}

std::wstring FindBrowserExecutable() {
  for (const wchar_t* exe_name : {L"chrome.exe", L"msedge.exe"}) {
    for (HKEY root : {HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER}) {
      std::wstring p = ReadAppPath(root, exe_name);
      std::error_code ec;
      if (!p.empty() && fs::exists(p, ec)) return p;
    }
  }
  // Registry mein nahi mila — standard install locations.
  std::vector<fs::path> candidates;
  for (const wchar_t* env : {L"PROGRAMFILES", L"PROGRAMFILES(X86)", L"LOCALAPPDATA"}) {
    wchar_t* base = nullptr;
    size_t len = 0;
    if (_wdupenv_s(&base, &len, env) == 0 && base != nullptr) {
      fs::path root(base);
      free(base);
      candidates.push_back(root / L"Google" / L"Chrome" / L"Application" / L"chrome.exe");
      candidates.push_back(root / L"Microsoft" / L"Edge" / L"Application" / L"msedge.exe");
    }
  }
  for (const auto& c : candidates) {
    std::error_code ec;
    if (fs::exists(c, ec)) return c.wstring();
  }
  return L"";
}

fs::path BrowserProfileDir() {
  wchar_t* local_app_data = nullptr;
  fs::path root;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                      &local_app_data))) {
    root = fs::path(local_app_data) / L"DeviceAgent" / L"browser-profile";
    CoTaskMemFree(local_app_data);
  } else {
    root = fs::temp_directory_path() / L"DeviceAgentBrowserProfile";
  }
  std::error_code ec;
  fs::create_directories(root, ec);
  return root;
}

bool LaunchBrowserWithDebugPort(int port) {
  std::wstring exe = FindBrowserExecutable();
  if (exe.empty()) return false;

  std::wstring cmd = L"\"" + exe + L"\" --remote-debugging-port=" +
                      std::to_wstring(port) + L" --user-data-dir=\"" +
                      BrowserProfileDir().wstring() + L"\" --no-first-run";

  STARTUPINFOW si{};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi{};

  // CreateProcessW cmd line ko modify kar sakta hai, isliye mutable buffer
  // chahiye.
  std::vector<wchar_t> cmd_buf(cmd.begin(), cmd.end());
  cmd_buf.push_back(L'\0');

  bool ok = CreateProcessW(nullptr, cmd_buf.data(), nullptr, nullptr, FALSE,
                            0, nullptr, nullptr, &si, &pi);
  if (ok) {
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
  }
  return ok;
}
}  // namespace

void BrowserManager::Register(flutter::FlutterEngine* engine) {
  auto channel = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kChannel,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [channel](const flutter::MethodCall<flutter::EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "launchDesktopBrowser") {
          // 9333 — `BrowserBridge.desktopDebugPort` (Dart) se match hona
          // chahiye.
          bool ok = LaunchBrowserWithDebugPort(9333);
          if (ok) {
            result->Success(flutter::EncodableValue(true));
          } else {
            result->Error("LAUNCH_FAILED",
                           "Chrome/Edge nahi mila ya launch nahi ho saka");
          }
        } else {
          // findAndClick/findAndType/getVisibleText/openUrl — yeh sab
          // Android-only semantic methods hain (koi CDP-equivalent nahi
          // hona chahiye yahan; Windows/Linux `CdpClient` seedha use
          // karte hain).
          result->NotImplemented();
        }
      });
}
