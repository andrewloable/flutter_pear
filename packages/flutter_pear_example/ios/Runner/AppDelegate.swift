import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // THROWAWAY T0 spike (flutter_pear-ovt.1.4): keeps SpikeBareHost alive for
  // the app's lifetime so its channel handlers aren't deallocated.
  private var spikeBareHost: SpikeBareHost?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    spikeBareHost = SpikeBareHost(messenger: engineBridge.applicationRegistrar.messenger())
  }
}
