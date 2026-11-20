// tray_icon.cpp — Item 85 (Windows). Native Win32 tray (Shell_NotifyIcon).
#include "tray_icon.h"

#include <shellapi.h>

#include <cwchar>
#include <string>

#include "resource.h"

namespace {
constexpr UINT kTrayId = 1;
constexpr UINT kCmdOpen = 1001;
constexpr UINT kCmdQuit = 1002;

bool g_added = false;
HWND g_hwnd = nullptr;
bool g_quitting = false;
UINT g_taskbar_created = 0;  // Explorer restart par icon dobara add karna

void ShowMainWindow(HWND hwnd) {
  if (IsIconic(hwnd)) {
    ShowWindow(hwnd, SW_RESTORE);
  } else {
    ShowWindow(hwnd, SW_SHOW);
  }
  SetForegroundWindow(hwnd);
}

NOTIFYICONDATAW MakeData(HWND hwnd) {
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = hwnd;
  nid.uID = kTrayId;
  nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  nid.uCallbackMessage = TrayIcon::kCallbackMessage;
  nid.hIcon = static_cast<HICON>(LoadImageW(
      GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0));
  wcsncpy_s(nid.szTip, L"Universal Device Agent (background mein chal raha hai)",
            _TRUNCATE);
  return nid;
}

void ShowMenu(HWND hwnd) {
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return;
  AppendMenuW(menu, MF_STRING, kCmdOpen, L"Open");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kCmdQuit, L"Quit");

  POINT pt;
  GetCursorPos(&pt);
  // Documented requirement: tray menu se pehle foreground window set karo,
  // warna menu bahar click par band nahi hota.
  SetForegroundWindow(hwnd);
  UINT cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY,
                            pt.x, pt.y, 0, hwnd, nullptr);
  PostMessage(hwnd, WM_NULL, 0, 0);
  DestroyMenu(menu);

  if (cmd == kCmdOpen) {
    ShowMainWindow(hwnd);
  } else if (cmd == kCmdQuit) {
    g_quitting = true;
    PostMessage(hwnd, WM_CLOSE, 0, 0);  // ab real close hoga (neeche dekhein)
  }
}
}  // namespace

void TrayIcon::Create(HWND hwnd) {
  g_hwnd = hwnd;
  if (g_taskbar_created == 0) {
    g_taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  }
  NOTIFYICONDATAW nid = MakeData(hwnd);
  g_added = Shell_NotifyIconW(NIM_ADD, &nid) != FALSE;
}

void TrayIcon::Remove() {
  if (!g_added || g_hwnd == nullptr) return;
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = g_hwnd;
  nid.uID = kTrayId;
  Shell_NotifyIconW(NIM_DELETE, &nid);
  g_added = false;
}

bool TrayIcon::IsActive() { return g_added; }

bool TrayIcon::HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                             LPARAM lparam, LRESULT* result) {
  if (message == kCallbackMessage) {
    switch (LOWORD(lparam)) {
      case WM_LBUTTONUP:
      case WM_LBUTTONDBLCLK:
        ShowMainWindow(hwnd);
        break;
      case WM_RBUTTONUP:
      case WM_CONTEXTMENU:
        ShowMenu(hwnd);
        break;
      default:
        break;
    }
    *result = 0;
    return true;
  }

  if (g_taskbar_created != 0 && message == g_taskbar_created) {
    NOTIFYICONDATAW nid = MakeData(hwnd);
    g_added = Shell_NotifyIconW(NIM_ADD, &nid) != FALSE;
    *result = 0;
    return true;
  }

  switch (message) {
    case WM_CLOSE:
      // Close (X / Alt+F4) = tray mein chhupa do; Quit menu / system
      // shutdown par real close.
      if (g_added && !g_quitting) {
        ShowWindow(hwnd, SW_HIDE);
        *result = 0;
        return true;
      }
      return false;

    case WM_QUERYENDSESSION:
    case WM_ENDSESSION:
      g_quitting = true;  // logoff/shutdown mein hum rukawat nahi banenge
      return false;

    case WM_DESTROY:
      Remove();
      return false;

    default:
      return false;
  }
}

bool TrayIcon::StartHidden() {
  static const bool hidden = [] {
    const wchar_t* cmd = GetCommandLineW();
    return cmd != nullptr && std::wstring(cmd).find(L"--background") != std::wstring::npos;
  }();
  return hidden;
}
