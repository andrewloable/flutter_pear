// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "flutter_pear_bare",
    platforms: [
        // 12.0, raised from 10.15.4 in 0.4.2 (flutter_pear-na0): Xcode 27
        // refuses to target macOS below 12.0 at all ("the range of supported
        // deployment target versions is 12.0 to 27.0.x"), so the old floor
        // was unbuildable rather than merely unverified. The API that
        // originally forced 10.15.4 over 10.15 (FileHandle.write(contentsOf:),
        // @available(macOS 10.15.4+), flutter_pear-a4p) is comfortably below
        // this floor and needs no availability guard.
        .macOS("12.0")
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
            ],
            // Committed by bin/pack.dart's buildDesktopBundle
            // (flutter_pear-9ng): the desktop pear-end.bundle + its
            // offloaded native addons for BOTH darwin hosts -- a universal
            // macOS binary decides which one actually runs at OS launch
            // time depending on the CPU underneath it (natively on Apple
            // Silicon, under Rosetta otherwise), not at build time, so both
            // must travel together even though only one is ever read by a
            // given launch (see FlutterPearBarePlugin.swift's `#if arch`).
            // `.copy` (not `.process`) because these are opaque data files
            // bare's own require() reads by relative path, not something
            // Xcode's resource compiler should transform. Resolved at
            // runtime via the SPM-synthesized `Bundle.module` accessor.
            resources: [.copy("Resources/desktop")]
        )
    ]
)
