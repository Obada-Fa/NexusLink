import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/widgets/app_error_view.dart';

class _Broken extends StatelessWidget {
  const _Broken();
  @override
  Widget build(BuildContext context) => throw StateError('boom');
}

void main() {
  late ErrorWidgetBuilder original;
  setUp(() {
    original = ErrorWidget.builder;
    ErrorWidget.builder = AppErrorView.fromDetails;
  });
  tearDown(() => ErrorWidget.builder = original);

  testWidgets('a failed widget shows Reload, even without MaterialApp', (
    t,
  ) async {
    await t.pumpWidget(const _Broken());
    expect(t.takeException(), isStateError);
    expect(find.text('This part of the app hit a problem'), findsOneWidget);
    expect(find.textContaining('boom'), findsOneWidget);

    final before = appReloadGeneration.value;
    await t.tap(find.text('Reload'));
    expect(appReloadGeneration.value, before + 1);
  });

  testWidgets('fits a tile and an unbounded list row', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(height: 60, width: 60, child: _Broken()),
              Expanded(child: _BrokenList()),
            ],
          ),
        ),
      ),
    );
    expect(t.takeException(), isNotNull);
    expect(find.text('Reload'), findsNWidgets(2));
  });
}

class _BrokenList extends StatelessWidget {
  const _BrokenList();
  @override
  Widget build(BuildContext context) => ListView(children: const [_Broken()]);
}
