// clipboard_manager.cc
#include "clipboard_manager.h"

#include <string>


namespace {
constexpr char kChannel[] = "device_agent/clipboard";

std::string GetStringArg(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return "";
  }
  FlValue* v = fl_value_lookup_string(args, key);
  if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) return "";
  return fl_value_get_string(v);
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                            gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);

  if (g_strcmp0(method, "readText") == 0) {
    // gtk_clipboard_wait_for_text blocking hai — MethodChannel handler
    // se synchronous response dene ke liye yahi simplest reliable tareeka
    // hai (screen_capture/pairing wale portal calls jaisa hi pattern).
    g_autofree gchar* text = gtk_clipboard_wait_for_text(clipboard);
    if (text != nullptr) {
      g_autoptr(FlValue) result = fl_value_new_string(text);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
    } else {
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }

  } else if (g_strcmp0(method, "writeText") == 0) {
    std::string text = GetStringArg(args, "text");
    gtk_clipboard_set_text(clipboard, text.c_str(), -1);
    // Persist karta hai taaki app band hone ke baad bhi clipboard content
    // zinda rahe (X11/Wayland dono par clipboard owner-app-dependent hota
    // hai bina store() ke).
    gtk_clipboard_store(clipboard);
    g_autoptr(FlValue) result = fl_value_new_bool(true);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));

  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Clipboard channel response failed: %s", error->message);
  }
}
}  // namespace

void clipboard_manager_register(FlEngine* engine) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  FlMethodChannel* channel =
      fl_method_channel_new(messenger, kChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr,
                                             nullptr);
}
