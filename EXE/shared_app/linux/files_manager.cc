// files_manager.cc
#include "files_manager.h"

#include <glib.h>

#include <filesystem>
#include <fstream>
#include <functional>
#include <mutex>
#include <atomic>
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

// Default sandbox root — $XDG_DATA_HOME/device-agent/sandbox (glib
// resolves this correctly per-distro). Doc ke "allowed-root filesystem
// sandbox" ka Linux-equivalent, koi extra permission ki zaroorat nahi.
fs::path SandboxRoot() {
  fs::path root = fs::path(g_get_user_data_dir()) / "device-agent" / "sandbox";
  std::error_code ec;
  fs::create_directories(root, ec);
  return root;
}

// Path traversal protection. User `pickDirectory()` se jo folder choose
// kare, uska path yahan "granted roots" mein add ho jaata hai — taaki
// poore device storage ko bhi (Windows wali file jaisi hi logic) isi
// Files capability se browse kiya ja sake.
// Item 81: IO cap (10 MiB — server ki upload limit ke barabar).
constexpr uintmax_t kMaxFileBytes = 10 * 1024 * 1024;

fs::path GrantedRootsFile() {
  return SandboxRoot().parent_path() / "granted_roots.txt";
}

// Item 82: granted roots ab restart ke baad bhi yaad rehte hain
// (ek path per line, text file).
std::vector<fs::path> LoadGrantedRoots() {
  std::vector<fs::path> roots;
  std::ifstream in(GrantedRootsFile());
  std::string line;
  while (std::getline(in, line)) {
    if (line.empty()) continue;
    std::error_code ec;
    fs::path p(line);
    if (fs::is_directory(p, ec)) roots.push_back(p);
  }
  return roots;
}

void SaveGrantedRoots(const std::vector<fs::path>& roots) {
  std::ofstream out(GrantedRootsFile(), std::ios::trunc);
  for (const auto& r : roots) out << r.string() << "\n";
}

std::vector<fs::path>& GrantedRoots() {
  static std::vector<fs::path> roots = LoadGrantedRoots();
  return roots;
}

// **Real bug jo yahan tha (Windows `files_manager.cpp` aur Android
// `FilesHandler.kt` dono mein wahi bug tha, teeno jagah fix kiya)**:
// bare string-prefix comparison tha, boundary check ke bina — matlab
// sandbox root `.../sandbox` ka koi sibling folder jaise
// `.../sandbox_other` bhi galti se "andar" maan liya jaata. Boundary
// check add kiya: target ya to root ke barabar ho, ya root + '/' se
// shuru ho.
bool IsPathUnder(const std::string& target_str, const std::string& root_str) {
  if (target_str == root_str) return true;
  if (target_str.size() <= root_str.size()) return false;
  if (target_str.compare(0, root_str.size(), root_str) != 0) return false;
  return target_str[root_str.size()] == '/';
}

fs::path ResolveSandboxed(const std::string& relative_path) {
  std::error_code ec;
  fs::path root = fs::weakly_canonical(SandboxRoot(), ec);

  fs::path requested(relative_path);
  if (requested.is_absolute()) {
    fs::path target = fs::weakly_canonical(requested, ec);
    if (ec || target.empty()) return {};  // item 81: invalid path => reject
    auto target_str = target.string();

    auto is_under = [&](const fs::path& allowed_root) {
      auto root_str = fs::weakly_canonical(allowed_root, ec).string();
      return IsPathUnder(target_str, root_str);
    };

    if (is_under(root)) return target;
    for (auto& granted : GrantedRoots()) {
      if (is_under(granted)) return target;
    }
    return {};
  }

  fs::path target = fs::weakly_canonical(root / relative_path, ec);
  if (!IsPathUnder(target.string(), root.string())) {
    return {};
  }
  return target;
}

// Item 81: Android jaisa consistent `path` — sandbox ke andar ho to root ke
// relative, warna (granted root) absolute. (Pehle hamesha absolute tha.)
std::string PathToUtf8(const fs::path& p) { return p.string(); }

std::string DisplayPath(const fs::path& p) {
  std::error_code ec;
  fs::path root = fs::weakly_canonical(SandboxRoot(), ec);
  fs::path c = fs::weakly_canonical(p, ec);
  if (!ec && !root.empty() && IsPathUnder(c.string(), root.string())) {
    fs::path rel = fs::relative(c, root, ec);
    if (!ec) return rel.string();
  }
  return p.string();
}

std::string Base64Encode(const std::vector<unsigned char>& bytes) {
  gchar* encoded = g_base64_encode(bytes.data(), bytes.size());
  std::string result(encoded);
  g_free(encoded);
  return result;
}

// Item 81: g_base64_decode invalid input par NULL/garbage de sakta hai.
// Ab strict validation + `false` return.
bool Base64Decode(const std::string& b64, std::vector<unsigned char>* out) {
  if (b64.empty()) {
    out->clear();
    return true;
  }
  gsize out_len = 0;
  guchar* decoded = g_base64_decode(b64.c_str(), &out_len);
  if (decoded == nullptr) return false;
  // Valid base64 ka decoded size ~3/4 hota hai; bahut chhota => invalid.
  if (out_len == 0 && b64.size() > 4) {
    g_free(decoded);
    return false;
  }
  out->assign(decoded, decoded + out_len);
  g_free(decoded);
  return true;
}

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


// ---- Linux dispatcher: worker thread -> GTK main loop -------------------
// FlMethodCall ko jawab sirf main thread se; worker `g_idle_add` se
// (thread-safe) reply main loop mein schedule karta hai.
std::atomic<int> g_inflight{0};

struct PendingReply {
  FlMethodCall* call;  // g_object_ref'd
  IoOutcome outcome;
};

FlMethodResponse* BuildResponse(const IoOutcome& o) {
  switch (o.kind) {
    case IoOutcome::Kind::kError:
      return FL_METHOD_RESPONSE(
          fl_method_error_response_new(o.code.c_str(), o.message.c_str(), nullptr));
    case IoOutcome::Kind::kString: {
      g_autoptr(FlValue) v = fl_value_new_string(o.text.c_str());
      return FL_METHOD_RESPONSE(fl_method_success_response_new(v));
    }
    case IoOutcome::Kind::kBool: {
      g_autoptr(FlValue) v = fl_value_new_bool(o.flag);
      return FL_METHOD_RESPONSE(fl_method_success_response_new(v));
    }
    case IoOutcome::Kind::kList: {
      g_autoptr(FlValue) list = fl_value_new_list();
      for (const auto& e : o.entries) {
        g_autoptr(FlValue) m = fl_value_new_map();
        fl_value_set_string_take(m, "name", fl_value_new_string(e.name.c_str()));
        fl_value_set_string_take(m, "isDirectory", fl_value_new_bool(e.is_dir));
        fl_value_set_string_take(m, "size", fl_value_new_int(e.size));
        fl_value_set_string_take(m, "path", fl_value_new_string(e.path.c_str()));
        fl_value_append(list, m);
      }
      return FL_METHOD_RESPONSE(fl_method_success_response_new(list));
    }
  }
  return FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
}

gboolean ReplyIdle(gpointer data) {
  PendingReply* r = static_cast<PendingReply*>(data);
  g_autoptr(FlMethodResponse) response = BuildResponse(r->outcome);
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(r->call, response, &error)) {
    g_warning("Files channel response failed: %s", error->message);
  }
  g_object_unref(r->call);
  delete r;
  g_inflight--;
  return G_SOURCE_REMOVE;
}

// `true` agar kaam worker ko de diya gaya (caller ko jawab nahi dena);
// `false` agar busy/failed — tab `err` mein error response hai.
bool RunIo(FlMethodCall* call, std::function<IoOutcome()> work,
           IoOutcome* err) {
  if (g_inflight.load() >= kMaxInflightIo) {
    *err = IoOutcome::Error(
        "BUSY", "File operations abhi busy hain — thodi der baad try karein");
    return false;
  }
  g_inflight++;
  g_object_ref(call);
  try {
    std::thread([call, work = std::move(work)]() {
      IoOutcome out;
      try {
        out = work();
      } catch (...) {
        out = IoOutcome::Error("IO_FAILED", "File operation mein unexpected error");
      }
      g_idle_add(ReplyIdle, new PendingReply{call, std::move(out)});
    }).detach();
  } catch (...) {
    g_inflight--;
    g_object_unref(call);
    *err = IoOutcome::Error("IO_FAILED", "Worker thread shuru nahi ho saka");
    return false;
  }
  return true;
}

// GtkFileChooserDialog, modal + blocking (gtk_dialog_run) — MethodChannel
// handler ko synchronous response dena hai, isliye yeh sabse simple
// reliable tareeka hai (GTK ka apna recommended async pattern iske
// bajaye signal-based hota, lekin yahan blocking acceptable hai kyunki
// user-interaction ke dauran UI thread waise bhi wait karta).
std::string PickDirectoryBlocking(GtkWindow* parent) {
  GtkWidget* dialog = gtk_file_chooser_dialog_new(
      "Folder Chunein", parent, GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
      "_Cancel", GTK_RESPONSE_CANCEL, "_Select", GTK_RESPONSE_ACCEPT, nullptr);

  std::string result;
  if (gtk_dialog_run(GTK_DIALOG(dialog)) == GTK_RESPONSE_ACCEPT) {
    g_autofree gchar* path =
        gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog));
    if (path != nullptr) result = path;
  }
  gtk_widget_destroy(dialog);
  return result;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                            gpointer user_data) {
  GtkWindow* window = static_cast<GtkWindow*>(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  auto get_string = [&](const char* key) -> std::string {
    if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return "";
    FlValue* v = fl_value_lookup_string(args, key);
    if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) return "";
    return fl_value_get_string(v);
  };

  if (g_strcmp0(method, "getAllowedRoot") == 0) {
    auto& roots = GrantedRoots();
    g_autoptr(FlValue) result = fl_value_new_string(
        roots.empty() ? SandboxRoot().c_str() : roots.back().c_str());
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));

  } else if (g_strcmp0(method, "listDirectory") == 0) {
    // Item 81: sandbox resolve main thread par; asli I/O worker par.
    fs::path dir = ResolveSandboxed(get_string("path"));
    IoOutcome err;
    if (RunIo(method_call, [dir]() { return DoListDirectory(dir); }, &err)) return;
    response = BuildResponse(err);

  } else if (g_strcmp0(method, "readFile") == 0) {
    fs::path file = ResolveSandboxed(get_string("path"));
    IoOutcome err;
    if (RunIo(method_call, [file]() { return DoReadFile(file); }, &err)) return;
    response = BuildResponse(err);

  } else if (g_strcmp0(method, "writeFile") == 0) {
    if (IsDangerousFileName(get_string("path"))) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "FORBIDDEN_TYPE",
          "Is file type ko likhna security policy se blocked hai", nullptr));
    } else {
      fs::path file = ResolveSandboxed(get_string("path"));
      if (file.empty()) {
        response = FL_METHOD_RESPONSE(fl_method_error_response_new(
            "FORBIDDEN", "Sandbox se bahar likhna mana hai", nullptr));
      } else {
        std::string data = get_string("data");
        IoOutcome err;
        if (RunIo(method_call,
                  [file, data = std::move(data)]() { return DoWriteFile(file, data); },
                  &err)) {
          return;
        }
        response = BuildResponse(err);
      }
    }

  } else if (g_strcmp0(method, "deleteFile") == 0) {
    fs::path file = ResolveSandboxed(get_string("path"));
    IoOutcome err;
    if (RunIo(method_call, [file]() { return DoDeleteFile(file); }, &err)) return;
    response = BuildResponse(err);

  } else if (g_strcmp0(method, "pickDirectory") == 0) {
    std::string picked = PickDirectoryBlocking(window);
    if (!picked.empty()) {
      auto& roots = GrantedRoots();
      fs::path p(picked);
      bool already = false;
      for (const auto& r : roots) {
        if (r == p) { already = true; break; }
      }
      if (!already) {
        roots.push_back(p);
        SaveGrantedRoots(roots);  // item 82
      }
    }
    g_autoptr(FlValue) result =
        picked.empty() ? nullptr : fl_value_new_string(picked.c_str());
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));

  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Files channel response failed: %s", error->message);
  }
}
}  // namespace

void files_manager_register(FlEngine* engine, GtkWindow* window) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  FlMethodChannel* channel =
      fl_method_channel_new(messenger, kChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, window,
                                             nullptr);
}
