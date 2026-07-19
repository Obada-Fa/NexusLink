// Walking-skeleton smoke test: the app builds and shows the connect screen.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nexuslink/main.dart';

void main() {
  testWidgets('Connect screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: NexusLinkApp()));
    await tester.pump();
    expect(find.text('NexusLink'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });
}
