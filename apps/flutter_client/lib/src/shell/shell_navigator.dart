// Lets code without a BuildContext (live activities, foreign workspace tabs,
// notification deep links) open a module on top of the home screen.

import '../workspace/workspace_shell.dart';

class ShellNavigator {
  ShellNavigator._();
  static final instance = ShellNavigator._();

  void Function(String moduleId)? _open;

  /// Registered by the home screen while it is mounted.
  void attach(void Function(String moduleId) open) => _open = open;
  void detach(void Function(String moduleId) open) {
    if (identical(_open, open)) _open = null;
  }

  /// Pops back to home and opens [moduleId]. No-op before home is mounted.
  void openModule(String moduleId) => _open?.call(moduleId);

  /// Opens the module that owns a NexusLink workspace tab.
  void openWorkspaceTab(int tab) => openModule(moduleForWorkspaceTab(tab));
}

/// Which compiled-in module shows each global workspace tab.
String moduleForWorkspaceTab(int tab) => switch (tab) {
  WorkspaceTabs.monitor => 'agents',
  WorkspaceTabs.files || WorkspaceTabs.terminal => 'terminal',
  _ => 'desktop',
};
