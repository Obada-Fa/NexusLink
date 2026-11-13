import 'package:flutter/material.dart';

import '../workspace/workspace_shell.dart';

/// Phone settings stay reachable without opening a PC tool or connecting a PC.
class AppSettingsButton extends StatelessWidget {
  const AppSettingsButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('home-settings'),
    tooltip: 'Settings',
    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    icon: const Icon(Icons.settings_outlined),
    onPressed: () => Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'settings'),
        builder: (_) => const PcScreen(phoneFirst: true),
      ),
    ),
  );
}
