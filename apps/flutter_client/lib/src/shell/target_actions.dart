// Per-target actions shared by the device picker and the home screen:
// rename/icon, wake, wake settings, remove, and pairing via the QR flow.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/wake_settings_sheet.dart';
import '../services/wake_service.dart';
import '../session/enrollment/pairing_flow.dart';
import '../session/target.dart';
import '../state/connection.dart';
import '../state/last_host.dart';
import '../state/saved_devices.dart' show SavedDevice, deviceIcons;
import '../theme/nexus_theme.dart';
import 'auto_connect.dart';
import 'reachability.dart';
import 'shell_controller.dart';

export '../state/saved_devices.dart' show deviceIcons;

IconData targetIcon(String icon) => switch (icon) {
  'laptop' => Icons.laptop_mac_rounded,
  'server' => Icons.dns_rounded,
  'gaming' => Icons.sports_esports_rounded,
  _ => Icons.desktop_windows_rounded,
};

String utilityName(String utility) => switch (utility) {
  UtilityIds.nexuslink => 'NexusLink',
  UtilityIds.remote => 'Remote',
  UtilityIds.audio => 'Audio',
  _ => utility,
};

/// The address shown under a target's name.
String targetAddressLabel(SavedTarget target) {
  final url = nexusLinkUrlOf(target);
  if (url != null) return lastHostLabel(url);
  for (final link in target.utilities.values) {
    final hosts = probeHosts(target, link);
    if (hosts.isNotEmpty) return hosts.first;
  }
  return target.addresses.ordered.firstOrNull ?? '';
}

/// Key for the wake token and the URL the wake flow polls: the NexusLink ws
/// URL when paired (what saved devices always used), else the first utility.
String wakeKeyOf(SavedTarget target) {
  final url = nexusLinkUrlOf(target);
  if (url != null) return url;
  for (final link in target.utilities.values) {
    final hosts = probeHosts(target, link);
    if (hosts.isNotEmpty) return 'ws://${hosts.first}:${probePort(link)}/rpc';
  }
  return target.id;
}

/// The wake sheet still speaks [SavedDevice]; this adapts a target to it.
SavedDevice wakeDeviceOf(SavedTarget target) => SavedDevice(
  url: wakeKeyOf(target),
  name: target.name,
  icon: target.icon,
  wake: target.wake,
);

/// Runs the QR pairing flow; NexusLink enrolls through the shared connection.
Future<SavedTarget?> startPairing(BuildContext context, WidgetRef ref) async {
  final target = await PairingFlow.run(
    context,
    enrollNexusLink: (wsUrl, code) => ref
        .read(connectionProvider.notifier)
        .connect(wsUrl, pairingCode: code),
  );
  if (target != null) await ref.read(shellProvider.notifier).adoptPaired(target);
  return target;
}

Future<void> openWakeSettings(
  BuildContext context,
  WidgetRef ref,
  SavedTarget target,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => WakeSettingsSheet(
    device: wakeDeviceOf(target),
    service: ref.read(wakeServiceProvider),
    onSave: (config) =>
        ref.read(shellProvider.notifier).setWake(target.id, config),
  ),
);

/// Rename / change icon / remove. Returns true when the target was removed.
Future<bool> editTarget(
  BuildContext context,
  WidgetRef ref,
  SavedTarget target,
) async {
  var name = target.name;
  var icon = target.icon;
  final result = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => Padding(
        padding: EdgeInsets.fromLTRB(
          24,
          8,
          24,
          MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Edit device',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              TextFormField(
                initialValue: name,
                maxLength: 40,
                decoration: const InputDecoration(labelText: 'Device name'),
                onChanged: (value) => update(() => name = value),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                children: [
                  for (final value in deviceIcons)
                    ChoiceChip(
                      label: Icon(targetIcon(value)),
                      tooltip: value,
                      selected: icon == value,
                      onSelected: (_) => update(() => icon = value),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                targetAddressLabel(target),
                style: const TextStyle(color: Colors.white54),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: name.trim().isEmpty
                    ? null
                    : () => Navigator.pop(context, 'save'),
                child: const Text('Save'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'remove'),
                child: const Text('Remove saved device'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (result == null || !context.mounted) return false;
  final shell = ref.read(shellProvider.notifier);
  if (result == 'save') {
    await shell.rename(target.id, name: name.trim(), icon: icon);
    return false;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Remove ${target.name}?'),
      content: const Text(
        'It disappears from this phone’s device list and its pairings and '
        'wake settings are deleted. The PC itself is not changed; you can add '
        'it again later.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Keep'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: NX.failed),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  await shell.remove(target.id);
  try {
    await ref.read(wakeServiceProvider).removeToken(wakeKeyOf(target));
  } catch (_) {}
  return true;
}

/// Wake-on-LAN / webhook wake with a wait for the PC to come up.
class WakeStatus {
  const WakeStatus({required this.targetId, required this.message, this.error});
  final String targetId;
  final String message;
  final String? error;
  bool get active => error == null;
}

final wakeFlowProvider = NotifierProvider<WakeFlow, WakeStatus?>(
  WakeFlow.new,
);

class WakeFlow extends Notifier<WakeStatus?> {
  int _generation = 0;

  @override
  WakeStatus? build() => null;

  bool get busy => state?.active == true;

  void cancel() {
    _generation++;
    state = null;
  }

  void clearError() {
    if (state?.error != null) state = null;
  }

  /// Sends the wake request and waits up to two minutes; on success makes the
  /// target current and connects.
  Future<void> wake(SavedTarget target) async {
    final config = target.wake;
    if (config == null || busy) return;
    final generation = ++_generation;
    final service = ref.read(wakeServiceProvider);
    final key = wakeKeyOf(target);
    state = WakeStatus(targetId: target.id, message: 'Sending wake request…');
    try {
      await service.wake(key, config);
      if (generation != _generation) return;
      state = WakeStatus(
        targetId: target.id,
        message: 'Wake sent · Waiting for the PC to start…',
      );
      final watch = Stopwatch()..start();
      while (generation == _generation &&
          watch.elapsed < const Duration(minutes: 2)) {
        final ready = await service.reachable(key);
        if (generation != _generation) return;
        if (ready) {
          state = null;
          await ref.read(shellProvider.notifier).select(target.id);
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (generation == _generation) {
        state = WakeStatus(
          targetId: target.id,
          message: '',
          error:
              'Wake was sent, but ${target.name} is not reachable yet. Check '
              'PC power and that NexusLink starts automatically, then tap '
              'Connect.',
        );
      }
    } catch (e) {
      if (generation == _generation) {
        state = WakeStatus(
          targetId: target.id,
          message: '',
          error: e is WakeException
              ? e.message
              : 'Couldn’t send the wake request. Check Wake settings and your '
                    'network.',
        );
      }
    }
  }
}
