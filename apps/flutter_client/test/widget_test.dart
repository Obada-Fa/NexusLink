// Walking-skeleton smoke test: the app builds and shows the connect screen.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nexuslink/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Connect screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: NexusLinkApp()));
    await tester.pump();
    expect(find.text('NexusLink'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('Connect screen suggests last connection', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'nexuslink-last-host-url': 'ws://192.168.2.30:45678/rpc',
    });
    await tester.pumpWidget(const ProviderScope(child: NexusLinkApp()));
    await tester.pump();
    await tester.pump(); // allow _loadLastHost future to settle
    expect(find.text('LAST CONNECTION'), findsOneWidget);
    expect(find.text('192.168.2.30:45678'), findsOneWidget);
    expect(find.text('ws://192.168.2.30:45678/rpc'), findsWidgets);
  });
}
