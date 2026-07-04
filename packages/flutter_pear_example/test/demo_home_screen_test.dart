import 'package:flutter_pear_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatApp home screen', () {
    testWidgets('shows both demo entry points', (tester) async {
      await tester.pumpWidget(const ChatApp());
      expect(find.text('Chat demo'), findsOneWidget);
      expect(find.text('File drop demo'), findsOneWidget);
    });

    testWidgets('Chat demo navigates to the chat screen', (tester) async {
      await tester.pumpWidget(const ChatApp());
      await tester.tap(find.text('Chat demo'));
      await tester.pumpAndSettle();
      expect(find.text('flutter_pear chat'), findsOneWidget);
    });

    testWidgets('File drop demo navigates to the file-drop screen',
        (tester) async {
      await tester.pumpWidget(const ChatApp());
      await tester.tap(find.text('File drop demo'));
      await tester.pumpAndSettle();
      expect(find.text('flutter_pear file drop'), findsOneWidget);
    });
  });
}
