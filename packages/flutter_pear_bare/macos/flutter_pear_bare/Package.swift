// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "flutter_pear_bare",
    platforms: [
        // 10.15.4, not 10.15 (flutter_pear-a4p): FileHandle.write(contentsOf:)
        // -- the throwing, NSException-safe stdin write Defect 2's fix
        // needs -- is @available(macOS 10.15.4+).
        .macOS("10.15.4")
    ],
    products: [
        .library(name: "flutter-pear-bare", targets: ["flutter_pear_bare"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "flutter_pear_bare",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
