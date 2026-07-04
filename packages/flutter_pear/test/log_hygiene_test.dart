import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// E5.9 -- a grep-able assertion (not a static analyzer) that key material
// (or anything else) can never leak through a stray debug-print call,
// because no such call exists anywhere in flutter_pear's own production
// source in the first place. Deliberately zero-tolerance rather than
// "no print call containing a key" -- a library printing to the app's
// console at all is already a DX smell independent of key safety, and a
// blanket ban is far simpler to keep true than trying to distinguish safe
// prints from unsafe ones case by case.
//
// Not airtight: aliasing print (`final log = print; log(secret);`) defeats
// any grep-based check. That's an accepted limitation of "grep-able
// assertion, not a static analyzer" -- catching the straightforward case
// cheaply is the point, not building a linter.

/// Matches a `print(`/`debugPrint(` call, not a longer identifier that
/// merely ends in one (e.g. a future `PearKey.fingerprint()`).
final _printCall = RegExp(r'(?<![A-Za-z0-9_])(?:print|debugPrint)\(');

/// Every `.dart` file under [dir], recursively.
List<File> _dartFiles(Directory dir) => dir
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

/// Every `.js` file under [dir], recursively, skipping `node_modules`
/// (third-party code this project doesn't own or vet for this) --
/// includes first-party subdirectories like `pear-end/test/`.
List<File> _jsFiles(Directory dir) {
  final out = <File>[];
  for (final entry in dir.listSync()) {
    if (entry is Directory) {
      if (entry.uri.pathSegments.where((s) => s.isNotEmpty).last ==
          'node_modules') {
        continue;
      }
      out.addAll(_jsFiles(entry));
    } else if (entry is File && entry.path.endsWith('.js')) {
      out.add(entry);
    }
  }
  return out;
}

void main() {
  test(
      'no print()/debugPrint() call anywhere in flutter_pear\'s own lib/ '
      'source (E5.9 log-hygiene guardrail)', () {
    // `flutter test` runs with the package root as the working directory.
    final lib = Directory('${Directory.current.path}/lib');
    final offenders = <String>[];
    for (final file in _dartFiles(lib)) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // Skip comments (including dartdoc `///` examples) -- they don't
        // execute, so they can't leak anything, and a `print(...)` line
        // inside an illustrative ```dart doc example is legitimate.
        if (line.trimLeft().startsWith('//')) continue;
        if (_printCall.hasMatch(line)) {
          offenders.add('${file.path}:${i + 1}: ${line.trim()}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'a print()/debugPrint() call in library source is exactly '
            'the kind of accidental sink key material (or anything else) '
            'could leak through -- found:\n${offenders.join('\n')}');
  });

  test(
      'no console.* call anywhere in pear-end\'s own first-party JS source '
      '(E5.9 log-hygiene guardrail, JS side)', () {
    final pearEnd = Directory('${Directory.current.path}/pear-end');
    final offenders = <String>[];
    for (final file in _jsFiles(pearEnd)) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (line.contains('console.')) {
          offenders.add('${file.path}:${i + 1}: ${line.trim()}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'a console.* call in pear-end is exactly the kind of '
            'accidental sink key material (peer public keys, discovery '
            'topics, invite bytes) could leak through -- found:\n'
            '${offenders.join('\n')}');
  });
}
