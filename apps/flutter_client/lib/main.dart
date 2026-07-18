// NexusLink Flutter client — M1 walking skeleton.
// Proves the full pipeline: discovery → WS connect → JSON RPC → binary
// mirror frames rendered. The real launcher/mirror UI builds on top of this.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'src/discovery/mdns_discovery.dart';
import 'src/rpc/rpc_client.dart';

void main() {
  runApp(const NexusLinkApp());
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

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _urlController = TextEditingController();
  List<DiscoveredHost> _hosts = [];
  bool _scanning = false;
  bool _connecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final hosts = await discoverHosts();
      setState(() => _hosts = hosts);
      // Zero-config: exactly one host on the LAN → connect to it directly.
      if (hosts.length == 1 && mounted && !_connecting) {
        _connect(hosts.first.wsUrl);
      }
    } catch (e) {
      setState(() => _error = 'Discovery failed: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _connect(String wsUrl) async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    final client = RpcClient(wsUrl);
    try {
      await client.connect();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SkeletonProbeScreen(client: client)),
      );
      client.disconnect();
    } catch (e) {
      client.dispose();
      setState(() => _error = 'Could not connect: $e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('NexusLink',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('Your PC, in your pocket',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.4))),
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
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.chevron_right),
                      onTap: _connecting ? null : () => _connect(h.wsUrl),
                    ),
                  )),
              if (_hosts.isEmpty && !_scanning)
                Text('No hosts found on this network.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.4))),
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
              const SizedBox(height: 24),
              TextField(
                controller: _urlController,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Manual: ws://host:45678/rpc',
                  border: OutlineInputBorder(),
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
    );
  }
}

/// Walking-skeleton probe: shows host info via RPC and live mirror frames.
class SkeletonProbeScreen extends StatefulWidget {
  const SkeletonProbeScreen({super.key, required this.client});

  final RpcClient client;

  @override
  State<SkeletonProbeScreen> createState() => _SkeletonProbeScreenState();
}

class _SkeletonProbeScreenState extends State<SkeletonProbeScreen> {
  String _info = 'loading…';
  Uint8List? _frame;
  int _streamKey = -1;
  String? _streamId;
  int _frameCount = 0;
  int _fps = 0;
  StreamSubscription<MirrorFrame>? _frameSub;
  Timer? _fpsTimer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final info = await widget.client.request('system.getInfo')
          as Map<String, dynamic>;
      if (!mounted) return;
      setState(() =>
          _info = '${info['hostname']} · ${info['os']} · ${info['cpuModel']}');

      final cap = await widget.client.request('screen.startCapture',
          {'quality': 'low', 'fps': 15}) as Map<String, dynamic>;
      _streamId = cap['streamId'] as String?;
      _streamKey = (cap['streamKey'] as num?)?.toInt() ?? -1;

      _frameSub = widget.client.frames.listen((frame) {
        if (frame.streamKey != _streamKey) return;
        _frameCount++;
        if (mounted) setState(() => _frame = frame.jpeg);
      });
      _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() => _fps = _frameCount);
          _frameCount = 0;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _info = 'error: $e');
    }
  }

  @override
  void dispose() {
    _frameSub?.cancel();
    _fpsTimer?.cancel();
    final id = _streamId;
    if (id != null) {
      try {
        widget.client.notify('screen.stopCapture', {'streamId': id});
      } catch (_) {}
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Probe · $_fps fps')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_info, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: _frame == null
                  ? const CircularProgressIndicator()
                  : Image.memory(_frame!,
                      gaplessPlayback: true, fit: BoxFit.contain),
            ),
          ),
        ],
      ),
    );
  }
}
