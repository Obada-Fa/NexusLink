// Walking-skeleton smoke test: the app builds and shows the connect screen.

import 'package:flutter_test/flutter_test.dart';

import 'package:nexuslink/main.dart';

void main() {
  testWidgets('Connect screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const NexusLinkApp());
    expect(find.text('NexusLink'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });
}
