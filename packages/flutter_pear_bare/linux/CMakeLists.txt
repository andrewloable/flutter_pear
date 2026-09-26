# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "flutter_pear_bare")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "flutter_pear_bare_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "flutter_pear_bare_plugin.cc"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file. flutter_pear_bare bundles
# no prebuilt native libraries on Linux -- unlike Android/iOS's BareKit
# .so/.xcframework, the Linux host spawns the real `bare` CLI as an external
# subprocess (flutter_pear-65g, E-D2c -- same embedding shape E-D1 proved),
# so there is nothing to bundle here.
set(flutter_pear_bare_bundled_libraries
  ""
  PARENT_SCOPE
)

# Desktop pear-end.bundle + its offloaded native addons, committed by
# bin/pack.dart's buildDesktopBundle (flutter_pear-9ng): NOT declared via
# flutter_pear_bare_bundled_libraries above, deliberately -- that variable
# feeds the app-level CMakeLists.txt's own `install(FILES ...)` call (see
# Flutter's own linux app template), and install(FILES) flattens every
# entry to its bare filename in the destination, destroying the
# node_modules/<addon>/prebuilds/linux-x64/ nesting bare's own require()
# needs to find its native addons. install(DIRECTORY ... DESTINATION) is
# the CMake call that preserves nested structure, so this plugin issues its
# own directly rather than routing through bundled_libraries at all -- a
# plain `install()` from an add_subdirectory()-included CMakeLists.txt
# aggregates into the app's own top-level install step (standard CMake
# behavior, not a Flutter-specific mechanism, so it does not depend on how
# Flutter's tooling treats bundled_libraries).
#
# "data" is a plain relative destination, resolved by CMake's own install()
# against ${CMAKE_INSTALL_PREFIX} -- confirmed against Flutter's own Linux
# app template (INSTALL_BUNDLE_DATA_DIR = "${CMAKE_INSTALL_PREFIX}/data"),
# the SAME prefix data/flutter_assets/ itself lands under, so this ends up
# a sibling of it: <bundle>/data/flutter_pear_bare_desktop/. The source
# path's trailing slash copies assets/desktop/linux-x64's CONTENTS directly
# into that destination (CMake's rsync-style convention), so the result is
# <bundle>/data/flutter_pear_bare_desktop/pear-end.bundle, matching
# flutter_pear_bare_plugin.cc's own resolve_bundle_path.
#
# Verified end to end on real Linux hardware (Ubuntu 24.04, Ninja generator,
# a real SSH-reachable machine): `flutter build linux --debug` succeeds, and
# the built bundle's data/flutter_pear_bare_desktop/ contains pear-end.bundle
# plus the full node_modules/<addon>/prebuilds/linux-x64/ tree, structure
# intact. A real worklet boots (integration_test/
# worklet_asset_resolution_test.dart, 3/3 clean runs) and completes a real
# P2P round trip over the public DHT (cross_platform_chat_test.dart).
#
# A bare install(DIRECTORY ...) works here specifically because Ninja is a
# SINGLE-config generator, so ${CMAKE_INSTALL_PREFIX} is a plain, already-
# resolved path with no generator-expression syntax in it at configure time
# -- unlike Visual Studio's multi-config generator on Windows, where the
# equivalent bare install(DIRECTORY ...) FAILED for exactly that reason (see
# windows/CMakeLists.txt's own comment on this same mechanism, including the
# real CMake error hit there).
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/assets/desktop/linux-x64/"
  DESTINATION "data/flutter_pear_bare_desktop"
)
