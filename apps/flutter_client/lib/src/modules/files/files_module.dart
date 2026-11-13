// Files: browse the PC's files, preview them and download to the phone.

import 'package:flutter/material.dart';

import '../../shell/module.dart';
import '../../shell/module_extras.dart';
import '../../shell/shell_navigator.dart';
import '../../theme/nexus_theme.dart';
import '../../workspace/workspace_shell.dart';

class FilesModule extends NexusModule implements DescribedModule {
  const FilesModule();

  @override
  String get id => 'files';
  @override
  String get title => 'Files';
  @override
  String get subtitle => 'Browse · Download';
  @override
  Color get accent => NX.accent;
  @override
  IconData get icon => Icons.folder_rounded;
  @override
  CapabilityRequirement get requires =>
      const CapabilityRequirement.anyOf(['files']);
  @override
  int get order => 15;

  @override
  Widget buildEntry(BuildContext context, ModuleContext ctx) =>
      WorkspaceShell(
        key: const ValueKey('module-files'),
        tabs: const [WorkspaceTabs.files],
        onForeignTab: ShellNavigator.instance.openWorkspaceTab,
      );
}
