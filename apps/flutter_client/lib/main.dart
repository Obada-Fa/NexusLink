// NexusLink Flutter client — premium remote-desktop app for the LAN/X11 host.
// Connect (mDNS discovery / manual) → launcher → per-app mirror sessions.

import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'src/auth/pair_bundle.dart';
import 'src/screens/scan_pair_screen.dart';
import 'src/workspace/platform_bridge.dart';
import 'src/workspace/project.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/discovery/mdns_discovery.dart';
import 'src/services/notification_service.dart';
import 'src/state/connection.dart';
import 'src/state/last_host.dart';
import 'src/workspace/workspace_shell.dart';
import 'src/widgets/app_error_view.dart';
import 'src/widgets/connection_lifecycle.dart';
import 'src/state/saved_devices.dart';
import 'src/services/wake_service.dart';
import 'src/screens/wake_settings_sheet.dart';
import 'src/theme/nexus_theme.dart';
import 'src/theme/nx_widgets.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.init();
  ErrorWidget.builder = AppErrorView.fromDetails;
  appReloadGeneration.addListener(() => _autoConnectAttempted = false);
  runApp(
    ValueListenableBuilder<int>(
      valueListenable: appReloadGeneration,
      builder: (_, generation, _) => ProviderScope(
        key: ValueKey(generation),
        child: const NexusLinkApp(),
      ),
    ),
  );
}

class NexusLinkApp extends StatelessWidget {
  const NexusLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NexusLink',
      debugShowCheckedModeBanner: false,
      theme: nexusTheme(),
      navigatorKey: appNavigatorKey,
      builder: (context, child) =>
          ConnectionLifecycle(child: child ?? const SizedBox.shrink()),
      home: const ConnectScreen(),
    );
  }
}

/// Auto-connect runs at most once per app run (cold start), never after the
/// user came back to this screen.
bool _autoConnectAttempted = false;

/// Test hook: lets widget tests start from a fresh "cold start".
@visibleForTesting
void resetAutoConnectForTest() => _autoConnectAttempted = false;

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _urlController = TextEditingController();
  final _pairingController = TextEditingController();
  final _pairingFocus = FocusNode();
  List<DiscoveredHost> _hosts = [];
  bool _scanning = false;
  bool _connecting = false;
  String? _error;
  List<SavedDevice> _devices = [];
  bool _showAddDevice = false;
  String? _connectingUrl;
  final _nameController = TextEditingController();
  String _newIcon = 'desktop';
  String? _wakingUrl;
  String? _wakeMessage;
  int _wakeGeneration = 0;

  /// Bumped to abandon an in-flight connect (Cancel).
  int _connectGeneration = 0;

  /// Name shown on the "Connecting…" card for automatic connections.
  String? _autoLabel;

  @override
  void initState() {
    super.initState();
    _loadLastHost();
  }

  @override
  void dispose() {
    _wakeGeneration++;
    _nameController.dispose();
    _urlController.dispose();
    _pairingController.dispose();
    _pairingFocus.dispose();
    super.dispose();
  }

  Future<void> _loadLastHost() async {
    try {
      final devices = await SavedDevices.load();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _showAddDevice = devices.isEmpty;
      });
      if (Platform.isAndroid) {
        final deepLink = await PlatformBridge.call('live.pendingTask');
        if (!mounted) return;
        if (deepLink is Map && deepLink['host'] is String) {
          _autoConnectAttempted = true;
          ref
              .read(pendingTaskProvider.notifier)
              .select(deepLink['taskId'] as String?);
          final url = normalizeHostWsUrl(deepLink['host'] as String);
          await _connect(
            url,
            auto: true,
            label: devices.where((d) => d.url == url).firstOrNull?.name,
          );
          return;
        }
      }
      await _autoConnect(devices);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Could not load saved devices: $error';
          _showAddDevice = true;
        });
      }
    }
  }

  Future<void> _autoConnect(List<SavedDevice> devices) async {
    final decision = await decideAutoConnect(
      devices: devices,
      lastHostUrl: await loadLastHostUrl(),
      userDisconnected: ref.read(connectionProvider.notifier).userDisconnected,
      alreadyAttempted: _autoConnectAttempted,
      hasCredential: (url) async =>
          (await PlatformBridge.credential(url))?.isNotEmpty == true,
    );
    _autoConnectAttempted = true;
    final device = decision.device;
    if (device == null || !mounted || _connecting) return;
    await _connect(device.url, auto: true, label: device.name);
  }

  void _cancelConnect() {
    ++_connectGeneration;
    ref.read(connectionProvider.notifier).disconnect();
    setState(() {
      _connecting = false;
      _connectingUrl = null;
      _autoLabel = null;
      _error = null;
    });
  }

  /// The PC refused this phone's pairing: open the pairing form prefilled
  /// with that PC so one code entry fixes it.
  void _showPairAgain(String? hostUrl) {
    final url = hostUrl == null ? null : normalizeHostWsUrl(hostUrl);
    final device = _devices.where((d) => d.url == url).firstOrNull;
    setState(() {
      _showAddDevice = true;
      if (url != null) _urlController.text = url;
      if (device != null) _nameController.text = device.name;
      _error =
          'This phone is no longer paired with ${device?.name ?? 'that PC'}. '
          'Scan the QR code again, or type a new pairing code from '
          'Nexus Utilities → Add phone on your PC.';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Never pull the keyboard up while another screen covers this one.
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        _pairingFocus.requestFocus();
      }
    });
  }

  IconData _deviceIcon(String icon) => switch (icon) {
    'laptop' => Icons.laptop_mac_rounded,
    'server' => Icons.dns_rounded,
    'gaming' => Icons.sports_esports_rounded,
    _ => Icons.desktop_windows_rounded,
  };

  Future<void> _editDevice(SavedDevice device) async {
    var name = device.name;
    var icon = device.icon;
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
                  children: deviceIcons
                      .map(
                        (value) => ChoiceChip(
                          label: Icon(_deviceIcon(value)),
                          tooltip: value,
                          selected: icon == value,
                          onSelected: (_) => update(() => icon = value),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 16),
                Text(
                  lastHostLabel(device.url),
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
    if (result == null || !mounted) return;
    if (result == 'remove') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Remove ${device.name}?'),
          content: const Text(
            'It disappears from this phone’s device list and its wake '
            'settings are deleted. The PC itself is not changed; you can add '
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
      if (confirmed != true || !mounted) return;
    }
    final devices = [
      for (final saved in _devices)
        if (saved.url != device.url)
          saved
        else if (result == 'save')
          saved.copyWith(name: name.trim(), icon: icon),
    ];
    try {
      await SavedDevices.save(devices);
      if (result == 'remove') {
        await ref.read(wakeServiceProvider).removeToken(device.url);
      }
      if (mounted) {
        setState(() {
          _devices = devices;
          _showAddDevice = devices.isEmpty;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _wakeSettings(SavedDevice device) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => WakeSettingsSheet(
        device: device,
        service: ref.read(wakeServiceProvider),
        onSave: (config) async {
          final devices = [
            for (final saved in _devices)
              if (saved.url == device.url)
                saved.copyWith(wake: config, clearWake: config == null)
              else
                saved,
          ];
          await SavedDevices.save(devices);
          if (mounted) setState(() => _devices = devices);
        },
      ),
    );
  }

  Future<void> _wakeDevice(SavedDevice device) async {
    if (_wakingUrl != null || _connecting) return;
    if (device.wake == null) {
      await _wakeSettings(device);
      return;
    }
    final generation = ++_wakeGeneration;
    final service = ref.read(wakeServiceProvider);
    setState(() {
      _wakingUrl = device.url;
      _wakeMessage = 'Sending wake request…';
      _error = null;
    });
    try {
      await service.wake(device.url, device.wake!);
      if (!mounted || generation != _wakeGeneration) return;
      setState(() => _wakeMessage = 'Wake sent · Waiting for the PC to start…');
      final watch = Stopwatch()..start();
      while (mounted &&
          generation == _wakeGeneration &&
          watch.elapsed < const Duration(minutes: 2)) {
        final ready = await service.reachable(device.url);
        if (!mounted || generation != _wakeGeneration) return;
        if (ready) {
          setState(() {
            _wakingUrl = null;
            _wakeMessage = null;
          });
          await _connect(device.url);
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (mounted && generation == _wakeGeneration) {
        setState(
          () => _error =
              'Wake was sent, but ${device.name} is not reachable yet. Check PC power and that NexusLink starts automatically, then tap Connect.',
        );
      }
    } catch (e) {
      if (mounted && generation == _wakeGeneration) {
        setState(
          () => _error = e is WakeException
              ? e.message
              : 'Couldn’t send the wake request. Check Wake settings and your network.',
        );
      }
    } finally {
      if (mounted && generation == _wakeGeneration) {
        setState(() {
          _wakingUrl = null;
          _wakeMessage = null;
        });
      }
    }
  }

  void _cancelWakeWait() {
    _wakeGeneration++;
    setState(() {
      _wakingUrl = null;
      _wakeMessage = null;
    });
  }

  Widget _deviceCard(SavedDevice device) {
    final connecting = _connectingUrl == device.url;
    final waking = _wakingUrl == device.url;
    final busy = _connecting || _wakingUrl != null;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: 12,
            ),
            leading: Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF537FE7), Color(0xFF7756C9)],
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                _deviceIcon(device.icon),
                color: Colors.white,
                size: 28,
              ),
            ),
            title: Text(
              device.name,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
            ),
            subtitle: Text(
              connecting
                  ? 'Connecting…'
                  : waking
                  ? _wakeMessage ?? 'Waking…'
                  : 'Tap to connect',
            ),
            trailing: connecting || waking
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    tooltip: 'Edit device',
                    icon: const Icon(Icons.more_horiz),
                    onPressed: busy ? null : () => _editDevice(device),
                  ),
            onTap: busy ? null : () => _connect(device.url),
            onLongPress: busy ? null : () => _editDevice(device),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Wrap(
              spacing: 8,
              alignment: WrapAlignment.spaceBetween,
              children: [
                if (connecting)
                  TextButton.icon(
                    onPressed: _cancelConnect,
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Cancel'),
                  )
                else if (waking)
                  TextButton.icon(
                    onPressed: _cancelWakeWait,
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Stop waiting'),
                  )
                else
                  TextButton.icon(
                    onPressed: busy ? null : () => _wakeDevice(device),
                    icon: const Icon(Icons.power_settings_new, size: 19),
                    label: Text(
                      device.wake == null ? 'Set up wake' : 'Wake PC',
                    ),
                  ),
                TextButton.icon(
                  onPressed: busy ? null : () => _wakeSettings(device),
                  icon: const Icon(Icons.settings_outlined, size: 18),
                  label: const Text('Wake settings'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final hosts = await discoverHosts();
      if (!mounted) return;
      setState(() => _hosts = hosts);
    } catch (e) {
      if (mounted) setState(() => _error = 'Discovery failed: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _scanPairCode() async {
    FocusScope.of(context).unfocus();
    final pairing = await Navigator.of(context).push<NexusLinkPairing>(
      MaterialPageRoute(builder: (_) => const ScanPairScreen()),
    );
    if (!mounted) return;
    if (pairing == null) return; // backed out or chose to type it
    _urlController.text = pairing.wsUrl;
    _pairingController.text = pairing.code;
    final typed = _nameController.text.trim();
    await _connect(
      pairing.wsUrl,
      name: typed.isEmpty ? pairing.pcName : typed,
      icon: _newIcon,
      label: pairing.pcName,
    );
  }

  Future<void> _connect(
    String wsUrl, {
    String? name,
    String? icon,
    bool auto = false,
    String? label,
  }) async {
    if (_connecting) return;
    if (_wakingUrl != null) _cancelWakeWait();
    wsUrl = normalizeHostWsUrl(wsUrl);
    final generation = ++_connectGeneration;
    final pairingCode = _pairingController.text.replaceAll(RegExp(r'\D'), '');
    setState(() {
      _connecting = true;
      _connectingUrl = wsUrl;
      _autoLabel = auto ? (label ?? lastHostLabel(wsUrl)) : null;
      _error = null;
    });
    try {
      await ref
          .read(connectionProvider.notifier)
          .connect(
            wsUrl,
            pairingCode: pairingCode.isEmpty ? null : pairingCode,
          );
      if (!mounted || generation != _connectGeneration) return;
      var devices = await SavedDevices.remember(wsUrl, name: name);
      if (icon != null) {
        devices = [
          for (final device in devices)
            if (device.url == wsUrl) device.copyWith(icon: icon) else device,
        ];
        await SavedDevices.save(devices);
      }
      await saveLastHostUrl(wsUrl);
      if (!mounted || generation != _connectGeneration) return;
      _pairingController.clear();
      setState(() {
        _devices = devices;
        _showAddDevice = false;
        _connecting = false;
        _connectingUrl = null;
        _autoLabel = null;
      });
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const WorkspaceShell()));
      // Returned from the workspace (disconnected) — nothing else to do.
    } catch (e) {
      if (!mounted || generation != _connectGeneration) return;
      final pcName =
          label ??
          _devices.where((d) => d.url == wsUrl).firstOrNull?.name ??
          lastHostLabel(wsUrl);
      if (isAuthError(e)) {
        setState(() {
          _connecting = false;
          _connectingUrl = null;
          _autoLabel = null;
        });
        _showPairAgain(wsUrl);
        if (pairingCode.isNotEmpty || !auto) {
          setState(() => _error = connectErrorMessage(e));
        }
        return;
      }
      setState(() {
        _error = auto
            ? 'Couldn’t reconnect to $pcName automatically. '
                  '${connectErrorMessage(e)} Tap the PC to try again.'
            : 'Couldn’t connect to $pcName. ${connectErrorMessage(e)}';
        _urlController.text = wsUrl;
        // Saved PCs stay one tap away; only show setup for new addresses.
        if (!_devices.any((d) => d.url == wsUrl)) _showAddDevice = true;
      });
    } finally {
      if (mounted && generation == _connectGeneration && _connecting) {
        setState(() {
          _connecting = false;
          _connectingUrl = null;
          _autoLabel = null;
        });
      }
    }
  }

  Widget _connectingCard() {
    final label = _autoLabel ?? lastHostLabel(_connectingUrl ?? '');
    return Padding(
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Connecting to $label…',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    lastHostLabel(_connectingUrl ?? ''),
                    style: const TextStyle(color: NX.textDim, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            TextButton(onPressed: _cancelConnect, child: const Text('Cancel')),
          ],
        ),
      ),
    );
  }

  Widget _errorCard(String message) => Padding(
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
            onPressed: () => setState(() => _error = null),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(connectionAuthRequiredProvider, (previous, next) {
      if (next && previous != true) {
        _showPairAgain(ref.read(connectionProvider).hostUrl);
      }
    });
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'NexusLink',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  'Your PC, in your pocket',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: NX.textDim),
                ),
                const SizedBox(height: 32),
                if (_connecting && _autoLabel != null) _connectingCard(),
                if (_error != null) _errorCard(_error!),
                if (_devices.isNotEmpty) ...[
                  const Text(
                    'YOUR DEVICES',
                    style: TextStyle(
                      fontSize: 12,
                      letterSpacing: 1.2,
                      color: Colors.white54,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ..._devices.map(_deviceCard),
                  const Text(
                    'Long-press to change a name or icon',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  const SizedBox(height: 20),
                ],
                OutlinedButton.icon(
                  onPressed: _connecting
                      ? null
                      : () => setState(() => _showAddDevice = !_showAddDevice),
                  icon: Icon(_showAddDevice ? Icons.expand_less : Icons.add),
                  label: Text(
                    _showAddDevice ? 'Hide device setup' : 'Add device',
                  ),
                ),
                if (_showAddDevice) ...[
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const ValueKey('scan-pair'),
                    onPressed: _connecting ? null : _scanPairCode,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                    ),
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: const Text(
                      'Scan QR code from PC',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'On your PC: Nexus Utilities → Add phone',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: NX.textDim, fontSize: 12.5),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _scanning || _connecting ? null : _scan,
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
                  ..._hosts.map(
                    (host) => Card(
                      child: ListTile(
                        leading: const Icon(Icons.computer),
                        title: Text(host.name),
                        subtitle: Text('${host.address}:${host.port}'),
                        onTap: _connecting
                            ? null
                            : () => _connect(
                                host.wsUrl,
                                name: _nameController.text.trim().isEmpty
                                    ? host.name
                                    : _nameController.text.trim(),
                                icon: _newIcon,
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
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
                          'Your PC’s Tailscale IP or name. The port is added '
                          'for you.',
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
                          '8 digits shown on your PC under Add phone. '
                          'Only needed the first time.',
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
                    children: deviceIcons
                        .map(
                          (value) => ChoiceChip(
                            label: Icon(_deviceIcon(value)),
                            tooltip: value,
                            selected: _newIcon == value,
                            onSelected: (_) => setState(() => _newIcon = value),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const ValueKey('connect'),
                    onPressed: _connecting || _urlController.text.isEmpty
                        ? null
                        : () => _connect(
                            _urlController.text,
                            name: _nameController.text.trim().isEmpty
                                ? 'My PC'
                                : _nameController.text.trim(),
                            icon: _newIcon,
                          ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: const Text('Connect'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
