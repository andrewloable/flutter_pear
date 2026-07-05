import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/check_compatibility.dart';

void main() {
  test(
      'checkCompatibility finds zero mismatches against this repo\'s real, '
      'current state (E9.5 VALIDATION: "CI green")', () {
    // `flutter test` runs with the package root as the working directory --
    // exactly the pkgRoot check_compatibility.dart itself expects
    // (`cd packages/flutter_pear && dart run bin/check_compatibility.dart`).
    final pkgRoot = Directory.current.path;
    final mismatches = checkCompatibility(pkgRoot);
    expect(mismatches, isEmpty,
        reason: mismatches.map((m) => m.describe()).join('\n'));
  });

  test(
      'a deliberately mutated pin is caught and named exactly (E9.5 '
      'VALIDATION: "mutate one pin locally -> check fails naming the exact '
      'mismatch")', () {
    final fixture = _buildFixture(bareKitVersionInGradle: '9.9.9');
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    final mismatches = checkCompatibility(fixture.pkgRoot);

    expect(mismatches, hasLength(1));
    final mismatch = mismatches.single;
    expect(mismatch.field, 'Bare Kit');
    expect(mismatch.tableValue, '2.3.0');
    expect(mismatch.actualValue, '9.9.9');
    expect(mismatch.actualSource, contains('build.gradle'));
    // The rendered message names the field and both disagreeing values --
    // the literal "which value where" the ticket's STEP 2 asks for.
    expect(
      mismatch.describe(),
      allOf(
        contains('Bare Kit'),
        contains('2.3.0'),
        contains('9.9.9'),
        contains('build.gradle'),
      ),
    );
  });

  test(
      'assertCompatibilityMatches throws CompatibilityMismatchException '
      'naming the mismatch, mirroring pack.dart\'s LicenseViolationException '
      'style', () {
    final fixture = _buildFixture(bareKitVersionInGradle: '9.9.9');
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    expect(
      () => assertCompatibilityMatches(fixture.pkgRoot),
      throwsA(isA<CompatibilityMismatchException>().having(
        (e) => e.toString(),
        'message',
        allOf(contains('Bare Kit'), contains('2.3.0'), contains('9.9.9')),
      )),
    );
  });

  test(
      'a self-consistent fixture (no mutated pin) passes with zero '
      'mismatches -- proves the synthetic fixture itself is a valid '
      'baseline, not just an artifact of the mutation', () {
    final fixture = _buildFixture(bareKitVersionInGradle: '2.3.0');
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    expect(checkCompatibility(fixture.pkgRoot), isEmpty);
  });

  test(
      'a mismatched Hyper* dependency version (pear-end/package.json) is '
      'caught and named, not just the Bare Kit field', () {
    final fixture = _buildFixture(autobaseVersionInPackageJson: '99.0.0');
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    final mismatches = checkCompatibility(fixture.pkgRoot);

    expect(mismatches, hasLength(1));
    expect(mismatches.single.field, 'autobase');
    expect(mismatches.single.tableValue, '7.28.1');
    expect(mismatches.single.actualValue, '99.0.0');
    expect(mismatches.single.actualSource, contains('package.json'));
  });

  test(
      'a missing COMPATIBILITY.md fails loud with a CompatibilityCheckException '
      'rather than a silent pass or a crash', () {
    final fixture = _buildFixture(writeCompatibilityMd: false);
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    expect(
      () => checkCompatibility(fixture.pkgRoot),
      throwsA(isA<CompatibilityCheckException>().having(
        (e) => e.toString(),
        'message',
        contains('COMPATIBILITY.md'),
      )),
    );
  });

  test(
      'a decoy "melos:" mention in a comment above dev_dependencies does not '
      'shadow the real pin (regression: the unanchored, comment-blind regex '
      'used to match the decoy comment\'s old value instead of the real, '
      'drifted dev_dependencies pin, producing a false PASS)', () {
    final fixture = _buildFixture(
      melosVersionInWorkspacePubspec: '^7.9.9',
      workspacePubspecMelosDecoyComment: '^6.3.2',
    );
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    final mismatches = checkCompatibility(fixture.pkgRoot);

    expect(mismatches, hasLength(1));
    expect(mismatches.single.field, 'Melos');
    expect(mismatches.single.tableValue, '^6.3.2');
    expect(mismatches.single.actualValue, '^7.9.9');
  });

  test(
      'a matching decoy "melos:" comment does not itself cause a false '
      'mismatch when the real pin genuinely agrees with the table', () {
    final fixture = _buildFixture(
      workspacePubspecMelosDecoyComment: '^9.9.9',
    );
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    expect(checkCompatibility(fixture.pkgRoot), isEmpty);
  });

  test(
      'a leftover ndkVersion pin inside a gitignored/generated build/ '
      'directory is not treated as a real, source-controlled pin '
      '(regression: the recursive android/ scan used to walk into Gradle '
      'build-output/cache dirs)', () {
    final fixture = _buildFixture(addGeneratedBuildDirNdkOffender: true);
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    expect(checkCompatibility(fixture.pkgRoot), isEmpty);
  });

  test(
      'an ndkVersion mention inside a // comment in a real, tracked '
      'build.gradle is not treated as a real pin (regression: the '
      'ndkVersion regex used to have no comment-awareness)', () {
    final fixture = _buildFixture(addNdkVersionInsideComment: true);
    addTearDown(() => fixture.root.deleteSync(recursive: true));

    expect(checkCompatibility(fixture.pkgRoot), isEmpty);
  });
}

class _Fixture {
  _Fixture(this.root, this.pkgRoot);
  final Directory root;
  final String pkgRoot;
}

/// Builds a minimal, self-consistent fixture tree mirroring this repo's real
/// layout (repo root with COMPATIBILITY.md/CLAUDE.md/pubspec.yaml, and
/// packages/{flutter_pear,flutter_pear_bare,flutter_pear_example}) so
/// [checkCompatibility] can run against it exactly as it would against the
/// real monorepo. Every value agrees with the fixture's own COMPATIBILITY.md
/// by construction unless overridden by one of the optional parameters,
/// letting a test introduce exactly one deliberate mismatch at a time.
_Fixture _buildFixture({
  String bareKitVersionInGradle = '2.3.0',
  String autobaseVersionInPackageJson = '7.28.1',
  bool writeCompatibilityMd = true,
  String melosVersionInWorkspacePubspec = '^6.3.2',
  String? workspacePubspecMelosDecoyComment,
  bool addGeneratedBuildDirNdkOffender = false,
  bool addNdkVersionInsideComment = false,
}) {
  final root = Directory.systemTemp.createTempSync('fp_check_compat');
  final pkgRoot = '${root.path}/packages/flutter_pear';
  Directory('$pkgRoot/pear-end').createSync(recursive: true);
  Directory('${root.path}/packages/flutter_pear_bare/android')
      .createSync(recursive: true);
  Directory(
          '${root.path}/packages/flutter_pear_example/android/gradle/wrapper')
      .createSync(recursive: true);

  File('$pkgRoot/pubspec.yaml').writeAsStringSync('''
name: flutter_pear
version: 0.0.1

environment:
  sdk: '>=3.5.0 <4.0.0'
  flutter: '>=3.24.0'

dependencies:
  flutter:
    sdk: flutter
''');

  File('${root.path}/packages/flutter_pear_bare/pubspec.yaml')
      .writeAsStringSync('''
name: flutter_pear_bare
version: 0.0.1

environment:
  sdk: '>=3.5.0 <4.0.0'
  flutter: '>=3.24.0'

dependencies:
  flutter:
    sdk: flutter
''');

  File('${root.path}/packages/flutter_pear_bare/android/build.gradle')
      .writeAsStringSync('''
buildscript {
    ext.kotlin_version = "1.9.24"
    dependencies {
        classpath "com.android.tools.build:gradle:8.3.0"
    }
}

def bareKitVersion = "$bareKitVersionInGradle"
def bareKitAbis = ["arm64-v8a", "x86_64"]

android {
    compileSdk = 34

    defaultConfig {
        minSdk = 24
    }
}
'''
          '${addNdkVersionInsideComment ? '\n// ndkVersion = "25.0.0"\n' : ''}');

  if (addGeneratedBuildDirNdkOffender) {
    final offenderDir = Directory(
        '${root.path}/packages/flutter_pear_bare/android/build/fake_exploded_aar')
      ..createSync(recursive: true);
    File('${offenderDir.path}/build.gradle')
        .writeAsStringSync('ndkVersion = "25.1.8937393"\n');
  }

  File('$pkgRoot/pear-end/package.json').writeAsStringSync('''
{
  "name": "pear-end",
  "version": "0.0.1",
  "dependencies": {
    "autobase": "$autobaseVersionInPackageJson",
    "bare-fs": "4.7.3",
    "bare-path": "3.0.1",
    "blind-pairing": "2.3.1",
    "blind-pairing-core": "2.10.1",
    "compact-encoding": "3.3.0",
    "corestore": "7.11.0",
    "hyperbee": "2.27.3",
    "hypercore-crypto": "3.7.0",
    "hyperdrive": "13.3.2",
    "hyperswarm": "4.17.0",
    "localdrive": "2.2.1",
    "mirror-drive": "1.14.2",
    "protomux": "3.11.0",
    "streamx": "2.28.0"
  }
}
''');

  File('${root.path}/packages/flutter_pear_example/android/gradle/wrapper/gradle-wrapper.properties')
      .writeAsStringSync('''
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\\://services.gradle.org/distributions/gradle-9.1.0-all.zip
''');

  final melosDecoyLine = workspacePubspecMelosDecoyComment == null
      ? ''
      : '# historical note: this repo has used '
          'melos: $workspacePubspecMelosDecoyComment since the initial bd '
          'init\n';
  File('${root.path}/pubspec.yaml').writeAsStringSync('''
name: flutter_pear_workspace

${melosDecoyLine}dev_dependencies:
  melos: $melosVersionInWorkspacePubspec
''');

  File('${root.path}/CLAUDE.md').writeAsStringSync('''
## Toolchain

| Tool | For | Notes |
|---|---|---|
| JDK 17 + Android SDK/NDK | build plugin + example | fixture |
''');

  if (writeCompatibilityMd) {
    File('${root.path}/COMPATIBILITY.md').writeAsStringSync('''
## Plugin ↔ Bare Kit ↔ Hyper* module versions

| flutter_pear version | Bare Kit | autobase | bare-fs | bare-path | blind-pairing | blind-pairing-core | compact-encoding | corestore | hyperbee | hypercore-crypto | hyperdrive | hyperswarm | localdrive | mirror-drive | protomux | streamx |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.0.1 | 2.3.0 | 7.28.1 | 4.7.3 | 3.0.1 | 2.3.1 | 2.10.1 | 3.3.0 | 7.11.0 | 2.27.3 | 3.7.0 | 13.3.2 | 4.17.0 | 2.2.1 | 1.14.2 | 3.11.0 | 2.28.0 |

## Toolchain

| flutter_pear version | Flutter SDK | Dart SDK | Melos | Android Gradle Plugin (flutter_pear_bare) | Kotlin (flutter_pear_bare) | Gradle (example app dev/CI wrapper) | Android compileSdk | Android minSdk | Android NDK | Supported ABIs | JDK |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.0.1 | >=3.24.0 | >=3.5.0 <4.0.0 | ^6.3.2 | 8.3.0 | 1.9.24 | 9.1.0 | 34 | 24 | not pinned | arm64-v8a, x86_64 | 17 |
''');
  }

  return _Fixture(root, pkgRoot);
}
