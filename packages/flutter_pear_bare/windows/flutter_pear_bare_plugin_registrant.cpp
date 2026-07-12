#include "include/flutter_pear_bare/flutter_pear_bare_plugin.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_pear_bare_plugin_impl.h"

void FlutterPearBarePluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_pear_bare::FlutterPearBarePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
