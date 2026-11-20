// files_manager.cpp
#include "files_manager.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <shobjidl.h>
#include <wincrypt.h>
#include <wrl/client.h>

#include <atomic>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace fs = std::filesystem;

namespace {

// Item 14 (native layer): server + Dart dispatcher ke baad teesri,
// independent line of defence. List `control_api/lib/validation/
// data_channel_security.dart` aur `lib/protocol/device_policy.dart` se
// sync rakhni hai.
bool IsDangerousFileName(const std::string& path) {
  static const char* const kDangerous[] = {
    ".exe",
    ".msi",
    ".msix",
    ".appx",
    ".bat",
    ".cmd",
    ".com",
    ".scr",
    ".pif",
    ".ps1",
    ".psm1",
    ".vbs",
    ".vbe",
    ".wsf",
    ".wsh",
    ".hta",
    ".js",
    ".jse",
    ".lnk",
    ".reg",
    ".cpl",
    ".msc",
    ".gadget",
    ".inf",
    ".sh",
    ".bash",
    ".zsh",
    ".run",
    ".bin",
    ".py",
    ".pl",
    ".rb",
    ".desktop",
    ".appimage",
    ".deb",
    ".rpm",
    ".apk",
    ".aab",
    ".dex",
    ".dll",
    ".so",
    ".dylib",
    ".sys",
    ".jar"
  };
  size_t slash = path.find_last_of("/\\");
  std::string name = slash == std::string::npos ? path : path.substr(slash + 1);
  for (auto& c : name) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
  }
  // NTFS ADS: har ':' -separated part alag check hota hai.
  size_t start = 0;
  while (start <= name.size()) {
    size_t colon = name.find(':', start);
    std::string part = name.substr(
        start, colon == std::string::npos ? std::string::npos : colon - start);
    while (!part.empty() && (part.back() == '.' || part.back() == ' ')) {
      part.pop_back();
    }
    for (const char* ext : kDangerous) {
      std::string e(ext);
      if (part.size() >= e.size() &&
          part.compare(part.size() - e.size(), e.size(), e) == 0) {
        return true;
      }
    }
    if (colon == std::string::npos) break;
    start = colon + 1;
  }
  return false;
}

constexpr char kChannel[] = "device_agent/files";

// Default sandbox root — %LOCALAPPDATA%\DeviceAgent\sandbox. Doc ke
// "allowed-root filesystem sandbox" (Section 6.7 file-list comment) ka
// Windows-equivalent; koi extra Windows permission nahi chahiye is
// folder ke liye kyunki yeh already user-writable hai.
fs::path SandboxRoot() {
  wchar_t* local_app_data = nullptr;
  fs::path root;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                      &local_app_data))) {
    root = fs::path(local_app_data) / L"DeviceAgent" / L"sandbox";
    CoTaskMemFree(local_app_data);
  } else {
    root = fs::temp_directory_path() / L"DeviceAgentSandbox";
  }
  std::error_code ec;
  fs::create_directories(root, ec);
  return root;
}

// Path traversal protection: relative_path ko sandbox root ke andar
// resolve karta hai, agar bahar nikal jaaye to empty path return karta
// hai (caller ise "forbidden" treat kare).
//
// User `pickDirectory()` se jo folder choose kare, uska absolute path
// yahan "granted roots" mein add ho jaata hai — taaki poore device
// storage ko bhi (jaise C:\ ya koi bhi user-chuni hui drive/folder)
// isi Files capability se browse kiya ja sake, sandbox root tak
// limited rahe bina. Yeh list sirf is process ke lifetime tak rehti
// hai (persist nahi hoti) — har naye session mein dobara pick karna
// padega, jo intentional hai (Section 3 ke scoped-permission spirit
// ke mutabiq, ek baar di gayi broad access hamesha ke liye silently
// yaad nahi rehni chahiye).
// Item 81: IO cap (10 MiB — server ki upload limit ke barabar).
constexpr uintmax_t kMaxFileBytes = 10 * 1024 * 1024;

fs::path GrantedRootsFile() {
  return SandboxRoot().parent_path() / L"granted_roots.txt";
}

// Item 82: pehle granted roots sirf memory mein the (upar wala comment
// purana tha) — ab ek UTF-8 text file (ek path per line) mein persist hote
// hain. Dhyan: user ne explicitly folder chuna tha, aur Permission Center
// se dobara chunke badla/hataya ja sakta hai.
std::vector<fs::path> LoadGrantedRoots() {
  std::vector<fs::path> roots;
  std::ifstream in(GrantedRootsFile(), std::ios::binary);
  std::string line;
  while (std::getline(in, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty()) continue;
    std::error_code ec;
    fs::path p = fs::u8path(line);
    if (fs::is_directory(p, ec)) roots.push_back(p);  // ab nahi bachi to skip
  }
  return roots;
}

void SaveGrantedRoots(const std::vector<fs::path>& roots) {
  std::ofstream out(GrantedRootsFile(), std::ios::binary | std::ios::trunc);
  for (const auto& r : roots) {
    out << r.u8string() << "\n";
  }
}

std::vector<fs::path>& GrantedRoots() {
  static std::vector<fs::path> roots = LoadGrantedRoots();
  return roots;
}

// `weakly_canonical` throw kar sakta hai — native crash ki jagah empty path.
fs::path SafeCanonical(const fs::path& p) {
  std::error_code ec;
  fs::path c = fs::weakly_canonical(p, ec);
  return ec ? fs::path() : c;
}

// **Real bug jo yahan tha (Android `FilesHandler.kt` mein bhi wahi bug
// tha, dono jagah fix kiya)**: neeche do jagah bare string-prefix
// comparison tha (`compare(0, root_str.size(), root_str) == 0`), boundary
// check ke bina. Iska matlab: agar sandbox root ho
// `C:\...\DeviceAgent\sandbox`, to ek SIBLING folder jiska naam bhi isi
// prefix se shuru ho — jaise `C:\...\DeviceAgent\sandbox_other` — is
// check ko galti se pass kar jaata, kyunki string-wise woh prefix match
// kar raha hota hai, chahe woh asal mein us directory ke andar na ho.
// Yeh helper sahi boundary check karta hai: target ya to root ke
// EXACTLY barabar ho, ya root + path-separator se shuru ho.
bool IsPathUnder(const std::wstring& target_str, const std::wstring& root_str) {
  if (target_str == root_str) return true;
  if (target_str.size() <= root_str.size()) return false;
  if (target_str.compare(0, root_str.size(), root_str) != 0) return false;
  wchar_t next = target_str[root_str.size()];
  return next == L'\\' || next == L'/';
}

fs::path ResolveSandboxed(const std::string& relative_path) {
  fs::path root = SafeCanonical(SandboxRoot());
  if (root.empty()) return {};

  // UTF-8 se path (narrow `fs::path(std::string)` ANSI code page use
  // karta tha — non-ASCII filenames toot'te the).
  fs::path requested = fs::u8path(relative_path);
  if (requested.is_absolute()) {
    // Absolute path — sirf tab allowed jab woh sandbox root ke andar ho
    // YA user ne explicitly pickDirectory() se grant kiya ho.
    fs::path target = SafeCanonical(requested);
    if (target.empty()) return {};
    auto target_str = target.wstring();

    auto is_under = [&](const fs::path& allowed_root) {
      fs::path c = SafeCanonical(allowed_root);
      return !c.empty() && IsPathUnder(target_str, c.wstring());
    };

    if (is_under(root)) return target;
    for (auto& granted : GrantedRoots()) {
      if (is_under(granted)) return target;
    }
    return {};
  }

  // Relative path — hamesha sandbox root ke andar resolve hota hai.
  fs::path target = SafeCanonical(root / requested);
  if (target.empty() || !IsPathUnder(target.wstring(), root.wstring())) {
    return {};
  }
  return target;
}

// Item 81: Android jaisa consistent `path` — sandbox ke andar ho to root ke
// relative, warna (granted root) absolute.
std::string PathToUtf8(const fs::path& p) { return p.u8string(); }

std::string DisplayPath(const fs::path& p) {
  fs::path root = SafeCanonical(SandboxRoot());
  fs::path c = SafeCanonical(p);
  if (!root.empty() && !c.empty() && IsPathUnder(c.wstring(), root.wstring())) {
    std::error_code ec;
    fs::path rel = fs::relative(c, root, ec);
    if (!ec) return rel.u8string();
  }
  return p.u8string();
}

std::string Base64Encode(const std::vector<unsigned char>& bytes) {
  DWORD out_len = 0;
  CryptBinaryToStringA(bytes.data(), static_cast<DWORD>(bytes.size()),
                        CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr,
                        &out_len);
  std::string out(out_len, '\0');
  CryptBinaryToStringA(bytes.data(), static_cast<DWORD>(bytes.size()),
                        CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, out.data(),
                        &out_len);
  out.resize(out_len > 0 ? out_len - 1 : 0);  // trailing NUL trim
  return out;
}

// Item 81: invalid base64 par pehle chup-chaap ghalat data likh kar `true`
// milta tha. Ab `false` return hota hai.
bool Base64Decode(const std::string& b64, std::vector<unsigned char>* out) {
  DWORD out_len = 0;
  if (!CryptStringToBinaryA(b64.c_str(), static_cast<DWORD>(b64.size()),
                            CRYPT_STRING_BASE64, nullptr, &out_len, nullptr,
                            nullptr)) {
    return false;
  }
  out->assign(out_len, 0);
  if (!CryptStringToBinaryA(b64.c_str(), static_cast<DWORD>(b64.size()),
                            CRYPT_STRING_BASE64, out->data(), &out_len,
                            nullptr, nullptr)) {
    return false;
  }
  out->resize(out_len);
  return true;
}

// Native folder picker — IFileDialog with FOS_PICKFOLDERS, broader
// user-granted access ke liye (sandbox root se bahar).
// ==== BEGIN IO CORE ====
// Item 81: file I/O ka platform-neutral core. Yeh block
// windows/runner/files_manager.cpp aur linux/files_manager.cc mein
// bilkul identical hai (dono jagah saath badlo). Yeh functions UI thread
// par nahi, worker thread par chalte hain; MethodResult ko jawab sirf
// UI thread se diya jata hai (neeche platform-specific dispatcher).
struct IoEntry {
  std::string name;
  bool is_dir = false;
  int64_t size = 0;
  std::string path;
};

struct IoOutcome {
  enum class Kind { kError, kList, kString, kBool };
  Kind kind = Kind::kError;
  std::string code;
  std::string message;
  std::string text;
  bool flag = false;
  std::vector<IoEntry> entries;

  static IoOutcome Error(const std::string& c, const std::string& m) {
    IoOutcome o;
    o.code = c;
    o.message = m;
    return o;
  }
  static IoOutcome Text(const std::string& t) {
    IoOutcome o;
    o.kind = Kind::kString;
    o.text = t;
    return o;
  }
  static IoOutcome Bool(bool b) {
    IoOutcome o;
    o.kind = Kind::kBool;
    o.flag = b;
    return o;
  }
};

// Ek waqt mein ek hi file operation (pehle UI thread par serial the —
// ordering/atomicity ka behaviour same rakhne ke liye).
std::mutex& IoMutex() {
  static std::mutex m;
  return m;
}

IoOutcome DoListDirectory(const fs::path& dir) {
  std::lock_guard<std::mutex> lock(IoMutex());
  std::error_code ec;
  if (dir.empty() || !fs::is_directory(dir, ec)) {
    return IoOutcome::Error("NOT_FOUND",
                            "Directory nahi mili ya sandbox se bahar hai");
  }
  IoOutcome out;
  out.kind = IoOutcome::Kind::kList;
  // Non-throwing overloads (`ec` ke saath) — ek unreadable entry poori
  // native process ko crash nahi karti.
  fs::directory_iterator it(dir, fs::directory_options::skip_permission_denied, ec);
  for (fs::directory_iterator end; !ec && it != end; it.increment(ec)) {
    std::error_code e2;
    const auto& entry = *it;
    IoEntry e;
    e.is_dir = entry.is_directory(e2);
    bool is_file = !e2 && entry.is_regular_file(e2);
    uintmax_t size = 0;
    if (is_file) {
      size = entry.file_size(e2);
      if (e2) size = 0;
    }
    e.size = static_cast<int64_t>(size);
    e.name = PathToUtf8(entry.path().filename());
    e.path = DisplayPath(entry.path());
    out.entries.push_back(std::move(e));
  }
  return out;
}

IoOutcome DoReadFile(const fs::path& file) {
  std::lock_guard<std::mutex> lock(IoMutex());
  std::error_code ec;
  if (file.empty() || !fs::is_regular_file(file, ec)) {
    return IoOutcome::Error("NOT_FOUND", "File nahi mili");
  }
  uintmax_t fsize = fs::file_size(file, ec);
  if (ec) return IoOutcome::Error("READ_FAILED", "File size nahi mil saka");
  if (fsize > kMaxFileBytes) {
    return IoOutcome::Error("TOO_LARGE", "File 10 MiB se badi hai");
  }
  std::ifstream in(file, std::ios::binary);
  if (!in) return IoOutcome::Error("READ_FAILED", "File open nahi hui");
  std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(in)),
                                   std::istreambuf_iterator<char>());
  return IoOutcome::Text(Base64Encode(bytes));
}

IoOutcome DoWriteFile(const fs::path& file, const std::string& b64) {
  // Decode lock se pehle — heavy CPU kaam, doosre operations ko na roke.
  std::vector<unsigned char> bytes;
  if (!Base64Decode(b64, &bytes)) {
    return IoOutcome::Error("INVALID_DATA", "Data valid base64 nahi hai");
  }
  if (bytes.size() > kMaxFileBytes) {
    return IoOutcome::Error("TOO_LARGE", "Data 10 MiB se bada hai");
  }
  std::lock_guard<std::mutex> lock(IoMutex());
  std::error_code ec;
  fs::create_directories(file.parent_path(), ec);
  std::ofstream out(file, std::ios::binary | std::ios::trunc);
  if (!out) return IoOutcome::Error("WRITE_FAILED", "File open/create nahi ho saki");
  out.write(reinterpret_cast<const char*>(bytes.data()),
            static_cast<std::streamsize>(bytes.size()));
  out.flush();
  if (!out) return IoOutcome::Error("WRITE_FAILED", "Write complete nahi hua");
  return IoOutcome::Bool(true);
}

IoOutcome DoDeleteFile(const fs::path& file) {
  std::lock_guard<std::mutex> lock(IoMutex());
  std::error_code ec;
  bool ok = !file.empty() && fs::remove(file, ec);
  return IoOutcome::Bool(ok);
}

// Zyada concurrent requests par thread-explosion nahi: cap ke upar
// "BUSY" error (Dart side retry kar sakta hai).
constexpr int kMaxInflightIo = 16;
// ==== END IO CORE ====


// ---- Windows dispatcher: worker thread -> UI thread --------------------
// Flutter ka MethodResult sirf platform (UI) thread se call hona chahiye.
// Worker kaam karke result ek queue mein daalta hai aur window ko custom
// message bhejta hai; `FlutterWindow::MessageHandler` use
// `FilesManager::DrainMainThreadTasks()` se UI thread par chalata hai.
std::mutex g_main_mutex;
std::deque<std::function<void()>> g_main_tasks;
HWND g_main_hwnd = nullptr;
std::atomic<int> g_inflight{0};

bool PostToMain(std::function<void()> fn) {
  HWND hwnd = g_main_hwnd;
  if (hwnd == nullptr) return false;
  {
    std::lock_guard<std::mutex> lock(g_main_mutex);
    g_main_tasks.push_back(std::move(fn));
  }
  return PostMessage(hwnd, FilesManager::kMainThreadMessage, 0, 0) != 0;
}

using FilesResult = flutter::MethodResult<flutter::EncodableValue>;

void ReplyOutcome(FilesResult& r, const IoOutcome& o) {
  switch (o.kind) {
    case IoOutcome::Kind::kError:
      r.Error(o.code, o.message);
      break;
    case IoOutcome::Kind::kString:
      r.Success(flutter::EncodableValue(o.text));
      break;
    case IoOutcome::Kind::kBool:
      r.Success(flutter::EncodableValue(o.flag));
      break;
    case IoOutcome::Kind::kList: {
      flutter::EncodableList entries;
      for (const auto& e : o.entries) {
        flutter::EncodableMap m;
        m[flutter::EncodableValue("name")] = flutter::EncodableValue(e.name);
        m[flutter::EncodableValue("isDirectory")] = flutter::EncodableValue(e.is_dir);
        m[flutter::EncodableValue("size")] = flutter::EncodableValue(e.size);
        m[flutter::EncodableValue("path")] = flutter::EncodableValue(e.path);
        entries.push_back(flutter::EncodableValue(m));
      }
      r.Success(flutter::EncodableValue(entries));
      break;
    }
  }
}

void RunIo(std::unique_ptr<FilesResult> result, std::function<IoOutcome()> work) {
  if (g_inflight.load() >= kMaxInflightIo) {
    result->Error("BUSY", "File operations abhi busy hain — thodi der baad try karein");
    return;
  }
  g_inflight++;
  std::shared_ptr<FilesResult> shared(std::move(result));
  try {
    std::thread([shared, work = std::move(work)]() {
      IoOutcome out;
      try {
        out = work();
      } catch (...) {
        out = IoOutcome::Error("IO_FAILED", "File operation mein unexpected error");
      }
      PostToMain([shared, out = std::move(out)]() {
        ReplyOutcome(*shared, out);
        g_inflight--;
      });
    }).detach();
  } catch (...) {
    g_inflight--;
    shared->Error("IO_FAILED", "Worker thread shuru nahi ho saka");
  }
}

std::string PickDirectory(HWND owner) {
  Microsoft::WRL::ComPtr<IFileDialog> dialog;
  if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                               IID_PPV_ARGS(&dialog)))) {
    return "";
  }
  DWORD flags = 0;
  dialog->GetOptions(&flags);
  dialog->SetOptions(flags | FOS_PICKFOLDERS);

  if (FAILED(dialog->Show(owner))) return "";

  Microsoft::WRL::ComPtr<IShellItem> item;
  if (FAILED(dialog->GetResult(&item))) return "";

  PWSTR path_wide = nullptr;
  if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &path_wide))) return "";

  int size = WideCharToMultiByte(CP_UTF8, 0, path_wide, -1, nullptr, 0,
                                  nullptr, nullptr);
  std::string result(size, 0);
  WideCharToMultiByte(CP_UTF8, 0, path_wide, -1, result.data(), size,
                       nullptr, nullptr);
  CoTaskMemFree(path_wide);
  if (!result.empty() && result.back() == '\0') result.pop_back();
  return result;
}
}  // namespace

void FilesManager::DrainMainThreadTasks() {
  std::deque<std::function<void()>> tasks;
  {
    std::lock_guard<std::mutex> lock(g_main_mutex);
    tasks.swap(g_main_tasks);
  }
  for (auto& t : tasks) t();
}

void FilesManager::Register(flutter::FlutterEngine* engine, HWND window_handle) {
  g_main_hwnd = window_handle;
  auto channel = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kChannel,
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [channel, window_handle](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        auto get_string = [&](const char* key) -> std::string {
          if (!args) return "";
          auto it = args->find(flutter::EncodableValue(key));
          if (it == args->end()) return "";
          if (auto v = std::get_if<std::string>(&it->second)) return *v;
          return "";
        };

        if (call.method_name() == "getAllowedRoot") {
          auto& roots = GrantedRoots();
          result->Success(flutter::EncodableValue(
              roots.empty() ? SandboxRoot().u8string() : roots.back().u8string()));

        } else if (call.method_name() == "listDirectory") {
          // Sandbox resolve UI thread par (GrantedRoots yahin badalte
          // hain); asli directory I/O worker thread par (Item 81).
          fs::path dir = ResolveSandboxed(get_string("path"));
          RunIo(std::move(result), [dir]() { return DoListDirectory(dir); });

        } else if (call.method_name() == "readFile") {
          fs::path file = ResolveSandboxed(get_string("path"));
          RunIo(std::move(result), [file]() { return DoReadFile(file); });

        } else if (call.method_name() == "writeFile") {
          if (IsDangerousFileName(get_string("path"))) {
            result->Error("FORBIDDEN_TYPE",
                          "Is file type ko likhna security policy se blocked hai");
            return;
          }
          fs::path file = ResolveSandboxed(get_string("path"));
          if (file.empty()) {
            result->Error("FORBIDDEN", "Sandbox se bahar likhna mana hai");
            return;
          }
          std::string data = get_string("data");
          RunIo(std::move(result),
                [file, data = std::move(data)]() { return DoWriteFile(file, data); });

        } else if (call.method_name() == "deleteFile") {
          fs::path file = ResolveSandboxed(get_string("path"));
          RunIo(std::move(result), [file]() { return DoDeleteFile(file); });

        } else if (call.method_name() == "pickDirectory") {
          std::string picked = PickDirectory(window_handle);
          if (picked.empty()) {
            result->Success();
          } else {
            auto& roots = GrantedRoots();
            fs::path p = fs::u8path(picked);
            bool already = false;
            for (const auto& r : roots) {
              if (r == p) { already = true; break; }
            }
            if (!already) {
              roots.push_back(p);
              SaveGrantedRoots(roots);  // item 82: restart ke baad bhi yaad
            }
            result->Success(flutter::EncodableValue(picked));
          }

        } else {
          result->NotImplemented();
        }
      });
}
