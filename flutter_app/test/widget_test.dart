import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chat_app/main.dart';

void main() {
  testWidgets('login shows validation error on empty fields', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: ChatApp()));
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(find.text('Enter username and password'), findsOneWidget);
  });
}