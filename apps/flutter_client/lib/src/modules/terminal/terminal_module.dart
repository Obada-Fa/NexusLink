// Terminal: PC shells, files and the editor over NexusLink.

import 'package:flutter/material.dart';

import '../../shell/module.dart';
import '../../shell/module_extras.dart';
import '../../shell/shell_navigator.dart';
import '../../theme/nexus_theme.dart';
import '../../workspace/workspace_shell.dart';

class TerminalModule extends NexusModule implements DescribedModule {
  const TerminalModule();

  @override
  String get id => 'terminal';
  @override
  String get title => 'Terminal';
  @override
  String get subtitle => 'Shells · Files · Editor';
  @override
  Color get accent => NX.working;
  @override
  IconData get icon => Icons.terminal_rounded;
  @override
  CapabilityRequirement get requires =>
      const CapabilityRequirement.anyOf(['terminal']);
  @override
  int get order => 30;

  @override
  Widget buildEntry(BuildContext context, ModuleContext ctx) =>
      WorkspaceShell(
        key: const ValueKey('module-terminal'),
        tabs: const [WorkspaceTabs.terminal, WorkspaceTabs.files],
        onForeignTab: ShellNavigator.instance.openWorkspaceTab,
      );
}
