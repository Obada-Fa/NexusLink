// Home's Continue remembers the module (and task) opened from Home. Modules
// opened from inside it, or returned to, are detours and must not replace it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/main.dart';
import 'package:nexuslink/src/session/store.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/reachability.dart';
import 'package:nexuslink/src/shell/resume_store.dart';
import 'package:nexuslink/src/shell/shell_controller.dart';
import 'package:nexuslink/src/shell/shell_navigator.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/workspace/project.dart';
import 'package:nexuslink/src/workspace/workspace_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_connection.dart';
import 'fakes.dart';

Future<void> frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  testWidgets('a detour to another module keeps Continue on the Home task', (
    tester,
  ) async {
    resetAutoConnect();
    SharedPreferences.setMockInitialValues({});
    await TargetStore.save([hubTarget(utilities: {UtilityIds.nexuslink})]);
    await TargetStore.setCurrent('hub-office');
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionProvider.overrideWith(FakeConnection.new),
          reachabilityProberProvider.overrideWithValue(
            ReachabilityProber(connect: (_, _, _) async => true),
          ),
        ],
        child: Consumer(
          builder: (context, r, _) {
            ref = r;
            return const NexusApp();
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    LastDestination? last() => ref.read(lastDestinationsProvider)['hub-office'];

    // From Home: Terminal, where a shell is attached (the task).
    await tester.tap(find.byKey(const ValueKey('tile-terminal')));
    await frames(tester);
    expect(last()?.moduleId, 'terminal');
    await ref
        .read(lastDestinationsProvider.notifier)
        .note('hub-office', 'terminal', terminalId: 'shell-1', path: '/work');

    // Nested: Terminal → Desktop (a foreign workspace tab).
    ref.read(workspaceTabProvider.notifier).select(WorkspaceTabs.pc);
    await frames(tester);
    expect(find.byKey(const ValueKey('desktop-nav')), findsOneWidget);
    expect(last()?.moduleId, 'terminal', reason: 'a detour is not recorded');
    expect(last()?.terminalId, 'shell-1');
    // The detour's own task notes are ignored too.
    await ref
        .read(lastDestinationsProvider.notifier)
        .note('hub-office', 'desktop', path: '/elsewhere');
    expect(last()?.path, '/work');

    // Returning: a jump back to the module already open below.
    ShellNavigator.instance.openModule('terminal');
    await frames(tester);
    expect(
      tester.widget<WorkspaceShell>(find.byType(WorkspaceShell)).tabs,
      [WorkspaceTabs.terminal, WorkspaceTabs.files],
    );
    expect(last()?.moduleId, 'terminal');
    expect(last()?.terminalId, 'shell-1');

    // Nested again, then Back twice to Home.
    ShellNavigator.instance.openModule('desktop');
    await frames(tester);
    expect(last()?.moduleId, 'terminal');
    await tester.binding.handlePopRoute();
    await frames(tester);
    await tester.binding.handlePopRoute();
    await frames(tester);
    expect(find.byType(WorkspaceShell), findsNothing);
    expect(last()?.moduleId, 'terminal');
    expect(last()?.terminalId, 'shell-1');
    expect(last()?.path, '/work');
    expect(find.byKey(const ValueKey('continue-card')), findsOneWidget);

    // Persisted the same way (a cold start offers the same Continue).
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('${lastModuleKeyPrefix}hub-office'),
      contains('"terminalId":"shell-1"'),
    );

    // A module opened from Home itself does replace it.
    await tester.ensureVisible(find.byKey(const ValueKey('tile-desktop')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tile-desktop')));
    await frames(tester);
    expect(last()?.moduleId, 'desktop');
    expect(last()?.terminalId, isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
