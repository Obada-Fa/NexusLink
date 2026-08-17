// NexusLink Flutter client — premium remote-desktop app for the LAN/X11 host.
// Connect (mDNS discovery / manual) → launcher → per-app mirror sessions.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/discovery/mdns_discovery.dart';
import 'src/state/connection.dart';
import 'src/state/last_host.dart';
import 'src/screens/launcher_screen.dart';

void main() {
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
          seedColor: const Color(0xFF2A6AFF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0A0A0F),
        useMaterial3: true,
      ),
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
  List<DiscoveredHost> _hosts = [];
  bool _scanning = false;
  bool _connecting = false;
  String? _error;
  String? _lastHostUrl;

  @override
  void initState() {
    super.initState();
    _loadLastHost();
    _scan();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _loadLastHost() async {
    final last = await loadLastHostUrl();
    if (!mounted || last == null) return;
    setState(() {
      _lastHostUrl = last;
      if (_urlController.text.isEmpty) {
        _urlController.text = last;
      }
    });
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
      if (hosts.length == 1 && !_connecting) {
        _connect(hosts.first.wsUrl);
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Discovery failed: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _connect(String wsUrl) async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await ref.read(connectionProvider.notifier).connect(wsUrl);
      await saveLastHostUrl(wsUrl);
      if (!mounted) return;
      setState(() => _lastHostUrl = wsUrl.trim());
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const LauncherScreen()),
      );
      // Returned from the launcher (disconnected) — nothing else to do.
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not connect: $e');
    } finally {
      if (mounted) setState(() => _connecting = false);
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
                const Text('NexusLink',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('Your PC, in your pocket',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: Colors.white.withValues(alpha: 0.4))),
                const SizedBox(height: 32),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.redAccent)),
                  ),
                ..._hosts.map((h) => Card(
                      child: ListTile(
                        leading: const Icon(Icons.computer),
                        title: Text(h.name),
                        subtitle: Text('${h.address}:${h.port}'),
                        trailing: _connecting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.chevron_right),
                        onTap: _connecting ? null : () => _connect(h.wsUrl),
                      ),
                    )),
                if (_hosts.isEmpty && !_scanning)
                  Text('No hosts found on this network.',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: Colors.white.withValues(alpha: 0.4))),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _scanning ? null : _scan,
                  icon: _scanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh),
                  label: Text(_scanning ? 'Scanning…' : 'Scan again'),
                ),
                if (_lastHostUrl != null) ...[
                  const SizedBox(height: 24),
                  Text('LAST CONNECTION',
                      style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 0.8,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.4))),
                  const SizedBox(height: 8),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.history),
                      title: Text(lastHostLabel(_lastHostUrl!)),
                      subtitle: Text(_lastHostUrl!,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: _connecting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.chevron_right),
                      onTap: _connecting
                          ? null
                          : () {
                              _urlController.text = _lastHostUrl!;
                              _connect(_lastHostUrl!);
                            },
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                TextField(
                  controller: _urlController,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: _lastHostUrl != null
                        ? 'Or enter a different host'
                        : 'Manual: ws://host:45678/rpc',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _connecting || _urlController.text.isEmpty
                      ? null
                      : () => _connect(_urlController.text),
                  child: const Text('Connect'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
