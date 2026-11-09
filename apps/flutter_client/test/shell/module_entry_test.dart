import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/shell/shell_navigator.dart';
import 'package:nexuslink/main.dart';
import 'package:nexuslink/src/session/store.dart';
import 'package:nexuslink/src/session/target.dart';
import 'package:nexuslink/src/shell/reachability.dart';
import 'package:nexuslink/src/shell/shell_controller.dart';
import 'package:nexuslink/src/state/connection.dart';
import 'package:nexuslink/src/workspace/project.dart';
import 'package:nexuslink/src/workspace/workspace_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_connection.dart';
import 'fakes.dart';

void main() {
  testWidgets('tiles open their module; a foreign tab opens its owner', (
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

    await tester.tap(find.byKey(const ValueKey('tile-terminal')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final shell = tester.widget<WorkspaceShell>(find.byType(WorkspaceShell));
    expect(shell.tabs, [WorkspaceTabs.terminal, WorkspaceTabs.files]);
    expect(find.widgetWithText(NavigationBar, 'Files'), findsOneWidget);
    expect(ref.read(workspaceTabProvider), WorkspaceTabs.terminal);

    // e.g. Mission Control's vitals chip selects the PC tab.
    ref.read(workspaceTabProvider.notifier).select(WorkspaceTabs.pc);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.widget<WorkspaceShell>(find.byType(WorkspaceShell)).tabs,
      [WorkspaceTabs.pc],
    );
    expect(find.byType(NavigationBar), findsNothing);

    // Back returns to Terminal, where the jump started, on its own tab.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.widget<WorkspaceShell>(find.byType(WorkspaceShell)).tabs,
      [WorkspaceTabs.terminal, WorkspaceTabs.files],
    );
    expect(ref.read(workspaceTabProvider), WorkspaceTabs.terminal);

    // A jump to a module that is already open goes back to it, not deeper.
    ref.read(workspaceTabProvider.notifier).select(WorkspaceTabs.pc);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    ShellNavigator.instance.openModule('terminal');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.widget<WorkspaceShell>(find.byType(WorkspaceShell)).tabs,
      [WorkspaceTabs.terminal, WorkspaceTabs.files],
    );

    // Back again returns home.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(WorkspaceShell), findsNothing);
    expect(find.byKey(const ValueKey('tile-desktop')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
