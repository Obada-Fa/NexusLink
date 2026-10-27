// Confirmations, result messages, RustDesk setup help and the disconnect flow
// for the PC tab.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rpc/rpc_client.dart';
import '../state/connection.dart';
import '../theme/nexus_theme.dart';
import '../workspace/platform_bridge.dart';

/// Short confirm dialog. Returns true only on an explicit confirm.
Future<bool> confirmPcAction(
  BuildContext context, {
  required String title,
  required String body,
  required String confirm,
  IconData? icon,
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: icon == null
          ? null
          : Icon(icon, color: destructive ? NX.failed : NX.accent),
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: NX.failed,
                  foregroundColor: NX.bg,
                )
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return ok == true;
}

void showPcMessage(
  BuildContext context,
  String message, {
  SnackBarAction? action,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), action: action));
}

/// Readable text for a failed action future.
String pcActionError(Object error) =>
    'Couldn’t reach the PC: ${friendlyLaunchError(error)}';

const rustdeskSetupCommand = 'sudo bash packaging/rustdesk/install.sh';

bool mentionsOneTimeSetup(String message) =>
    message.contains('one-time setup') || message.contains('install.sh');

/// Explains the one-time RustDesk fix and lets the user copy the command.
Future<void> showRustdeskSetupSheet(BuildContext context, {String? message}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(NX.pad, 0, NX.pad, NX.pad + 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'One-time RustDesk setup',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          if (message != null) ...[
            const SizedBox(height: 8),
            Text(message, style: const TextStyle(color: NX.waiting)),
          ],
          const SizedBox(height: 12),
          const Text(
            'Run this once on the PC, in a terminal inside the NexusLink folder:',
            style: TextStyle(color: NX.textDim),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              color: NX.bg,
              borderRadius: BorderRadius.circular(NX.radiusSm),
              border: Border.all(color: NX.line),
            ),
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            child: Row(
              children: [
                const Expanded(
                  child: SelectableText(
                    rustdeskSetupCommand,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      color: NX.working,
                      fontSize: 13,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy command',
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () async {
                    await Clipboard.setData(
                      const ClipboardData(text: rustdeskSetupCommand),
                    );
                    if (ctx.mounted) showPcMessage(ctx, 'Command copied');
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          for (final line in const [
            'Makes RustDesk wait for your desktop at boot, so it never binds to the wrong display.',
            'Lets NexusLink restart RustDesk without a password — the automatic repair and this button then always work.',
            'Removes the duplicate Flatpak RustDesk that can steal the connection.',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.check_circle_outline,
                      size: 16,
                      color: NX.working,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(line, style: const TextStyle(color: NX.text)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          const Text(
            'Add --restart to apply it immediately instead of at the next boot.',
            style: TextStyle(color: NX.textFaint, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

/// Confirms, stops live monitoring, disconnects and returns to the connect
/// screen — the same steps as "Disconnect PC" in PC settings.
Future<void> disconnectFromPc(BuildContext context, WidgetRef ref) async {
  final ok = await confirmPcAction(
    context,
    title: 'Disconnect from this PC?',
    body:
        'You’ll go back to the connect screen. Agents, apps and terminals keep running on the PC.',
    confirm: 'Disconnect',
    icon: Icons.power_settings_new,
  );
  if (!ok || !context.mounted) return;
  if (Platform.isAndroid) {
    try {
      await PlatformBridge.call('live.stop');
    } catch (_) {
      // Live activity may already be stopped; disconnecting matters more.
    }
  }
  ref.read(connectionProvider.notifier).disconnect();
  if (context.mounted) {
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
  }
}
