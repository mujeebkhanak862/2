// clipboard_manager.h
#ifndef DEVICE_AGENT_CLIPBOARD_MANAGER_H_
#define DEVICE_AGENT_CLIPBOARD_MANAGER_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Native side of `ChannelNames.clipboard` for Linux — GTK clipboard API.
void clipboard_manager_register(FlEngine* engine);

#endif  // DEVICE_AGENT_CLIPBOARD_MANAGER_H_
