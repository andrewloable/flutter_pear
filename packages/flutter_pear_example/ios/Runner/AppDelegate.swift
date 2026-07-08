import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Owned here rather than created per-call: this instance is the delegate
  // for whichever UIDocumentInteractionController is currently presenting a
  // preview, so it must outlive that single presentation.
  private let shareOpenChannel = ShareOpenChannel()

  // Owned here for the same reason: holds pendingResult across the async
  // gap between presenting UIDocumentPickerViewController and its delegate
  // callback.
  private let filePickerChannel = FilePickerChannel()

  // Owned here for the same reason: holds pendingResult across the async
  // gap between presenting QrScannerViewController and its result callback.
  private let qrScannerChannel = QrScannerChannel()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    shareOpenChannel.register(with: engineBridge.pluginRegistry)
    filePickerChannel.register(with: engineBridge.pluginRegistry)
    qrScannerChannel.register(with: engineBridge.pluginRegistry)
  }
}

// `UIWindowScene.keyWindow` needs iOS 15 -- this app's deployment target is
// iOS 13 (Runner.xcodeproj's IPHONEOS_DEPLOYMENT_TARGET), so the key window
// is found the iOS-13-safe way instead: every scene's windows, filtered to
// the one marked key. Shared by every native channel in this file that
// needs a view controller to present from.
private func iosRootViewController() -> UIViewController? {
  UIApplication.shared.connectedScenes
    .compactMap { $0 as? UIWindowScene }
    .flatMap { $0.windows }
    .first { $0.isKeyWindow }?.rootViewController
}

/// Native handler for the "flutter_pear_example/share_open" method channel
/// (DES-T1 / eng review round 2 item 5) -- opens a received file via
/// `UIDocumentInteractionController` (falling back to its options menu if
/// no in-app preview is available) and shares a file or plain text via
/// `UIActivityViewController`. `ShareOpenChannel` on the Dart side is the
/// typed wrapper around this exact contract.
final class ShareOpenChannel: NSObject, UIDocumentInteractionControllerDelegate {
  // Must be retained for the duration of the preview/menu presentation --
  // UIDocumentInteractionController does not retain itself, and a
  // locally-scoped instance would be deallocated (silently dismissing the
  // preview) before the user ever sees it.
  private var presentingController: UIDocumentInteractionController?

  func register(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "ShareOpenChannel") else { return }
    let channel = FlutterMethodChannel(
      name: "flutter_pear_example/share_open",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result) ?? result(FlutterMethodNotImplemented)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "openFile":
      guard let path = args?["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "path is required", details: nil))
        return
      }
      openFile(path: path, result: result)
    case "shareFile":
      guard let path = args?["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "path is required", details: nil))
        return
      }
      share(items: [URL(fileURLWithPath: path)], result: result)
    case "shareText":
      guard let text = args?["text"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "text is required", details: nil))
        return
      }
      share(items: [text], result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Presents an in-app preview of [path], falling back to the "open in"
  /// options menu if no preview is available for its type. Resolves
  /// `false` (never throws to Dart) if there's no presenting view
  /// controller or the file doesn't exist, so the caller can show a
  /// snackbar instead of crashing.
  private func openFile(path: String, result: @escaping FlutterResult) {
    guard let root = iosRootViewController(), FileManager.default.fileExists(atPath: path) else {
      result(false)
      return
    }
    let controller = UIDocumentInteractionController(url: URL(fileURLWithPath: path))
    controller.delegate = self
    presentingController = controller
    let presented = controller.presentPreview(animated: true)
      || controller.presentOptionsMenu(from: root.view.bounds, in: root.view, animated: true)
    if !presented { presentingController = nil }
    result(presented)
  }

  /// Presents `UIActivityViewController` for [items] (a file URL or plain
  /// text). Resolves `false` if there's no presenting view controller.
  private func share(items: [Any], result: @escaping FlutterResult) {
    guard let root = iosRootViewController() else {
      result(false)
      return
    }
    let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
    // iPad requires a popover anchor or UIActivityViewController crashes on
    // presentation -- anchor to the root view's center, since these actions
    // aren't tied to a specific on-screen button (this file's channel is
    // called from a card's Open/Share text button in file_drop_screen.dart,
    // but the anchor only needs to be a valid, reasonably-placed point).
    activity.popoverPresentationController?.sourceView = root.view
    activity.popoverPresentationController?.sourceRect = CGRect(
      x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0
    )
    root.present(activity, animated: true)
    result(true)
  }

  func documentInteractionControllerDidEndPreview(_ controller: UIDocumentInteractionController) {
    presentingController = nil
  }

  func documentInteractionControllerViewControllerForPreview(
    _ controller: UIDocumentInteractionController
  ) -> UIViewController {
    iosRootViewController() ?? UIViewController()
  }
}

/// Native handler for the "flutter_pear_example/file_picker" method channel
/// (D13, outside-voice verified) -- presents `UIDocumentPickerViewController`
/// in `.open` mode and copies the picked, security-scoped document into this
/// app's own caches directory before resolving. `UIDocumentPickerViewController`
/// hands back a security-scoped URL, not a durable path -- `PearDrive.put`
/// (the Dart caller's eventual destination) needs a plain local path that
/// outlives this call, so the copy happens between
/// `startAccessingSecurityScopedResource` and `stopAccessingSecurityScopedResource`,
/// mirroring MainActivity.kt's `copyUriToCache` for the Android leg.
/// `FilePickerChannel` on the Dart side is the typed wrapper.
final class FilePickerChannel: NSObject, UIDocumentPickerDelegate {
  // Exactly one pick in flight at a time -- mirrors MainActivity.kt's
  // pendingPickFileResult: a second pickFile call before the first resolves
  // must not silently orphan it.
  private var pendingResult: FlutterResult?

  func register(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "FilePickerChannel") else { return }
    let channel = FlutterMethodChannel(
      name: "flutter_pear_example/file_picker",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "pickFile" {
        self?.pickFile(result: result) ?? result(FlutterMethodNotImplemented)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func pickFile(result: @escaping FlutterResult) {
    guard let root = iosRootViewController() else {
      result(FlutterError(code: "FILE_PICK_FAILED", message: "no presenting view controller", details: nil))
      return
    }
    // See the matching comment on ShareOpenChannel's presentingController --
    // don't silently orphan an overlapping call.
    pendingResult?(FlutterError(
      code: "SUPERSEDED", message: "A newer pickFile call replaced this one", details: nil
    ))
    pendingResult = result
    // The UTI-string initializer, not `forOpeningContentTypes:` (iOS 14+) --
    // this app's deployment target is iOS 13 (Runner.xcodeproj's
    // IPHONEOS_DEPLOYMENT_TARGET). "public.item" is the UTI equivalent of
    // UTType.item -- any file type selectable, matching Android's "*/*".
    // `.open` mode (not `.import`) is deliberate, matching D13's explicit
    // security-scoped-copy requirement below rather than relying on
    // UIDocumentPickerViewController's own opaque auto-copy-to-Inbox
    // behavior.
    let picker = UIDocumentPickerViewController(documentTypes: ["public.item"], in: .open)
    picker.delegate = self
    root.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let result = pendingResult
    pendingResult = nil
    guard let url = urls.first else {
      result?(nil)
      return
    }
    do {
      let copyPath = try copyToOwnedCache(url)
      result?(["path": copyPath, "name": url.lastPathComponent])
    } catch {
      result?(FlutterError(code: "FILE_PICK_FAILED", message: error.localizedDescription, details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = pendingResult
    pendingResult = nil
    result?(nil)
  }

  /// Copies [url] (a security-scoped `UIDocumentPickerViewController`
  /// result) into a freshly-named subdirectory of this app's caches
  /// directory, returning the copy's path. Each pick gets its own
  /// randomly-named subdirectory -- same reasoning as
  /// MainActivity.kt's `copyUriToCache`: two picks sharing a display name
  /// must not resolve to the same path and truncate each other.
  private func copyToOwnedCache(_ url: URL) throws -> String {
    let didStartAccess = url.startAccessingSecurityScopedResource()
    defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
    let pickDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("picked_files", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: pickDir, withIntermediateDirectories: true)
    let destination = pickDir.appendingPathComponent(sanitizedFileName(url.lastPathComponent))
    try FileManager.default.copyItem(at: url, to: destination)
    return destination.path
  }

  /// Reduces [name] down to a bare file name with no directory components --
  /// same defensive reasoning as MainActivity.kt's `sanitizeFileName`, even
  /// though a `URL`'s `lastPathComponent` should already be exactly that.
  private func sanitizedFileName(_ name: String) -> String {
    let candidate = (name as NSString).lastPathComponent
    return candidate.isEmpty || candidate == "." || candidate == ".." ? "picked_file" : candidate
  }
}

/// Native handler for the "flutter_pear_example/qr_scanner" method channel
/// (E7.2's iOS counterpart) -- the exact same four-method contract
/// MainActivity.kt implements for Android via CameraX + ML Kit, here via
/// AVFoundation, so `QrScannerChannel` on the Dart side stays byte-identical
/// across platforms. iOS never re-shows its camera permission dialog once a
/// decision is made (unlike Android's soft "denied, can ask again" state),
/// so any non-authorized status after a request maps to `permanentlyDenied`
/// -- Settings is always the only way forward from there.
final class QrScannerChannel: NSObject {
  // Exactly one scan in flight -- mirrors MainActivity.kt's
  // pendingScanResult: a second scanQrCode call before the first resolves
  // must not silently orphan it.
  private var pendingResult: FlutterResult?
  // Retained so it isn't deallocated mid-presentation.
  private var presentedScanner: QrScannerViewController?

  func register(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "QrScannerChannel") else { return }
    let channel = FlutterMethodChannel(
      name: "flutter_pear_example/qr_scanner",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result) ?? result(FlutterMethodNotImplemented)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "checkCameraPermission":
      result(Self.statusString(for: AVCaptureDevice.authorizationStatus(for: .video)))
    case "requestCameraPermission":
      requestCameraPermission(result: result)
    case "scanQrCode":
      scanQrCode(result: result)
    case "openAppSettings":
      openAppSettings(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func statusString(for status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "granted"
    case .notDetermined: return "notDetermined"
    case .denied, .restricted: return "permanentlyDenied"
    @unknown default: return "permanentlyDenied"
    }
  }

  /// `requestAccess` only actually shows the OS dialog when the current
  /// status is `.notDetermined`; for `.denied`/`.restricted` it resolves
  /// immediately with `granted == false` and no UI -- re-reading
  /// `authorizationStatus` afterward is what maps that back to the right
  /// string via [statusString].
  private func requestCameraPermission(result: @escaping FlutterResult) {
    AVCaptureDevice.requestAccess(for: .video) { _ in
      DispatchQueue.main.async {
        result(Self.statusString(for: AVCaptureDevice.authorizationStatus(for: .video)))
      }
    }
  }

  private func openAppSettings(result: @escaping FlutterResult) {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      result(false)
      return
    }
    DispatchQueue.main.async {
      UIApplication.shared.open(url)
    }
    result(true)
  }

  private func scanQrCode(result: @escaping FlutterResult) {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      result(FlutterError(code: "PERMISSION_DENIED", message: "Camera permission is not granted", details: nil))
      return
    }
    guard let root = iosRootViewController() else {
      result(nil)
      return
    }
    pendingResult?(FlutterError(
      code: "SUPERSEDED", message: "A newer scanQrCode call replaced this one", details: nil
    ))
    pendingResult = result
    let scanner = QrScannerViewController { [weak self] decoded in
      self?.finishScan(with: decoded)
    }
    presentedScanner = scanner
    root.present(scanner, animated: true)
  }

  private func finishScan(with value: String?) {
    let result = pendingResult
    pendingResult = nil
    presentedScanner = nil
    result?(value)
  }
}

/// Full-screen QR scanner (E7.2's iOS counterpart to `QrScannerActivity.kt`)
/// -- `AVCaptureSession` + `AVCaptureVideoPreviewLayer` +
/// `AVCaptureMetadataOutput` restricted to `.qr`. The first decoded string
/// calls [onResult] and dismisses; a visible Cancel button calls
/// `onResult(nil)` and dismisses. If no capture device is available (the
/// iOS Simulator has none), shows a brief message and calls `onResult(nil)`
/// instead of crashing.
final class QrScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  private let onResult: (String?) -> Void
  private var captureSession: AVCaptureSession?
  private var didFinish = false

  init(onResult: @escaping (String?) -> Void) {
    self.onResult = onResult
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    // Matches QrScannerActivity.kt's android:screenOrientation="portrait" --
    // locking orientation avoids tracking the preview layer's frame across
    // rotation entirely.
    .portrait
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    addCancelButton()
    startSession()
  }

  private func addCancelButton() {
    let button = UIButton(type: .system)
    button.setTitle("Cancel", for: .normal)
    button.setTitleColor(.white, for: .normal)
    button.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
    button.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(button)
    NSLayoutConstraint.activate([
      button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      button.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
    ])
  }

  @objc private func cancelTapped() {
    finish(with: nil)
  }

  private func startSession() {
    guard let device = AVCaptureDevice.default(for: .video),
          let input = try? AVCaptureDeviceInput(device: device) else {
      showUnavailableMessage()
      return
    }
    let session = AVCaptureSession()
    guard session.canAddInput(input) else {
      showUnavailableMessage()
      return
    }
    session.addInput(input)

    let output = AVCaptureMetadataOutput()
    guard session.canAddOutput(output) else {
      showUnavailableMessage()
      return
    }
    session.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: .main)
    output.metadataObjectTypes = [.qr]

    let previewLayer = AVCaptureVideoPreviewLayer(session: session)
    previewLayer.frame = view.bounds
    previewLayer.videoGravity = .resizeAspectFill
    view.layer.insertSublayer(previewLayer, at: 0)

    captureSession = session
    DispatchQueue.global(qos: .userInitiated).async {
      session.startRunning()
    }
  }

  /// The Simulator (no capture device) and a real device with no camera
  /// hardware both land here -- shown briefly rather than dismissing
  /// instantly, so a developer testing on the Simulator sees *why* nothing
  /// happened instead of the screen just flashing shut.
  private func showUnavailableMessage() {
    let label = UILabel()
    label.text = "Camera unavailable -- use the code below instead."
    label.textColor = .white
    label.textAlignment = .center
    label.numberOfLines = 0
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
      label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
    ])
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      self?.finish(with: nil)
    }
  }

  func metadataOutput(
    _ output: AVCaptureMetadataOutput,
    didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
          object.type == .qr,
          let value = object.stringValue else { return }
    finish(with: value)
  }

  private func finish(with value: String?) {
    guard !didFinish else { return }
    didFinish = true
    captureSession?.stopRunning()
    dismiss(animated: true) { [weak self] in
      self?.onResult(value)
    }
  }
}
