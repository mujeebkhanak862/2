# windows/runner/CMakeLists.txt
#
# Yeh woh file hai jo normally hand-edit hoti hai jab bhi naya native
# source file add karna ho — humne apne saare capability managers
# (pairing, screen, input, files, app_launcher, clipboard, browser,
# location_network, contacts) isi SOURCES list mein daal diye hain.

cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

add_executable(${BINARY_NAME} WIN32
  "main.cpp"
  "win32_window.cpp"
  "flutter_window.cpp"
  "utils.cpp"
  "Runner.rc"
  "runner.exe.manifest"

  # --- Device Agent capability managers ---
  "pairing_manager.cpp"
  "screen_capture_manager.cpp"
  "input_manager.cpp"
  "files_manager.cpp"
  "app_launcher_manager.cpp"
  "clipboard_manager.cpp"
  "browser_manager.cpp"
  "location_network_manager.cpp"
  "contacts_manager.cpp"
  "lock_state_manager.cpp"
  "tray_icon.cpp"

  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

apply_standard_settings(${BINARY_NAME})
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")

# --- Device Agent capability dependencies ---
# screen_capture_manager.cpp — Windows.Graphics.Capture + WIC.
target_link_libraries(${BINARY_NAME} PRIVATE "windowsapp.lib" "d3d11.lib" "dxgi.lib" "windowscodecs.lib")
# files_manager.cpp — folder picker (IFileDialog) + base64 (Crypt32).
target_link_libraries(${BINARY_NAME} PRIVATE "shell32.lib" "crypt32.lib")
# app_launcher_manager.cpp — ShellExecute.
target_link_libraries(${BINARY_NAME} PRIVATE "shlwapi.lib")
# location_network_manager.cpp — WLAN API + WinInet.
target_link_libraries(${BINARY_NAME} PRIVATE "wlanapi.lib" "wininet.lib")

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}/../ephemeral")

add_dependencies(${BINARY_NAME} flutter_assemble)
