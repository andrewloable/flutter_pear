// swift-tools-version:5.9
// THROWAWAY T0/T1 spike shim (flutter_pear-ovt.1.4, extended by
// flutter_pear-ovt.1.7): wraps the gitignored BareKit.xcframework and every
// pear-end native addon xcframework (symlinked from repo-root .spike/, see
// flutter_pear-ovt.1.2 and flutter_pear-ovt.1.5) as local Swift packages so
// the Runner app target embeds them all. Never committed as a real package
// -- productized packaging is a later epic (E3); this whole directory is
// throwaway. Each addon is its own binaryTarget/product (rather than one
// umbrella target) since Bare's runtime dlopens them individually by name at
// runtime -- nothing in Swift/ObjC ever imports them, they only need to be
// EMBEDDED into the app bundle, which SPM does automatically for any binary
// package product a target depends on.
import PackageDescription

let package = Package(
    name: "BareKitShim",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "BareKitShim", targets: ["BareKit"]),
        .library(name: "AddonBareFs", targets: ["AddonBareFs"]),
        .library(name: "AddonBareInspect", targets: ["AddonBareInspect"]),
        .library(name: "AddonBareOs", targets: ["AddonBareOs"]),
        .library(name: "AddonBareType", targets: ["AddonBareType"]),
        .library(name: "AddonBareUrl", targets: ["AddonBareUrl"]),
        .library(name: "AddonFsNativeExtensions", targets: ["AddonFsNativeExtensions"]),
        .library(name: "AddonQuickbitNative", targets: ["AddonQuickbitNative"]),
        .library(name: "AddonRabinNative", targets: ["AddonRabinNative"]),
        .library(name: "AddonRocksdbNative", targets: ["AddonRocksdbNative"]),
        .library(name: "AddonSimdleNative", targets: ["AddonSimdleNative"]),
        .library(name: "AddonSodiumNative", targets: ["AddonSodiumNative"]),
        .library(name: "AddonUdxNative", targets: ["AddonUdxNative"]),
    ],
    targets: [
        .binaryTarget(name: "BareKit", path: "BareKit.xcframework"),
        .binaryTarget(name: "AddonBareFs", path: "addons/bare-fs.4.7.3.xcframework"),
        .binaryTarget(name: "AddonBareInspect", path: "addons/bare-inspect.3.1.4.xcframework"),
        .binaryTarget(name: "AddonBareOs", path: "addons/bare-os.3.9.3.xcframework"),
        .binaryTarget(name: "AddonBareType", path: "addons/bare-type.1.1.0.xcframework"),
        .binaryTarget(name: "AddonBareUrl", path: "addons/bare-url.2.4.5.xcframework"),
        .binaryTarget(name: "AddonFsNativeExtensions", path: "addons/fs-native-extensions.1.5.0.xcframework"),
        .binaryTarget(name: "AddonQuickbitNative", path: "addons/quickbit-native.2.4.8.xcframework"),
        .binaryTarget(name: "AddonRabinNative", path: "addons/rabin-native.2.0.0.xcframework"),
        .binaryTarget(name: "AddonRocksdbNative", path: "addons/rocksdb-native.3.17.1.xcframework"),
        .binaryTarget(name: "AddonSimdleNative", path: "addons/simdle-native.1.3.9.xcframework"),
        .binaryTarget(name: "AddonSodiumNative", path: "addons/sodium-native.5.1.0.xcframework"),
        .binaryTarget(name: "AddonUdxNative", path: "addons/udx-native.1.20.7.xcframework"),
    ]
)
