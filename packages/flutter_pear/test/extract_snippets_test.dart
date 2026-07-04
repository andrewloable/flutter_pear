import 'package:flutter_test/flutter_test.dart';

import '../tool/extract_snippets.dart';

void main() {
  test('extracts a ```dart snippet``` block and ignores plain ```dart```', () {
    final markdown = '''
# Title

```dart snippet
final x = 1;
```

Some prose.

```dart
// not marked, should be ignored
```

```yaml
key: value
```
''';
    final snippets = extractDartSnippets(markdown);
    expect(snippets, hasLength(1));
    expect(snippets.single.body, contains('final x = 1;'));
  });

  test('extracts multiple snippets in document order', () {
    final markdown = '''
```dart snippet
final a = 1;
```

```dart snippet
final b = 2;
```
''';
    final snippets = extractDartSnippets(markdown);
    expect(snippets, hasLength(2));
    expect(snippets[0].index, 0);
    expect(snippets[0].body, contains('final a = 1;'));
    expect(snippets[1].index, 1);
    expect(snippets[1].body, contains('final b = 2;'));
  });

  test('extractDartSnippets can start numbering from a given index', () {
    final snippets = extractDartSnippets('''
```dart snippet
final a = 1;
```
''', startIndex: 5);
    expect(snippets.single.index, 5);
  });

  test('marker matching is exact, not a prefix -- near misses are ignored', () {
    for (final info in [
      'dart snippets',
      'dart snippet-other',
      'dart snippet2'
    ]) {
      final markdown = '```$info\nfinal x = 1;\n```\n';
      expect(extractDartSnippets(markdown), isEmpty,
          reason: '"$info" must not match the `dart snippet` marker');
    }
  });

  test('an unclosed fence throws instead of silently dropping the snippet', () {
    expect(
      () => extractDartSnippets('```dart snippet\nfinal x = 1;\n'),
      throwsStateError,
    );
  });

  test(
      'a bare ``` line inside an open fence throws instead of silently '
      'merging the next block into it', () {
    final markdown = '''
```dart snippet
final a = 1;
// oops, missing the real closing fence below
```dart snippet
final b = 2;
```
''';
    expect(() => extractDartSnippets(markdown), throwsStateError);
  });

  test('splitImports hoists import lines wherever they appear in the body', () {
    final split = splitImports('''
import 'dart:convert';
import 'package:flutter_pear/flutter_pear.dart';

final pear = await Pear.start();
''');
    expect(split.imports, [
      "import 'dart:convert';",
      "import 'package:flutter_pear/flutter_pear.dart';",
    ]);
    expect(split.body, contains('final pear = await Pear.start();'));
    expect(split.body, isNot(contains('import')));
  });

  test('splitImports handles a snippet with no imports', () {
    final split = splitImports('final x = 1;');
    expect(split.imports, isEmpty);
    expect(split.body, contains('final x = 1;'));
  });

  test('splitImports hoists an import that appears after a leading comment',
      () {
    final split = splitImports('''
// A leading comment
import 'dart:io';

stdout.writeln('hi');
''');
    expect(split.imports, ["import 'dart:io';"]);
    expect(split.body, isNot(contains('import')));
    expect(split.body, contains("stdout.writeln('hi');"));
  });

  test('splitImports hoists an import written mid-snippet', () {
    final split = splitImports('''
final pear = await Pear.start();
import 'dart:convert';
print(utf8.encode('hi'));
''');
    expect(split.imports, ["import 'dart:convert';"]);
    expect(split.body, isNot(contains('import')));
    expect(split.body, contains('final pear = await Pear.start();'));
    expect(split.body, contains("print(utf8.encode('hi'));"));
  });

  test(
      'generateAnalysisFile dedupes imports and wraps each snippet in its '
      'own private function', () {
    final generated = generateAnalysisFile([
      (index: 0, body: "import 'dart:convert';\nfinal a = 1;"),
      (index: 1, body: "import 'dart:convert';\nfinal b = 2;"),
    ]);
    expect("import 'dart:convert';".allMatches(generated), hasLength(1));
    expect(generated, contains('Future<void> _snippet0() async {'));
    expect(generated, contains('Future<void> _snippet1() async {'));
    // Every snippet function must be referenced somewhere, or `dart
    // analyze` flags it as unused_element (a false-positive failure
    // unrelated to whether the snippet itself is correct).
    expect(generated, contains('_snippet0;'));
    expect(generated, contains('_snippet1;'));
  });
}
