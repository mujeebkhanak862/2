// input_manager.cc
#include "input_manager.h"
#include "input_wayland_portal.h"
#include "input_x11.h"

#include <glib.h>
#include <string>

namespace {
constexpr char kChannel[] = "device_agent/input";

double GetDoubleArg(FlValue* args, const char* key, double def = 0.0) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return def;
  }
  FlValue* v = fl_value_lookup_string(args, key);
  if (v == nullptr) return def;
  if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) return fl_value_get_float(v);
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT) return fl_value_get_int(v);
  return def;
}

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

  bool use_wayland = InputWaylandPortal::IsAvailable();

  if (g_strcmp0(method, "isEnabled") == 0) {
    bool available =
        use_wayland ? InputWaylandPortal::IsAvailable() : InputX11::IsAvailable();
    g_autoptr(FlValue) result = fl_value_new_bool(available);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(method, "tap") == 0) {
    double x = GetDoubleArg(args, "x");
    double y = GetDoubleArg(args, "y");
    bool ok = use_wayland ? InputWaylandPortal::Tap(x, y) : InputX11::Tap(x, y);
    g_autoptr(FlValue) result = fl_value_new_bool(ok);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(method, "swipe") == 0) {
    double x1 = GetDoubleArg(args, "x1");
    double y1 = GetDoubleArg(args, "y1");
    double x2 = GetDoubleArg(args, "x2");
    double y2 = GetDoubleArg(args, "y2");
    int duration = static_cast<int>(GetDoubleArg(args, "duration_ms", 200));
    bool ok = use_wayland
        ? InputWaylandPortal::Swipe(x1, y1, x2, y2, duration)
        : InputX11::Swipe(x1, y1, x2, y2, duration);
    g_autoptr(FlValue) result = fl_value_new_bool(ok);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(method, "typeText") == 0) {
    std::string text = GetStringArg(args, "text");
    bool ok = use_wayland ? InputWaylandPortal::TypeText(text)
                           : InputX11::TypeText(text);
    g_autoptr(FlValue) result = fl_value_new_bool(ok);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (g_strcmp0(method, "openAccessibilitySettings") == 0) {
    // Android-only concept — Linux par no-op (already enabled at session level).
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Input channel response failed: %s", error->message);
  }
}
}  // namespace

void input_manager_register(FlEngine* engine) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  FlMethodChannel* channel =
      fl_method_channel_new(messenger, kChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr,
                                             nullptr);
}
