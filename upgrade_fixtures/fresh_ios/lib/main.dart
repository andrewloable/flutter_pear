import 'package:flutter/material.dart';
import 'package:flutter_pear/flutter_pear.dart';

void main() {
  runApp(const FreshIosFixtureApp());
}

class FreshIosFixtureApp extends StatefulWidget {
  const FreshIosFixtureApp({super.key});

  @override
  State<FreshIosFixtureApp> createState() => _FreshIosFixtureAppState();
}

class _FreshIosFixtureAppState extends State<FreshIosFixtureApp> {
  String _status = 'starting...';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final pear = await Pear.start();
      // run_check.sh polls the captured `flutter run` log for this exact
      // string as the upgrade fixture's readiness marker -- keep both
      // sides in sync if either changes.
      // ignore: avoid_print
      print('FLUTTER_PEAR_FIXTURE_ATTACHED');
      setState(() => _status = 'worklet attached');
      await pear.dispose();
    } catch (e) {
      // ignore: avoid_print
      print('FLUTTER_PEAR_FIXTURE_FAILED: $e');
      setState(() => _status = 'failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(body: Center(child: Text(_status))),
      );
}
