// tray_icon.h — Item 85 (Windows): system-tray icon + "close = hide to tray".
#ifndef DEVICE_AGENT_TRAY_ICON_H_
#define DEVICE_AGENT_TRAY_ICON_H_

#include <windows.h>

// Agent background mein chalta rehta hai: window band karne par app quit
// nahi hoti, sirf tray mein chali jaati hai. Tray menu: Open / Quit.
// Login autostart `--background` ke saath start hota hai => window chhupi.
class TrayIcon {
 public:
  static constexpr UINT kCallbackMessage = WM_APP + 0x52;

  // Tray icon add karta hai (ek baar, window banne ke baad).
  static void Create(HWND hwnd);
  // Tray icon hataata hai (idempotent).
  static void Remove();
  // Tray icon abhi dikh raha hai? (Login par explorer ready na ho to add
  // fail ho sakta hai; tab window chhupayenge nahi.)
  static bool IsActive();

  // true => message handle ho gaya, `*result` return karo.
  static bool HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                            LPARAM lparam, LRESULT* result);

  // Command line mein `--background` tha?
  static bool StartHidden();
};

#endif  // DEVICE_AGENT_TRAY_ICON_H_
