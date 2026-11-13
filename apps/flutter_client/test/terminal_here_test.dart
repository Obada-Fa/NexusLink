import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/screens/terminal_screen.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/workspace/terminal_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'workspace_terminal_test.dart' show TerminalHost;

/// Records which shell each terminal view asked for.
class _RecordingRepository extends TerminalRepository {
  final requests = <({String? cwd, String? terminalId})>[];
  @override
  RemoteTerminal get(String key, {String? cwd, String? terminalId}) {
    requests.add((cwd: cwd, terminalId: terminalId));
    return super.get(key, cwd: cwd, terminalId: terminalId);
  }
}

Future<_RecordingRepository> _open(
  WidgetTester tester, {
  String? initialCwd,
}) async {
  final host = TerminalHost();
  final repository = _RecordingRepository()..bind(host);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeClientProvider.overrideWithValue(host),
        terminalRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(home: TerminalScreen(initialCwd: initialCwd)),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

void main() {
  testWidgets('Open terminal here never reattaches another folder\'s shell', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'terminal:selected:pc': 'shell-a',
      'terminal:selected-cwd:pc': '/home/me/project-a',
    });
    final repository = await _open(tester, initialCwd: '/home/me/project-b');
    expect(repository.requests, isNotEmpty);
    expect(repository.requests.last.terminalId, isNull);
    expect(repository.requests.last.cwd, '/home/me/project-b');
    expect(find.text('/home/me/project-b'), findsOneWidget);
    // The new shell becomes the remembered one, with its folder.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('terminal:selected-cwd:pc'), '/home/me/project-b');
  });

  testWidgets('Open terminal here reuses the last shell in the same folder', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'terminal:selected:pc': 'shell-b',
      'terminal:selected-cwd:pc': '/home/me/project-b',
    });
    final repository = await _open(tester, initialCwd: '/home/me/project-b');
    expect(repository.requests.last.terminalId, 'shell-b');
  });

  testWidgets('a selection saved without its folder is not trusted', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'terminal:selected:pc': 'old'});
    final repository = await _open(tester, initialCwd: '/home/me/project-b');
    expect(repository.requests.last.terminalId, isNull);
  });

  testWidgets('the Terminal tab still restores the PC\'s last shell', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'terminal:selected:pc': 'shell-a',
      'terminal:selected-cwd:pc': '/home/me/project-a',
    });
    final repository = await _open(tester);
    expect(repository.requests.last.terminalId, 'shell-a');
    expect(find.text('/home/me/project-a'), findsOneWidget);
  });
}
