# linux/CMakeLists.txt
#
# Standard Flutter Linux desktop template structure (`flutter create -p
# linux` isi shape ki files generate karta hai). Humne is file mein
# apne capability files (Section: 9 capabilities) ke extra pkg-config
# dependencies add kiye hain — yeh woh hissa hai jo normally hand-edit
# hota hai jab bhi koi naya native dependency add ho.

cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

set(BINARY_NAME "device_agent")
set(APPLICATION_ID "com.deviceagent.app")

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE STRING "" FORCE)
endif()

option(DEVICE_AGENT_WERROR "Treat compiler warnings as errors" OFF)

function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  # Warnings-as-errors ab opt-in (-DDEVICE_AGENT_WERROR=ON). Blind-likhe native
  # code par pehle CI run mein koi bhi warning poori build tod deti thi.
  target_compile_options(${TARGET} PRIVATE -Wall)
  if(DEVICE_AGENT_WERROR)
    target_compile_options(${TARGET} PRIVATE -Werror)
  endif()
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")

add_subdirectory(${FLUTTER_MANAGED_DIR})

# --- Device Agent capability dependencies -----------------------------
# Har capability jo alag system library maangti hai — README mein bhi
# already note kiya gaya tha (gio-unix-2.0 ka gdesktopappinfo.h ke liye
# zaroori hona, libebook-1.2 ka evolution-data-server-dev, waghera).
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)
pkg_check_modules(GIO REQUIRED IMPORTED_TARGET gio-2.0)
pkg_check_modules(GIO_UNIX REQUIRED IMPORTED_TARGET gio-unix-2.0)
pkg_check_modules(PIPEWIRE REQUIRED IMPORTED_TARGET libpipewire-0.3)
pkg_check_modules(X11 REQUIRED IMPORTED_TARGET x11 xtst)
pkg_check_modules(TURBOJPEG REQUIRED IMPORTED_TARGET libturbojpeg)
pkg_check_modules(EBOOK REQUIRED IMPORTED_TARGET libebook-1.2)

add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"

  # --- Device Agent capability managers ---
  "pairing_manager.cc"
  "screen_capture_manager.cc"
  "screen_capture_x11.cc"
  "screen_capture_wayland_portal.cc"
  "wayland_portal_session.cc"
  "input_manager.cc"
  "input_x11.cc"
  "input_wayland_portal.cc"
  "files_manager.cc"
  "app_launcher_manager.cc"
  "clipboard_manager.cc"
  "browser_manager.cc"
  "location_network_manager.cc"
  "contacts_manager.cc"
  "lock_state_manager.cc"

  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

apply_standard_settings(${BINARY_NAME})

target_compile_definitions(${BINARY_NAME} PRIVATE "APPLICATION_ID=\"${APPLICATION_ID}\"")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

find_package(Threads REQUIRED)
target_link_libraries(${BINARY_NAME} PRIVATE Threads::Threads)
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GIO)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GIO_UNIX)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::PIPEWIRE)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::X11)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::TURBOJPEG)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::EBOOK)

add_dependencies(${BINARY_NAME} flutter_assemble)

include(flutter/generated_plugins.cmake)

# --- Installation (bundling) -------------------------------------------
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "Install prefix" FORCE)
endif()
set(INSTALL_BUNDLE_DIR "${CMAKE_INSTALL_PREFIX}")
set(INSTALL_BUNDLE_DATA_DIR "${INSTALL_BUNDLE_DIR}/data")
set(INSTALL_BUNDLE_LIB_DIR "${INSTALL_BUNDLE_DIR}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${INSTALL_BUNDLE_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release COMPONENT Runtime)

# --- Branding (Section 13 #9) --------------------------------------------
# Pehle koi .desktop entry ya icon packaging nahi thi — app system app-menu
# mein sahi se dikhti hi nahi (na icon, na proper display name), aur na hi
# koi `.deb`/`.rpm`/Flatpak jaisi packaging isse discover kar paati bina
# handmade extra steps ke. Standard freedesktop.org layout follow karte
# hain (`share/applications/`, `share/icons/hicolor/<size>/apps/`) taaki
# koi bhi standard Linux packaging tool (electron-builder jaisa nahi,
# lekin dpkg-deb/appimagetool/flatpak-builder) inhe automatically pick
# kar sake.
install(FILES "${CMAKE_SOURCE_DIR}/packaging/com.deviceagent.app.desktop"
  DESTINATION "${INSTALL_BUNDLE_DIR}/share/applications" COMPONENT Runtime)
# Item 88: poora hicolor set (menu/launcher/HiDPI sab ke liye).
foreach(_icon_size 16 32 48 64 128 256 512)
  install(FILES
    "${CMAKE_SOURCE_DIR}/packaging/icons/hicolor/${_icon_size}x${_icon_size}/apps/com.deviceagent.app.png"
    DESTINATION "${INSTALL_BUNDLE_DIR}/share/icons/hicolor/${_icon_size}x${_icon_size}/apps"
    COMPONENT Runtime)
endforeach()
