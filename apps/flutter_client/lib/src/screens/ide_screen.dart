// Tier 3: VS Code UI on the phone. The PC runs code-server / openvscode-server;
// this screen loads that URL in a full-screen WebView (the editor is already
// a responsive web app — no pixels are streamed).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../rpc/rpc_client.dart';
import '../state/connection.dart';

class IdeScreen extends ConsumerStatefulWidget {
  const IdeScreen({super.key});

  @override
  ConsumerState<IdeScreen> createState() => _IdeScreenState();
}

class _IdeScreenState extends ConsumerState<IdeScreen> {
  String? _error;
  bool _loading = true;
  WebViewController? _web;

  RpcClient? get _client => ref.read(activeClientProvider);

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final client = _client;
    final httpBase = ref.read(connectionProvider).httpBase;
    if (client == null || httpBase == null) {
      setState(() {
        _loading = false;
        _error = 'Not connected to the PC.';
      });
      return;
    }
    try {
      final st = await client.requestMap('ide.start', const {});
      if (st['available'] != true || st['port'] is! num) {
        setState(() {
          _loading = false;
          _error = (st['reason'] as String?) ??
              'Install code-server on the PC, then open VS Code again.';
        });
        return;
      }
      final host = Uri.parse(httpBase).host;
      final url = 'http://$host:${(st['port'] as num).toInt()}';
      final web = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..loadRequest(Uri.parse(url));
      if (!mounted) return;
      setState(() {
        _web = web;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyLaunchError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0F),
        title: const Text('VS Code', style: TextStyle(fontSize: 16)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70)),
                  ),
                )
              : _web != null
                  ? WebViewWidget(controller: _web!)
                  : const SizedBox.shrink(),
    );
  }
}
