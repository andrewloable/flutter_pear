#ifndef FLUTTER_PLUGIN_FLUTTER_PEAR_BARE_PLUGIN_C_API_H_
#define FLUTTER_PLUGIN_FLUTTER_PEAR_BARE_PLUGIN_C_API_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif

// The exact name/path Flutter's own plugin-registration generator expects,
// derived purely from pubspec.yaml's `pluginClass: FlutterPearBarePlugin`
// declaration (confirmed against a real generated_plugin_registrant.cc on
// a real Windows box, which literally #includes
// <flutter_pear_bare/flutter_pear_bare_plugin.h> and calls this exact
// symbol -- there is no "_c_api" suffix anywhere in that generated
// contract, unlike a plugin whose own pluginClass value happens to
// include one).
FLUTTER_PLUGIN_EXPORT void FlutterPearBarePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#if defined(__cplusplus)
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_FLUTTER_PEAR_BARE_PLUGIN_C_API_H_
