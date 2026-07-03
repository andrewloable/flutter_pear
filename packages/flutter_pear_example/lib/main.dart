import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_pear/flutter_pear.dart';

void main() => runApp(const EchoApp());

/// M0 demo app.
class EchoApp extends StatelessWidget {
  /// Creates the demo app.
  const EchoApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
        title: 'flutter_pear echo',
        home: EchoScreen(),
      );
}

/// Sends bytes to the worklet and shows them coming back on `incoming` —
/// proving the Dart↔IPC round trip (native echo today; Bare worklet next).
class EchoScreen extends StatefulWidget {
  /// Creates the echo screen.
  const EchoScreen({super.key});

  @override
  State<EchoScreen> createState() => _EchoScreenState();
}

class _EchoScreenState extends State<EchoScreen> {
  final _input = TextEditingController();
  final _log = <String>[];
  Pear? _pear;

  @override
  void initState() {
    super.initState();
    Pear.start().then((pear) {
      _pear = pear;
      pear.worklet.incoming.listen((bytes) {
        setState(() => _log.add('◀ ${utf8.decode(bytes)}'));
      });
    });
  }

  Future<void> _send() async {
    final text = _input.text;
    final pear = _pear;
    if (text.isEmpty || pear == null) return;
    setState(() => _log.add('▶ $text'));
    await pear.worklet.send(Uint8List.fromList(utf8.encode(text)));
    _input.clear();
  }

  @override
  void dispose() {
    _pear?.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('flutter_pear echo (M0)')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [for (final line in _log) Text(line)],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      hintText: 'Type; it echoes back through the worklet',
                    ),
                  ),
                ),
                IconButton(onPressed: _send, icon: const Icon(Icons.send)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
