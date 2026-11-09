// Device picker: saved targets, add one (QR pairing flow, Wi-Fi discovery or
// the typed NexusLink address + code), and per-target rename/icon/wake/remove.
// It is the first screen when no target is current, and a pushed screen from
// the home header otherwise.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../discovery/mdns_discovery.dart';
import '../session/target.dart';
import '../state/connection.dart';
import '../state/last_host.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import 'auto_connect.dart';
import 'shell_controller.dart';
import 'target_actions.dart';

class DevicePickerScreen extends ConsumerStatefulWidget {
  const DevicePickerScreen({super.key, this.isRoot = false, this.pairAgain});

  /// Shown as the app's first screen (no target yet): brand header, no back.
  final bool isRoot;

  /// Open the typed form prefilled for this target (its pairing was refused).
  final SavedTarget? pairAgain;

  @override
  ConsumerState<DevicePickerScreen> createState() => _DevicePickerScreenState();
}

class _DevicePickerScreenState extends ConsumerState<DevicePickerScreen> {
  final _urlController = TextEditingController();
  final _pairingController = TextEditingController();
  final _nameController = TextEditingController();
  final _pairingFocus = FocusNode();
  String _newIcon = 'desktop';
  List<DiscoveredHost> _hosts = [];
  bool _scanning = false;
  bool? _showTyped;
  String? _connectingUrl;
  String? _error;
  int _connectGeneration = 0;

  bool get _connecting => _connectingUrl != null;

  @override
  void initState() {
    super.initState();
    final again = widget.pairAgain;
    if (again != null) {
      _showTyped = true;
      _urlController.text = nexusLinkUrlOf(again) ?? '';
      _nameController.text = again.name;
      _error =
          'This phone is no longer paired with ${again.name}. Scan the QR '
          'code again, or type a new pairing code from Nexus Utilities → Add '
          'phone on your PC.';
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          _pairingFocus.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _pairingController.dispose();
    _nameController.dispose();
    _pairingFocus.dispose();
    super.dispose();
  }

  void _done() {
    if (!widget.isRoot && mounted) Navigator.of(context).maybePop();
  }

  Future<void> _select(SavedTarget target) async {
    ref.read(wakeFlowProvider.notifier).cancel();
    await ref.read(shellProvider.notifier).select(target.id);
    _done();
  }

  Future<void> _scanQr() async {
    FocusScope.of(context).unfocus();
    setState(() => _error = null);
    final target = await startPairing(context, ref);
    if (target != null) _done();
  }

  Future<void> _discover() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final hosts = await discoverHosts();
      if (mounted) setState(() => _hosts = hosts);
    } catch (e) {
      if (mounted) setState(() => _error = 'Discovery failed: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _cancelConnect() {
    ++_connectGeneration;
    ref.read(connectionProvider.notifier).disconnect();
    setState(() {
      _connectingUrl = null;
      _error = null;
    });
  }

  /// Typed address + code, or a PC found on Wi-Fi.
  Future<void> _connectTyped(String wsUrl, {String? name}) async {
    if (_connecting) return;
    ref.read(wakeFlowProvider.notifier).cancel();
    final url = normalizeHostWsUrl(wsUrl);
    final code = _pairingController.text.replaceAll(RegExp(r'\D'), '');
    final generation = ++_connectGeneration;
    setState(() {
      _connectingUrl = url;
      _error = null;
    });
    try {
      await ref
          .read(shellProvider.notifier)
          .addNexusLink(url, pairingCode: code, name: name, icon: _newIcon);
      if (!mounted || generation != _connectGeneration) return;
      _pairingController.clear();
      setState(() => _connectingUrl = null);
      _done();
    } catch (e) {
      if (!mounted || generation != _connectGeneration) return;
      final known = ref.read(shellProvider.notifier).targetForUrl(url);
      final pcName = known?.name ?? lastHostLabel(url);
      setState(() {
        _connectingUrl = null;
        _showTyped = true;
        _urlController.text = url;
        if (isAuthError(e)) {
          _error = code.isEmpty
              ? 'This phone is not paired with $pcName yet. Type the pairing '
                    'code shown on your PC under Nexus Utilities → Add phone.'
              : connectErrorMessage(e);
        } else {
          _error = 'Couldn’t connect to $pcName. ${connectErrorMessage(e)}';
        }
      });
      if (isAuthError(e)) _pairingFocus.requestFocus();
    }
  }

  Future<void> _wake(SavedTarget target) async {
    if (target.wake == null) {
      await openWakeSettings(context, ref, target);
      return;
    }
    setState(() => _error = null);
    final flow = ref.read(wakeFlowProvider.notifier);
    await flow.wake(target);
    if (!mounted) return;
    final status = ref.read(wakeFlowProvider);
    if (status?.error != null) {
      setState(() => _error = status!.error);
      flow.clearError();
    } else if (ref.read(shellProvider).currentId == target.id &&
        status == null) {
      _done();
    }
  }

  @override
  Widget build(BuildContext context) {
    final shell = ref.watch(shellProvider);
    final wake = ref.watch(wakeFlowProvider);
    final targets = shell.targets;
    // QR is the main way in; Wi-Fi discovery and the typed address wait
    // under "Other ways to connect" unless a pairing needs them.
    final showOther = _showTyped ?? false;
    final busy = _connecting || wake?.active == true;
    return Scaffold(
      appBar: widget.isRoot ? null : AppBar(title: const Text('Devices')),
      body: SafeArea(
        top: widget.isRoot,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            if (widget.isRoot) const _BrandHeader(),
            if (_connecting &&
                targets.any((t) => nexusLinkUrlOf(t) == _connectingUrl))
              _ConnectingCard(
                label: lastHostLabel(_connectingUrl!),
                onCancel: _cancelConnect,
              ),
            if (_error != null)
              _ErrorCard(
                message: _error!,
                onDismiss: () => setState(() => _error = null),
              ),
            if (shell.error != null && targets.isEmpty)
              _ErrorCard(message: shell.error!, onDismiss: () {}),
            if (targets.isNotEmpty) ...[
              const _Label('YOUR DEVICES'),
              const SizedBox(height: 10),
              for (final t in targets)
                _TargetCard(
                  key: ValueKey('target-${t.id}'),
                  target: t,
                  current: t.id == shell.currentId,
                  wake: wake?.targetId == t.id ? wake : null,
                  busy: busy,
                  onTap: () => _select(t),
                  onEdit: () => editTarget(context, ref, t),
                  onWake: () => _wake(t),
                  onWakeSettings: () => openWakeSettings(context, ref, t),
                  onStopWaiting: ref.read(wakeFlowProvider.notifier).cancel,
                ),
              const Text(
                'Long-press to change a name or icon',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const SizedBox(height: 24),
            ] else
              const _ConnectIntro(),
            FilledButton.icon(
              key: const ValueKey('scan-pair'),
              onPressed: busy ? null : _scanQr,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(NX.radiusSm + 4),
                ),
              ),
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: Text(
                targets.isEmpty ? 'Scan QR code' : 'Add a device',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (targets.isNotEmpty)
              const Text(
                'On your PC, open Nexus Utilities → Add phone. One scan pairs '
                'NexusLink, Remote and Audio.',
                textAlign: TextAlign.center,
                style: TextStyle(color: NX.textDim, fontSize: 12.5),
              ),
            const SizedBox(height: 14),
            TextButton.icon(
              key: const ValueKey('other-ways'),
              onPressed: () => setState(() => _showTyped = !showOther),
              icon: Icon(
                showOther
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
              ),
              label: const Text('Other ways to connect'),
            ),
            if (showOther) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _scanning || busy ? null : _discover,
                icon: _scanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_find),
                label: Text(
                  _scanning ? 'Scanning…' : 'Find a PC on this Wi-Fi',
                ),
              ),
              for (final host in _hosts)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: NxCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    onTap: busy
                        ? null
                        : () => _connectTyped(
                            host.wsUrl,
                            name: _nameController.text.trim().isEmpty
                                ? host.name
                                : _nameController.text.trim(),
                          ),
                    child: Row(
                      children: [
                        const Icon(Icons.computer, color: NX.accent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                host.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '${host.address}:${host.port}',
                                style: const TextStyle(
                                  color: NX.textDim,
                                  fontSize: 12.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_connectingUrl == normalizeHostWsUrl(host.wsUrl))
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ],
                    ),
                  ),
                ),
              ..._typedForm(busy),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _typedForm(bool busy) => [
    const SizedBox(height: 14),
    const Row(
      children: [
        Expanded(child: Divider(color: NX.line)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'OR TYPE IT IN',
            style: TextStyle(
              fontSize: 11.5,
              letterSpacing: 1.2,
              color: NX.textFaint,
            ),
          ),
        ),
        Expanded(child: Divider(color: NX.line)),
      ],
    ),
    const SizedBox(height: 18),
    TextField(
      key: const ValueKey('pc-address'),
      controller: _urlController,
      onChanged: (_) => setState(() {}),
      keyboardType: TextInputType.url,
      autocorrect: false,
      decoration: const InputDecoration(
        labelText: 'PC address',
        hintText: 'e.g. 100.64.0.5',
        helperText:
            'Your PC’s Tailscale IP or name. The port is added for you.',
        border: OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: 16),
    TextField(
      key: const ValueKey('pairing-code'),
      controller: _pairingController,
      focusNode: _pairingFocus,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
        LengthLimitingTextInputFormatter(9),
      ],
      style: const TextStyle(
        fontSize: 20,
        letterSpacing: 3,
        fontWeight: FontWeight.w700,
      ),
      decoration: const InputDecoration(
        labelText: 'Pairing code',
        hintText: '1234 5678',
        helperText:
            '8 digits shown on your PC under Add phone. Only needed the first '
            'time.',
        helperMaxLines: 2,
        border: OutlineInputBorder(),
      ),
    ),
    const SizedBox(height: 16),
    TextField(
      controller: _nameController,
      maxLength: 40,
      decoration: const InputDecoration(
        labelText: 'Name (optional)',
        hintText: 'e.g. Office PC',
      ),
    ),
    Wrap(
      spacing: 12,
      children: [
        for (final value in deviceIcons)
          ChoiceChip(
            label: Icon(targetIcon(value)),
            tooltip: value,
            selected: _newIcon == value,
            onSelected: (_) => setState(() => _newIcon = value),
          ),
      ],
    ),
    const SizedBox(height: 16),
    if (_connecting &&
        !ref
            .read(shellProvider)
            .targets
            .any((t) => nexusLinkUrlOf(t) == _connectingUrl))
      _ConnectingCard(
        label: lastHostLabel(_connectingUrl!),
        onCancel: _cancelConnect,
      ),
    FilledButton(
      key: const ValueKey('connect'),
      onPressed: busy || _urlController.text.trim().isEmpty
          ? null
          : () => _connectTyped(
              _urlController.text,
              name: _nameController.text.trim().isEmpty
                  ? 'My PC'
                  : _nameController.text.trim(),
            ),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      child: const Text('Connect'),
    ),
  ];
}

/// First run: what to do on the PC before scanning.
class _ConnectIntro extends StatelessWidget {
  const _ConnectIntro();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Connect your computer',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        SizedBox(height: 8),
        Text(
          'On your PC, open Nexus Utilities → Add phone, then scan the QR '
          'code it shows. One scan pairs NexusLink, Remote and Audio.',
          style: TextStyle(color: NX.textDim, fontSize: 14.5, height: 1.4),
        ),
      ],
    ),
  );
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(0, 28, 0, 32),
    child: Column(
      children: [
        NexusMark(size: 68),
        SizedBox(height: 18),
        Text(
          'Nexus',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.w800,
            letterSpacing: -.8,
          ),
        ),
        SizedBox(height: 4),
        Text(
          'Your PC, in your pocket',
          textAlign: TextAlign.center,
          style: TextStyle(color: NX.textDim, fontSize: 15),
        ),
      ],
    ),
  );
}

/// The app's mark: a gradient tile with a hub glyph.
class NexusMark extends StatelessWidget {
  const NexusMark({super.key, this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * .3),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [NX.accent, NX.accent2],
        ),
        boxShadow: [
          BoxShadow(
            color: NX.accent.withValues(alpha: .28),
            blurRadius: size * .5,
            spreadRadius: -size * .1,
          ),
        ],
      ),
      child: Icon(Icons.hub_rounded, color: NX.bg, size: size * .56),
    ),
  );
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 12,
      letterSpacing: 1.2,
      color: Colors.white54,
    ),
  );
}

class _TargetCard extends StatelessWidget {
  const _TargetCard({
    super.key,
    required this.target,
    required this.current,
    required this.wake,
    required this.busy,
    required this.onTap,
    required this.onEdit,
    required this.onWake,
    required this.onWakeSettings,
    required this.onStopWaiting,
  });
  final SavedTarget target;
  final bool current;
  final WakeStatus? wake;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onWake;
  final VoidCallback onWakeSettings;
  final VoidCallback onStopWaiting;

  @override
  Widget build(BuildContext context) {
    final waking = wake?.active == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: NxCard(
        accent: current ? NX.accent : null,
        padding: EdgeInsets.zero,
        onTap: busy ? null : onTap,
        onLongPress: busy ? null : onEdit,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 6, 10),
              child: Row(
                children: [
                  TargetBadge(icon: target.icon, size: 50),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                target.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 18,
                                ),
                              ),
                            ),
                            if (current) ...[
                              const SizedBox(width: 8),
                              const NxPill(
                                'Current',
                                color: NX.accent,
                                dense: true,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          waking
                              ? wake!.message
                              : current
                              ? 'Tap to open'
                              : 'Tap to connect',
                          style: const TextStyle(
                            color: NX.textDim,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 8),
                        UtilityPills(target: target),
                      ],
                    ),
                  ),
                  if (waking)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    IconButton(
                      tooltip: 'Edit device',
                      icon: const Icon(Icons.more_horiz),
                      onPressed: busy ? null : onEdit,
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Wrap(
                spacing: 8,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  if (waking)
                    TextButton.icon(
                      onPressed: onStopWaiting,
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('Stop waiting'),
                    )
                  else
                    TextButton.icon(
                      onPressed: busy ? null : onWake,
                      icon: const Icon(Icons.power_settings_new, size: 19),
                      label: Text(
                        target.wake == null ? 'Set up wake' : 'Wake PC',
                      ),
                    ),
                  TextButton.icon(
                    onPressed: busy ? null : onWakeSettings,
                    icon: const Icon(Icons.settings_outlined, size: 18),
                    label: const Text('Wake settings'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Gradient square with the target's device icon.
class TargetBadge extends StatelessWidget {
  const TargetBadge({super.key, required this.icon, this.size = 50});
  final String icon;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF537FE7), Color(0xFF7756C9)],
      ),
      borderRadius: BorderRadius.circular(size * .32),
    ),
    child: Icon(targetIcon(icon), color: Colors.white, size: size * .56),
  );
}

/// Which utilities are paired on a target.
class UtilityPills extends StatelessWidget {
  const UtilityPills({super.key, required this.target, this.reachable});
  final SavedTarget target;

  /// When given, paired-but-unreachable utilities are drawn muted.
  final Set<String>? reachable;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final u in UtilityIds.all)
        if (target.has(u))
          NxPill(
            utilityName(u),
            dense: true,
            color: reachable == null || reachable!.contains(u)
                ? NX.working
                : NX.idle,
            icon: reachable == null || reachable!.contains(u)
                ? Icons.check_rounded
                : Icons.cloud_off_rounded,
          ),
    ],
  );
}

class _ConnectingCard extends StatelessWidget {
  const _ConnectingCard({required this.label, required this.onCancel});
  final String label;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: NxCard(
      accent: NX.accent,
      child: Row(
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              'Connecting to $label…',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
          ),
          TextButton(onPressed: onCancel, child: const Text('Cancel')),
        ],
      ),
    ),
  );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onDismiss});
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: NxCard(
      accent: NX.failed,
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.error_outline, color: NX.failed, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: const TextStyle(color: NX.text)),
          ),
          IconButton(
            tooltip: 'Dismiss',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18, color: NX.textDim),
            onPressed: onDismiss,
          ),
        ],
      ),
    ),
  );
}
