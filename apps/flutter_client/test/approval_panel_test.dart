import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/monitor/approvals.dart';
import 'package:nexuslink/src/theme/nexus_theme.dart';

typedef Call = ({
  String id,
  bool allow,
  Map<String, String>? answers,
  String? message,
});

class FakeApprovals extends ApprovalsNotifier {
  FakeApprovals(this.items, this.calls);
  final List<ExternalApproval> items;
  final List<Call> calls;
  @override
  ApprovalsState build() => ApprovalsState(items: items);
  @override
  Future<String?> resolve(
    ExternalApproval approval, {
    required bool allow,
    Map<String, String>? answers,
    String? message,
  }) async {
    calls.add((
      id: approval.id,
      allow: allow,
      answers: answers,
      message: message,
    ));
    return null;
  }
}

ExternalApproval approval(Map<String, dynamic> json) =>
    ExternalApproval({'id': 'a1', 'chatId': 'c1', 'mirrored': true, ...json});

Future<List<Call>> pump(WidgetTester t, ExternalApproval a) async {
  final calls = <Call>[];
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        approvalsProvider.overrideWith(() => FakeApprovals([a], calls)),
      ],
      child: MaterialApp(
        theme: nexusTheme(),
        home: Scaffold(
          body: SingleChildScrollView(child: ApprovalPanel(approval: a)),
        ),
      ),
    ),
  );
  return calls;
}

void main() {
  testWidgets('a tool approval shows the command and allows', (t) async {
    final calls = await pump(
      t,
      approval({
        'kind': 'approval',
        'title': 'Run: npm test',
        'detail': 'npm test -- --watch',
      }),
    );
    expect(find.text('Needs approval'), findsOneWidget);
    expect(find.text('npm test -- --watch'), findsOneWidget);
    expect(
      find.text('Also open on your PC. Whichever you answer first wins.'),
      findsOneWidget,
    );
    await t.tap(find.text('Allow'));
    await t.pump();
    expect(calls.single.allow, isTrue);
  });

  testWidgets('deny can carry a note', (t) async {
    final calls = await pump(
      t,
      approval({'kind': 'approval', 'title': 'Run: rm -rf build'}),
    );
    await t.tap(find.text('Deny with a note'));
    await t.pump();
    await t.enterText(find.byType(TextField), 'Not on main');
    await t.tap(find.text('Send deny'));
    await t.pump();
    expect(calls.single, (
      id: 'a1',
      allow: false,
      answers: null,
      message: 'Not on main',
    ));
  });

  testWidgets('a question is sent only once every question has an answer', (
    t,
  ) async {
    final calls = await pump(
      t,
      approval({
        'kind': 'question',
        'title': 'Which port?',
        'questions': [
          {
            'question': 'Which port?',
            'header': 'Port',
            'options': [
              {'label': '8080'},
              {'label': '3000', 'description': 'dev server'},
            ],
          },
        ],
      }),
    );
    final send = find.widgetWithText(FilledButton, 'Send answer');
    expect(t.widget<FilledButton>(send).onPressed, isNull);
    await t.tap(find.text('3000'));
    await t.pump();
    await t.tap(send);
    await t.pump();
    expect(calls.single.allow, isTrue);
    expect(calls.single.answers, {'Which port?': '3000'});
  });

  testWidgets('a typed answer works too', (t) async {
    final calls = await pump(
      t,
      approval({
        'kind': 'question',
        'title': 'Name?',
        'questions': [
          {
            'question': 'Name?',
            'options': [
              {'label': 'A'},
            ],
          },
        ],
      }),
    );
    await t.enterText(find.byType(TextField), 'Nexus');
    await t.pump();
    await t.tap(find.text('Send answer'));
    await t.pump();
    expect(calls.single.answers, {'Name?': 'Nexus'});
  });

  testWidgets('a plan is approved, or sent back with feedback', (t) async {
    final calls = await pump(
      t,
      approval({
        'kind': 'plan',
        'title': 'Approve the plan',
        'detail': '1. Add tests',
      }),
    );
    expect(find.text('1. Add tests'), findsOneWidget);
    await t.tap(find.text('Keep planning'));
    await t.pump();
    expect(calls, isEmpty);
    await t.enterText(find.byType(TextField), 'Also update the README');
    await t.tap(find.text('Send feedback'));
    await t.pump();
    expect(calls.single.allow, isFalse);
    expect(calls.single.message, 'Also update the README');
  });
}
