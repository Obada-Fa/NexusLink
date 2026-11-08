// Desktop: mirror, launcher/apps and PC vitals over NexusLink.

import 'package:flutter/material.dart';

import '../../shell/module.dart';
import '../../shell/module_extras.dart';
import '../../shell/shell_navigator.dart';
import '../../theme/nexus_theme.dart';
import '../../workspace/workspace_shell.dart';

class DesktopModule extends NexusModule implements DescribedModule {
  const DesktopModule();

  @override
  String get id => 'desktop';
  @override
  String get title => 'Desktop';
  @override
  String get subtitle => 'Mirror · Apps · Vitals';
  @override
  Color get accent => NX.accent;
  @override
  IconData get icon => Icons.desktop_windows_rounded;
  @override
  CapabilityRequirement get requires =>
      const CapabilityRequirement.anyOf(['screen', 'apps']);
  @override
  int get order => 10;

  @override
  Widget buildEntry(BuildContext context, ModuleContext ctx) =>
      WorkspaceShell(
        key: const ValueKey('module-desktop'),
        tabs: const [WorkspaceTabs.pc],
        onForeignTab: ShellNavigator.instance.openWorkspaceTab,
      );
}
