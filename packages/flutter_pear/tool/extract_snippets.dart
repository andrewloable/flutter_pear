// E8.2 -- extracts every marked README code snippet and runs `dart analyze`
// on it, so a README example can never silently drift from the real API
// again (the historical bug this exists to catch: `swarm.leave(topic)` in
// the README when the real method is `swarm.leave()`).
//
// MARKER CONVENTION: a fenced code block is extracted when its info string's
// first two whitespace-separated words are exactly `dart snippet` -- e.g.
// ` ```dart snippet `. GitHub only reads the first word of a fence's info
// string for syntax highlighting, so this still renders as ordinary
// highlighted Dart; the second word is just a marker this tool looks for.
// Matching is exact (not a prefix check), so a near-miss like
// ` ```dart snippets ` or ` ```dart snippet-wip ` is deliberately NOT
// extracted -- use those (or a plain ` ```dart `, no marker at all) for
// anything illustrative that isn't meant to compile standalone.
//
// Every marked block must have its own closing ``` before the next fence
// starts or the file ends -- an unclosed fence, or one closed by a LATER
// block's fence (silently merging two snippets into one corrupted blob),
// fails loudly instead of being silently dropped or mangled. This tool
// leans on one fact to detect that: Dart syntax never contains a bare
// triple-backtick line, so if one shows up inside an already-open fence,
// something went wrong with the fencing, not the snippet.
//
// ponytail: doesn't handle a fence's own body legitimately containing a
// literal ``` line (e.g. a Dart string demonstrating Markdown) -- that's a
// rare, deliberately unhandled case for this tool's own small, curated set
// of README snippets; if it's ever needed, don't mark that block `snippet`.
// Also doesn't tolerate CommonMark's indented-fence syntax (fences nested
// under a list item) -- this repo's own READMEs don't nest snippets that way.
//
// Usage: `dart run tool/extract_snippets.dart <README.md> [<README.md> ...]`,
// run from the `flutter_pear` package directory (so the generated file's
// imports resolve against this package's own dependency graph) with one or
// more README paths relative to that directory. Run from CI via
// .github/workflows/ci.yml.

import 'dart:io';

/// One extracted `dart snippet` block, in document order across every
/// README passed to [main] -- [index] is globally unique, used to name its
/// generated wrapper function.
typedef Snippet = ({int index, String body});

/// A snippet's `import` statements (which must stay top-level in the
/// generated file, wherever they appeared in the original snippet)
/// separated from the rest of its body (which gets wrapped in a function,
/// since a README snippet is written as if it were already inside one).
typedef SplitSnippet = ({List<String> imports, String body});

final _fenceStart = RegExp(r'^```(.*)$');

bool _isSnippetMarker(String info) {
  final tokens = info.trim().split(RegExp(r'\s+'));
  return tokens.length >= 2 && tokens[0] == 'dart' && tokens[1] == 'snippet';
}

/// Finds every fenced code block in [markdown] marked `dart snippet` (see
/// this file's header for the exact convention) and returns their bodies in
/// document order, indexed starting at [startIndex].
///
/// Throws a [StateError] if a marked fence is never closed, or if a bare
/// ``` line turns up inside one -- see this file's header for why that's
/// treated as corruption rather than silently dropped or included as-is.
List<Snippet> extractDartSnippets(String markdown, {int startIndex = 0}) {
  final snippets = <Snippet>[];
  String? currentInfo;
  final body = StringBuffer();
  var index = startIndex;

  for (final line in markdown.split('\n')) {
    if (currentInfo == null) {
      final match = _fenceStart.firstMatch(line);
      if (match != null) currentInfo = match.group(1)!.trim();
      continue;
    }
    if (line.trimRight() == '```') {
      if (_isSnippetMarker(currentInfo)) {
        snippets.add((index: index++, body: body.toString()));
      }
      currentInfo = null;
      body.clear();
      continue;
    }
    if (_fenceStart.hasMatch(line)) {
      throw StateError(
          'extract_snippets: found a line that looks like a markdown code '
          'fence ("${line.trim()}") inside a still-open ```$currentInfo``` '
          'block -- likely an earlier fence was never closed (or was closed '
          'with mismatched indentation) and swallowed this one. Every '
          '```dart snippet``` block must be closed with its own bare ``` '
          'before the next fence starts.');
    }
    body.writeln(line);
  }
  if (currentInfo != null) {
    throw StateError('extract_snippets: unterminated code fence (opened '
        'with "```$currentInfo") -- reached end of file without a closing '
        '```.');
  }
  return snippets;
}

/// Splits [snippetBody] into its `import` lines (wherever they appear) and
/// the remaining lines in their original relative order.
SplitSnippet splitImports(String snippetBody) {
  final imports = <String>[];
  final rest = <String>[];
  for (final line in snippetBody.split('\n')) {
    if (line.trim().startsWith('import ')) {
      imports.add(line.trim());
    } else {
      rest.add(line);
    }
  }
  return (imports: imports, body: rest.join('\n'));
}

/// Renders every snippet into one throwaway, analyzable Dart file: imports
/// hoisted and deduplicated at the top, each snippet's remaining statements
/// wrapped in its own private `async` function. Private names keep this
/// generated, never-run, never-imported file's functions out of the way --
/// they exist only so `dart analyze` has something to type-check.
String generateAnalysisFile(List<Snippet> snippets) {
  final allImports = <String>{};
  final functions = StringBuffer();
  for (final snippet in snippets) {
    final split = splitImports(snippet.body);
    allImports.addAll(split.imports);
    functions
      ..writeln('Future<void> _snippet${snippet.index}() async {')
      ..writeln(split.body)
      ..writeln('}')
      ..writeln();
  }
  final sortedImports = allImports.toList()..sort();
  // Referencing (not calling -- this file is only ever analyzed, never
  // run) each function keeps `unused_element` from flagging every snippet.
  final references = snippets.map((s) => '  _snippet${s.index};').join('\n');
  return '// GENERATED by tool/extract_snippets.dart -- DO NOT EDIT.\n'
      '// Source: every ```dart snippet``` block in the README(s) passed to '
      'this tool.\n'
      '${sortedImports.join('\n')}\n'
      '\n'
      '$functions'
      'void main() {\n'
      '$references\n'
      '}\n';
}

Future<void> main(List<String> args) async {
  final readmePaths = args.isEmpty ? ['../../README.md'] : args;
  final snippets = <Snippet>[];

  for (final path in readmePaths) {
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('extract_snippets: no README at $path');
      exitCode = 2;
      return;
    }
    snippets.addAll(extractDartSnippets(file.readAsStringSync(),
        startIndex: snippets.length));
  }

  if (snippets.isEmpty) {
    stderr.writeln(
        'extract_snippets: no ```dart snippet``` blocks found in ${readmePaths.join(', ')}');
    exitCode = 2;
    return;
  }

  final outFile = File('test/readme_snippets.g.dart')
    ..writeAsStringSync(generateAnalysisFile(snippets));
  stdout.writeln(
      'extract_snippets: wrote ${snippets.length} snippet(s) from ${readmePaths.length} file(s) to ${outFile.path}');

  final result = await Process.run('dart', ['analyze', outFile.path]);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  exitCode = result.exitCode;
}
