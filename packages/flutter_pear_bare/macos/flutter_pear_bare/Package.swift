// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "flutter_pear_bare",
    platforms: [
        .macOS("10.15")
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
