# The Flutter tooling requires that developers have a version of Visual
# Studio installed that includes CMake 3.14 or later. You should not
# increase this version, as doing so will cause the plugin to fail to
# compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "flutter_pear_bare")
project(${PROJECT_NAME} LANGUAGES CXX)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "flutter_pear_bare_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "flutter_pear_bare_plugin_impl.cpp"
  "flutter_pear_bare_plugin_impl.h"
)

# Define the plugin library target. Its name must not be changed (see
# comment on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  "include/flutter_pear_bare/flutter_pear_bare_plugin.h"
  "flutter_pear_bare_plugin_registrant.cpp"
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that
# want full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental
# conflicts between plugins. This should not be removed; any symbols that
# should be exported should be explicitly exported with the
# FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Source include directories and library dependencies. Add any
# plugin-specific dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# List of absolute paths to libraries that should be bundled with the
# plugin. This list could contain prebuilt libraries, or libraries created
# by an external build triggered from this build file.
# flutter_pear_bare bundles no prebuilt native libraries on Windows --
# unlike Android/iOS's BareKit .so/.xcframework, the Windows host spawns
# the real `bare` CLI as an external subprocess (flutter_pear-pfp, E-D2b --
# the same embedding shape E-D1/E-D2a/E-D2c proved), so there is nothing to
# bundle here.
set(flutter_pear_bare_bundled_libraries
  ""
  PARENT_SCOPE
)

# Desktop pear-end.bundle + its offloaded native addons, committed by
# bin/pack.dart's buildDesktopBundle (flutter_pear-9ng): NOT declared via
# flutter_pear_bare_bundled_libraries above, deliberately -- that variable
# feeds the app-level CMakeLists.txt's own `install(FILES ...)` call (see
# Flutter's own Windows app template), and install(FILES) flattens every
# entry to its bare filename in the destination, destroying the
# node_modules/<addon>/prebuilds/win32-x64/ nesting bare's own require()
# needs to find its native addons. install(DIRECTORY ... DESTINATION) is
# the CMake call that preserves nested structure, so this plugin issues its
# own directly rather than routing through bundled_libraries at all -- a
# plain `install()` from an add_subdirectory()-included CMakeLists.txt
# aggregates into the app's own top-level install step (standard CMake
# behavior, not a Flutter-specific mechanism, so it does not depend on how
# Flutter's tooling treats bundled_libraries).
#
# NOT a bare install(DIRECTORY ... DESTINATION "data/...") -- build-tested
# on real Windows hardware (a real SSH-reachable machine, Visual Studio 2022
# Community) and it fails there, though it works fine on Linux. Root cause:
# Flutter's own windows/CMakeLists.txt template sets
# CMAKE_INSTALL_PREFIX to the LITERAL, unresolved string
# "$<TARGET_FILE_DIR:${BINARY_NAME}>" (a generator expression, needed
# because Visual Studio is a MULTI-CONFIG generator -- Debug/Release/Profile
# share one build tree, so the real output directory can only be known at
# generator-expression-evaluation time, not at plain configure time; Linux's
# Ninja is single-config and never hits this). install(TARGETS ...)
# specially resolves a generator expression appearing in its own DESTINATION
# argument; install(DIRECTORY ...) does NOT get that same treatment, so
# concatenating a plain relative destination onto ${CMAKE_INSTALL_PREFIX}
# produces literal, unexpanded "$<TARGET_FILE_DIR:...>" text baked into the
# path -- confirmed exactly by the real error: CMake Error ... file INSTALL
# cannot make directory ".../$<TARGET_FILE_DIR:flutter_pear_example>/data/
# flutter_pear_bare_desktop": Invalid argument.
#
# install(CODE "...") sidesteps this: its STRING content is genex-evaluated
# as part of generating cmake_install.cmake (a well-established pattern for
# exactly this situation), so by the time file(INSTALL ...) actually runs,
# ${CMAKE_INSTALL_PREFIX} has already been substituted into a fully-resolved,
# per-configuration absolute path with no generator-expression syntax left
# in it at all. file(INSTALL ...) is the same underlying primitive
# install(DIRECTORY ...) itself expands to, so the trailing-slash/no-
# trailing-slash source semantics are identical (contents-only copy).
#
# The prefix is NOT read straight from ${CMAKE_INSTALL_PREFIX}: the app
# template includes generated_plugins.cmake BEFORE it sets that variable, so
# on a FRESH configure this file still sees CMake's default,
# "C:/Program Files/<project>" -- the files went there (from an elevated
# shell) or failed with access denied, never next to the .exe. Only a
# RE-configure, reading the app's cached value, happened to work. This
# mirrors the app template's own rule instead: default prefix -> the
# executable's own directory, a caller-set prefix -> that prefix.
# BINARY_NAME is set by every Flutter Windows app template (the flutter
# tool itself reads it to find the .exe).
#
# Verified end to end on real hardware from a fresh build directory:
# `flutter build windows --debug` succeeds, and the built bundle's
# data\flutter_pear_bare_desktop\ contains pear-end.bundle plus the full
# node_modules\<addon>\prebuilds\win32-x64\ tree, structure intact --
# matching flutter_pear_bare_plugin_impl.cpp's own ResolveBundlePath.
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(FLUTTER_PEAR_BARE_INSTALL_PREFIX "$<TARGET_FILE_DIR:${BINARY_NAME}>")
else()
  set(FLUTTER_PEAR_BARE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")
endif()
install(CODE "
  file(INSTALL \"${CMAKE_CURRENT_SOURCE_DIR}/assets/desktop/win32-x64/\"
    DESTINATION \"${FLUTTER_PEAR_BARE_INSTALL_PREFIX}/data/flutter_pear_bare_desktop\"
  )
")
