// NexusLink Flutter client — premium remote-desktop app for the LAN/X11 host.
// Connect (mDNS discovery / manual) → launcher → per-app mirror sessions.

import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'src/workspace/platform_bridge.dart';
import 'src/workspace/project.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/discovery/mdns_discovery.dart';
import 'src/services/notification_service.dart';
import 'src/state/connection.dart';
import 'src/state/last_host.dart';
import 'src/workspace/workspace_shell.dart';
import 'src/widgets/connection_lifecycle.dart';
import 'src/state/saved_devices.dart';
import 'src/services/wake_service.dart';
import 'src/screens/wake_settings_sheet.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.init();
  runApp(const ProviderScope(child: NexusLinkApp()));
}

class NexusLinkApp extends StatelessWidget {
  const NexusLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NexusLink',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C9BFF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0B0D12),
        useMaterial3: true,
      ),
      builder: (context, child) =>
          ConnectionLifecycle(child: child ?? const SizedBox.shrink()),
      home: const ConnectScreen(),
    );
  }
}

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _urlController = TextEditingController();
  final _pairingController = TextEditingController();
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
          ref
              .read(pendingTaskProvider.notifier)
              .select(deepLink['taskId'] as String?);
          await _connect(deepLink['host'] as String);
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'Could not load saved devices: $error';
          _showAddDevice = true;
        });
      }
    }
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
                if (waking)
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

  Future<void> _connect(String wsUrl, {String? name, String? icon}) async {
    if (_connecting) return;
    if (_wakingUrl != null) _cancelWakeWait();
    wsUrl = normalizeHostWsUrl(wsUrl);
    setState(() {
      _connecting = true;
      _connectingUrl = wsUrl;
      _error = null;
    });
    try {
      await ref
          .read(connectionProvider.notifier)
          .connect(
            wsUrl,
            pairingCode: _pairingController.text.trim().isEmpty
                ? null
                : _pairingController.text.trim(),
          );
      var devices = await SavedDevices.remember(wsUrl, name: name);
      if (icon != null) {
        devices = [
          for (final device in devices)
            if (device.url == wsUrl) device.copyWith(icon: icon) else device,
        ];
        await SavedDevices.save(devices);
      }
      await saveLastHostUrl(wsUrl);
      if (!mounted) return;
      _pairingController.clear();
      setState(() {
        _devices = devices;
        _showAddDevice = false;
      });
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const WorkspaceShell()));
      // Returned from the launcher (disconnected) — nothing else to do.
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not connect: $e';
          _urlController.text = wsUrl;
          _showAddDevice = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _connecting = false;
          _connectingUrl = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
                ),
                const SizedBox(height: 32),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
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
                  TextField(
                    controller: _nameController,
                    maxLength: 40,
                    decoration: const InputDecoration(
                      labelText: 'Device name',
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
                  const SizedBox(height: 24),
                  TextField(
                    controller: _pairingController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Pairing code (first connection)',
                      helperText: 'On your PC: bun run host:pair',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _urlController,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Device address',
                      hintText: 'ws://host:45678/rpc',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _connecting || _urlController.text.isEmpty
                        ? null
                        : () => _connect(
                            _urlController.text,
                            name: _nameController.text.trim().isEmpty
                                ? 'My PC'
                                : _nameController.text.trim(),
                            icon: _newIcon,
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
