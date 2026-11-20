// files_manager.h
#ifndef DEVICE_AGENT_FILES_MANAGER_H_
#define DEVICE_AGENT_FILES_MANAGER_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Native side of `ChannelNames.files` for Linux — sandboxed
// std::filesystem operations within an allowed root, plus a GTK folder
// picker for broader user-granted access. `window` GtkWindow* chahiye
// taaki folder-picker dialog sahi parent ke saath modal ho.
void files_manager_register(FlEngine* engine, GtkWindow* window);

#endif  // DEVICE_AGENT_FILES_MANAGER_H_
