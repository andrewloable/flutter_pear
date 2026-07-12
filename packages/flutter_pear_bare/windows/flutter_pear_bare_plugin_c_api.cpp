#include "include/flutter_pear_bare/flutter_pear_bare_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "flutter_pear_bare_plugin.h"

void FlutterPearBarePluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_pear_bare::FlutterPearBarePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
