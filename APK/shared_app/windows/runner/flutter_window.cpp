// flutter_window.cpp
//
// NOTE: Architecture doc (Section 6.7) sugggested "C++/C#" for
// windows_native/. Flutter's actual Windows desktop embedder runs on a
// native C++ runner (this is how `flutter build windows` really works) —
// there's no supported C#/WinUI method-channel host. So implementation
// yahan pure C++ mein hai; agar future mein .NET side ki zaroorat pade
// (e.g. calling a C# library for something), woh ek separate interop
// layer hoga, is runner ka hissa nahi.
//
// Section 6.7: "App.xaml.cs — Entry point, channels register karta hai"
// ka real equivalent yeh FlutterWindow::OnCreate() hai.

#include "flutter_window.h"
#include "app_launcher_manager.h"
#include "browser_manager.h"
#include "clipboard_manager.h"
#include "contacts_manager.h"
#include "files_manager.h"
#include "input_manager.h"
#include "location_network_manager.h"
#include "lock_state_manager.h"
#include "pairing_manager.h"
#include "screen_capture_manager.h"
#include "tray_icon.h"

// `flutter create .` generate karta hai — RegisterPlugins() yahin se
// declared hoti hai (agar koi pub.dev Flutter plugin bhi use ho to
// uske native side yahan auto-register hote hain).
#include "flutter/generated_plugin_registrant.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <memory>

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // Har naya capability isi jagah register hoga. Abhi Pairing, Screen
  // Capture, Input, Files, App Launcher, Clipboard, Browser,
  // Location/Network aur Contacts wired hain.
  PairingManager::Register(flutter_controller_->engine());
  ScreenCaptureManager::Register(flutter_controller_->engine(), GetHandle());
  InputManager::Register(flutter_controller_->engine(), GetHandle());
  FilesManager::Register(flutter_controller_->engine(), GetHandle());
  AppLauncherManager::Register(flutter_controller_->engine());
  ClipboardManagerNative::Register(flutter_controller_->engine(), GetHandle());
  BrowserManager::Register(flutter_controller_->engine());
  LocationNetworkManager::Register(flutter_controller_->engine());
  ContactsManager::Register(flutter_controller_->engine());

  // Audit fix (P1-05) — real lock/session state (OpenInputDesktop-based).
  LockStateManager::Register(flutter_controller_->engine());

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Item 85: tray icon (close = tray mein chhupo, Quit menu se real exit).
  TrayIcon::Create(GetHandle());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    // Login autostart `--background` ke saath chalta hai => window chhupi
    // rahe, sirf tray icon dikhe.
    if (!TrayIcon::StartHidden() || !TrayIcon::IsActive()) this->Show();
  });

  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  TrayIcon::Remove();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  Win32Window::OnDestroy();
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                                       WPARAM const wparam,
                                       LPARAM const lparam) noexcept {
  // Item 85: tray callbacks + close-to-tray.
  {
    LRESULT tray_result = 0;
    if (TrayIcon::HandleMessage(hwnd, message, wparam, lparam, &tray_result)) {
      return tray_result;
    }
  }
  // Item 81: files worker thread ke results UI thread par yahin chalte hain.
  if (message == FilesManager::kMainThreadMessage) {
    FilesManager::DrainMainThreadTasks();
    return 0;
  }
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                        lparam);
    if (result) {
      return *result;
    }
  }
  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
