#ifndef FLUTTER_PLUGIN_FLUTTER_PEAR_BARE_PLUGIN_IMPL_H_
#define FLUTTER_PLUGIN_FLUTTER_PEAR_BARE_PLUGIN_IMPL_H_

#include <flutter/basic_message_channel.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_message_codec.h>

#include <memory>

namespace flutter_pear_bare {

class FlutterPearBarePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  FlutterPearBarePlugin(
      std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
          control_channel,
      std::unique_ptr<flutter::BasicMessageChannel<flutter::EncodableValue>>
          ipc_channel);

  virtual ~FlutterPearBarePlugin();

  // Disallow copy and assign.
  FlutterPearBarePlugin(const FlutterPearBarePlugin &) = delete;
  FlutterPearBarePlugin &operator=(const FlutterPearBarePlugin &) = delete;

  // Called when a method is called on the control channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Reached from the process-wide relay window/threads (see the .cpp file's
  // "static, process-lifetime state" section) to deliver worklet -> Dart
  // bytes and unexpected-exit notifications on the CURRENT plugin instance's
  // channels -- there is exactly one live instance at a time, tracked via
  // the static g_current_plugin pointer, but the accessors themselves are
  // ordinary instance methods.
  flutter::BasicMessageChannel<flutter::EncodableValue> *ipc_channel() const {
    return ipc_channel_.get();
  }
  flutter::MethodChannel<flutter::EncodableValue> *control_channel() const {
    return control_channel_.get();
  }

  // Mirrors the other hosts' `attached`/`self->attached` flag: cleared in
  // the destructor so a message that arrives after this instance is torn
  // down (e.g. mid hot-restart) is dropped rather than sent on a
  // about-to-be-destroyed channel.
  bool attached = true;

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      control_channel_;
  std::unique_ptr<flutter::BasicMessageChannel<flutter::EncodableValue>>
      ipc_channel_;
};

}  // namespace flutter_pear_bare

#endif  // FLUTTER_PLUGIN_FLUTTER_PEAR_BARE_PLUGIN_IMPL_H_
