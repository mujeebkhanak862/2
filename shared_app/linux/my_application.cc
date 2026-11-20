// my_application.cc
//
// Flutter Linux desktop embedder GTK par based hai (flutter_linux library).
// Section 6.7 ka "main.cpp — Entry point" isi file ka real equivalent hai.

#include "my_application.h"
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

#include <flutter_linux/flutter_linux.h>
#include "flutter/generated_plugin_registrant.h"
#include <gtk/gtk.h>

struct _MyApplication {
  GtkApplication parent_instance;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void my_application_activate(GApplication* application) {
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  gtk_window_set_title(window, "Universal Device Agent");
  gtk_window_set_default_size(window, 1280, 720);
  gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  // Har naya capability isi jagah register hoga. Abhi Pairing, Screen
  // Capture, Input, Files, App Launcher, Clipboard, Browser,
  // Location/Network aur Contacts wired hain.
  pairing_manager_register(fl_view_get_engine(view));
  screen_capture_manager_register(fl_view_get_engine(view));
  input_manager_register(fl_view_get_engine(view));
  files_manager_register(fl_view_get_engine(view), window);
  app_launcher_manager_register(fl_view_get_engine(view));
  clipboard_manager_register(fl_view_get_engine(view));
  browser_manager_register(fl_view_get_engine(view));
  location_network_manager_register(fl_view_get_engine(view));
  contacts_manager_register(fl_view_get_engine(view));

  // Audit fix (P1-05) — real lock/session state (org.freedesktop.
  // ScreenSaver over D-Bus; last of the three platforms).
  lock_state_manager_register(fl_view_get_engine(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  return MY_APPLICATION(g_object_new(
      my_application_get_type(), "application-id", "com.deviceagent.app",
      "flags", G_APPLICATION_NON_UNIQUE, nullptr));
}
