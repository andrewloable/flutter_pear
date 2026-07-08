import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/check_pins.dart';

void main() {
  test(
      'checkPins finds zero mismatches against this repo\'s real, current '
      'state, with exactly the 1 not-yet-landed leg skipped', () {
    // `flutter test` runs with the package root as the working directory --
    // exactly the pkgRoot check_pins.dart itself expects.
    final pkgRoot = Directory.current.path;
    final result = checkPins(pkgRoot);
    expect(result.mismatches, isEmpty,
        reason: result.mismatches.map((m) => m.describe()).join('\n'));
    expect(result.skipped, hasLength(1),
        reason: 'only the podspec should still be skipped (it reads '
            'barekit-pin.json dynamically at pod-install time, '
            'flutter_pear-ovt.3.6, so it has no independent literal pin to '
            'cross-check) -- Package.swift now carries a real, published '
            'BareKit url+checksum (flutter_pear-ovt.6.1\'s own discovery: '
            'the earlier PENDING-UPLOAD sentinel was resolved). If this '
            'count changed, a leg landed or un-landed and this test (and '
            'the fixture below) needs updating');
  });

  test(
      'a self-consistent fixture with every leg landed (including the '
      'not-yet-real ones) passes with zero mismatches and zero skips', () {
    final fixture = _buildFixture(
      barekitPinJson: const {
        'bareKitVersion': '2.3.0',
        'upstreamSha256':
            'a386063fa405b0bb4967490e84745075f007f95359c9871c5b7a45c18c2f49e2',
      },
      packageSwiftContent: _packageSwift(
        version: '2.3.0',
        checksum:
            'a386063fa405b0bb4967490e84745075f007f95359c9871c5b7a45c18c2f49e2',
      ),
      podspecContent: _podspec(
        version: '2.3.0',
        sha256:
            'a386063fa405b0bb4967490e84745075f007f95359c9871c5b7a45c18c2f49e2',
      ),
      swiftHostContent: _swiftHost(assetName: 'assets/pear-end.bundle'),
    );
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    final result = checkPins(fixture.pkgRoot);
    expect(result.mismatches, isEmpty,
        reason: result.mismatches.map((m) => m.describe()).join('\n'));
    expect(result.skipped, isEmpty);
  });

  test(
      'the default fixture (no optional legs created) skips exactly the 4 '
      'not-yet-landed legs, matching the real repo\'s own shape', () {
    final fixture = _buildFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    final result = checkPins(fixture.pkgRoot);
    expect(result.mismatches, isEmpty);
    expect(result.skipped, hasLength(4));
  });

  test(
      'a BareKit version mismatch between build.gradle and barekit-pin.json '
      'is caught and named exactly, with both files and both values', () {
    final fixture = _buildFixture(
      bareKitVersionInGradle: '2.3.0',
      barekitPinJson: {'bareKitVersion': '9.9.9', 'upstreamSha256': 'aa' * 32},
    );
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    final result = checkPins(fixture.pkgRoot);
    final versionMismatches =
        result.mismatches.where((m) => m.field == 'BareKit version');
    expect(versionMismatches, hasLength(1));
    final m = versionMismatches.single;
    expect(
      m.describe(),
      allOf(contains('2.3.0'), contains('9.9.9'), contains('build.gradle'),
          contains('barekit-pin.json')),
    );
  });

  test(
      'a BareKit sha256 mismatch between build.gradle and barekit-pin.json '
      'is caught and named exactly', () {
    final fixture = _buildFixture(
      bareKitSha256InGradle: 'aa' * 32,
      barekitPinJson: {'bareKitVersion': '2.3.0', 'upstreamSha256': 'bb' * 32},
    );
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    final result = checkPins(fixture.pkgRoot);
    final shaMismatches =
        result.mismatches.where((m) => m.field.startsWith('BareKit sha256'));
    expect(shaMismatches, hasLength(1));
    expect(shaMismatches.single.field, 'BareKit sha256 (upstream)');
    expect(
      shaMismatches.single.describe(),
      allOf(contains('aa' * 32), contains('bb' * 32)),
    );
  });

  test(
      'a bundle asset name mismatch in pubspec.yaml (vs pack.dart\'s real '
      'bundleAssetPath) is caught and named', () {
    final fixture =
        _buildFixture(pubspecBundleAssetName: 'assets/wrong-name.bundle');
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    final result = checkPins(fixture.pkgRoot);
    final assetMismatches = result.mismatches
        .where((m) => m.field == 'Bundle asset name' && m.sourceA.contains('pubspec.yaml'));
    expect(assetMismatches, hasLength(1));
    expect(
      assetMismatches.single.describe(),
      allOf(contains('assets/wrong-name.bundle'),
          contains('assets/pear-end.bundle')),
    );
  });

  test(
      'a bundle asset name mismatch in the Kotlin host\'s '
      'BUNDLE_ASSET_SUBPATH is caught and named', () {
    final fixture = _buildFixture(
        kotlinBundleAssetSubpath: 'assets/some-other.bundle');
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    final result = checkPins(fixture.pkgRoot);
    final assetMismatches = result.mismatches.where(
        (m) => m.field == 'Bundle asset name' && m.sourceA.contains('.kt'));
    expect(assetMismatches, hasLength(1));
    expect(assetMismatches.single.valueA, 'assets/some-other.bundle');
  });

  test(
      'a bundle asset name mismatch in a landed Swift host is caught and '
      'named', () {
    final fixture = _buildFixture(
        swiftHostContent: _swiftHost(assetName: 'assets/ios-wrong.bundle'));
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    final result = checkPins(fixture.pkgRoot);
    final assetMismatches = result.mismatches
        .where((m) => m.field == 'Bundle asset name' && m.sourceA.contains('.swift'));
    expect(assetMismatches, hasLength(1));
    expect(assetMismatches.single.valueA, 'assets/ios-wrong.bundle');
  });

  test(
      'a baked bundle version absent from the committed bundle\'s bytes is '
      'caught and named (the version stamp itself drifted from what '
      'actually shipped)', () {
    final fixture = _buildFixture(
        bakedBundleVersion: 'deadbeefcafe0001',
        bundleContainsBakedVersion: false);
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    final result = checkPins(fixture.pkgRoot);
    final versionMismatches =
        result.mismatches.where((m) => m.field == 'Baked bundle version');
    expect(versionMismatches, hasLength(1));
    expect(versionMismatches.single.valueA, 'deadbeefcafe0001');
  });

  test(
      'a Package.swift checksum mismatch against barekit-pin.json\'s '
      'repackedSha256 (its own lineage) is caught and named', () {
    final fixture = _buildFixture(
      barekitPinJson: {
        'bareKitVersion': '2.3.0',
        'upstreamSha256': _defaultSha256,
        'repackedSha256': 'dd' * 32,
      },
      packageSwiftContent: _packageSwift(version: '2.3.0', checksum: 'cc' * 32),
    );
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    final result = checkPins(fixture.pkgRoot);
    final shaMismatches =
        result.mismatches.where((m) => m.field == 'BareKit sha256 (repacked)');
    expect(shaMismatches, hasLength(1),
        reason: result.mismatches.map((m) => m.describe()).join('\n'));
    expect(
      shaMismatches.single.describe(),
      allOf(contains('cc' * 32), contains('dd' * 32)),
    );
  });

  test(
      'a Package.swift checksum is NEVER compared against build.gradle\'s '
      'upstream checksum -- they pin different artifacts (repacked vs '
      'upstream) and must not cross-compare, even when barekit-pin.json '
      'stays unlanded so there is nothing in Package.swift\'s own lineage '
      'to check it against', () {
    final fixture = _buildFixture(
      bareKitSha256InGradle: _defaultSha256,
      packageSwiftContent:
          _packageSwift(version: '2.3.0', checksum: 'cc' * 32),
    );
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    final result = checkPins(fixture.pkgRoot);
    expect(result.skipped, hasLength(3)); // barekit-pin.json, podspec, swift host
    expect(result.mismatches, isEmpty,
        reason: result.mismatches.map((m) => m.describe()).join('\n'));
  });

  test(
      'a real, generated Package.swift whose BareKit url is still the '
      'PENDING-UPLOAD sentinel (flutter_pear-ovt.2.3\'s intentional '
      'upload-skip state) is gracefully skipped, not a thrown parse error '
      '(flutter_pear-ovt.2.4)', () {
    final fixture = _buildFixture(
      packageSwiftContent: '''
// swift-tools-version:5.9
import Foundation
import PackageDescription
let bareKitURL = ProcessInfo.processInfo.environment["FLUTTER_PEAR_BAREKIT_URL"] ?? "PENDING-UPLOAD: run `dart run flutter_pear:pack --repack-barekit` to publish and fill this in"
let package = Package(
    name: "BareKitShim",
    targets: [
        .binaryTarget(name: "BareKit", url: bareKitURL, checksum: "${'a' * 64}")
    ]
)
''',
    );
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    final result = checkPins(fixture.pkgRoot);
    expect(result.mismatches, isEmpty,
        reason: result.mismatches.map((m) => m.describe()).join('\n'));
    expect(
        result.skipped.any((s) => s.contains('Package.swift') && s.contains('PENDING-UPLOAD')),
        isTrue,
        reason: 'expected a PENDING-UPLOAD skip entry, got: ${result.skipped}');
  });
}

class _Fixture {
  _Fixture(this.root, this.pkgRoot);
  final Directory root;
  final String pkgRoot;
}

const _defaultVersion = '2.3.0';
const _defaultSha256 =
    'a386063fa405b0bb4967490e84745075f007f95359c9871c5b7a45c18c2f49e2';
const _defaultBakedVersion = 'e21b84c0cfec344d';

/// Builds a minimal, self-consistent fixture tree mirroring this repo's real
/// layout (packages/flutter_pear + packages/flutter_pear_bare) so
/// [checkPins] can run against it exactly as it would against the real
/// monorepo. Every value agrees by construction unless overridden, letting a
/// test introduce exactly one deliberate mismatch at a time. The
/// not-yet-landed legs (barekit-pin.json, Package.swift, the podspec, the
/// Swift host) are omitted by default, matching the real repo's current
/// shape -- pass the matching `*Content`/`*Json` parameter to simulate one
/// having landed.
_Fixture _buildFixture({
  String bareKitVersionInGradle = _defaultVersion,
  String bareKitSha256InGradle = _defaultSha256,
  String pubspecBundleAssetName = 'assets/pear-end.bundle',
  String kotlinBundleAssetSubpath = 'assets/pear-end.bundle',
  String bakedBundleVersion = _defaultBakedVersion,
  bool bundleContainsBakedVersion = true,
  Map<String, String>? barekitPinJson,
  String? packageSwiftContent,
  String? podspecContent,
  String? swiftHostContent,
}) {
  final root = Directory.systemTemp.createTempSync('fp_check_pins');
  final pkgRoot = '${root.path}/packages/flutter_pear';
  final bareRoot = '${root.path}/packages/flutter_pear_bare';
  Directory('$pkgRoot/lib/src').createSync(recursive: true);
  Directory('$pkgRoot/assets').createSync(recursive: true);
  Directory('$bareRoot/android/src/main/kotlin/tech/loable/flutter_pear_bare')
      .createSync(recursive: true);

  File('$pkgRoot/pubspec.yaml').writeAsStringSync('''
name: flutter_pear
version: 0.0.1

flutter:
  assets:
    - $pubspecBundleAssetName
''');

  File('$pkgRoot/lib/src/bundle_version.dart').writeAsStringSync('''
const String kPearEndBundleVersion = '$bakedBundleVersion';
''');

  File('$pkgRoot/assets/pear-end.bundle').writeAsBytesSync(utf8.encode(
      bundleContainsBakedVersion
          ? 'fixture bundle bytes ... $bakedBundleVersion ... more bytes'
          : 'fixture bundle bytes with no version stamp inside'));

  File('$bareRoot/android/build.gradle').writeAsStringSync('''
def bareKitVersion = "$bareKitVersionInGradle"
def bareKitSha256 = "$bareKitSha256InGradle"
''');

  File('$bareRoot/android/src/main/kotlin/tech/loable/flutter_pear_bare/FlutterPearBarePlugin.kt')
      .writeAsStringSync('''
private const val BUNDLE_ASSET_SUBPATH = "$kotlinBundleAssetSubpath"
''');

  if (barekitPinJson != null) {
    File('$bareRoot/barekit-pin.json').writeAsStringSync(jsonEncode(barekitPinJson));
  }
  if (packageSwiftContent != null) {
    Directory('$bareRoot/ios/BareKitShim').createSync(recursive: true);
    File('$bareRoot/ios/BareKitShim/Package.swift')
        .writeAsStringSync(packageSwiftContent);
  }
  if (podspecContent != null) {
    Directory('$bareRoot/ios').createSync(recursive: true);
    File('$bareRoot/ios/flutter_pear_bare.podspec')
        .writeAsStringSync(podspecContent);
  }
  if (swiftHostContent != null) {
    Directory('$bareRoot/ios/Classes').createSync(recursive: true);
    File('$bareRoot/ios/Classes/FlutterPearBareHost.swift')
        .writeAsStringSync(swiftHostContent);
  }

  return _Fixture(root, pkgRoot);
}

String _packageSwift({required String version, required String checksum}) => '''
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "BareKitShim",
    targets: [
        .binaryTarget(
            name: "BareKit",
            url: "https://github.com/holepunchto/bare-kit/releases/download/v$version/BareKit.xcframework.zip",
            checksum: "$checksum"
        )
    ]
)
''';

String _podspec({required String version, required String sha256}) => '''
Pod::Spec.new do |s|
  s.name = "flutter_pear_bare"
  s.script_phase = {
    :name => "FetchBareKit",
    :script => "curl -L https://github.com/holepunchto/bare-kit/releases/download/v$version/prebuilds.zip -o prebuilds.zip; echo expected sha256:$sha256"
  }
end
''';

String _swiftHost({required String assetName}) => '''
import Flutter
private let bundleAssetSubpath = "$assetName"
func startWorklet() {
  let key = FlutterDartProject.lookupKey(forAsset: bundleAssetSubpath, fromPackage: "flutter_pear")
}
''';
