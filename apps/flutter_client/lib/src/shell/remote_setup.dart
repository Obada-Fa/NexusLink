import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../session/target.dart';
import '../theme/nexus_theme.dart';
import 'target_actions.dart';

const remoteSetupUrl = 'https://github.com/Obada-Fa/nexus-remote#development';

/// Discovery and installation help before a PC has a Remote pairing.
Future<void> showRemoteSetup(
  BuildContext context,
  WidgetRef ref,
  SavedTarget target,
) async {
  final scan = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Set up Remote', style: Theme.of(sheet).textTheme.titleLarge),
            const SizedBox(height: 12),
            const Text(
              'Use this phone as your PC’s trackpad, keyboard and media remote.',
            ),
            const SizedBox(height: 8),
            Text(
              'Remote is not paired with ${target.name}. The phone cannot tell whether its PC companion is installed.',
              style: const TextStyle(color: NX.textDim),
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Install on PC'),
              subtitle: const Text('Nexus Remote companion · Linux/X11'),
              children: [
                const Text(
                  'Install and start the Nexus Remote companion on your PC. NexusLink alone does not include it. This development companion supports a logged-in Linux/X11 desktop; Windows and Wayland input are not supported.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'The source setup instructions explain building the companion and speech worker. You need Rust/Cargo, CMake, a C++ compiler, Python 3, playerctl and pactl. The portable launcher downloads a 574 MB speech model on first run.',
                ),
                const SizedBox(height: 12),
                const SelectableText(remoteSetupUrl),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Copy PC installation link'),
                  onPressed: () async {
                    await Clipboard.setData(
                      const ClipboardData(text: remoteSetupUrl),
                    );
                    if (sheet.mounted) {
                      ScaffoldMessenger.of(sheet).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'PC installation link copied. Open it on your PC.',
                          ),
                        ),
                      );
                    }
                  },
                ),
                const SizedBox(height: 12),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Already installed?',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'On your PC, open Nexus Utilities, start Remote, then choose Add phone. Scan its QR code here to pair Remote with this phone.',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => Navigator.pop(sheet, true),
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text('Scan QR to pair Remote'),
            ),
          ],
        ),
      ),
    ),
  );
  if (scan == true && context.mounted) await startPairing(context, ref);
}
