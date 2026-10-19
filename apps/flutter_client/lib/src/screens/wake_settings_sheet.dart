import 'package:flutter/material.dart';
import '../services/wake_service.dart';
import '../state/saved_devices.dart';
import '../state/wake_config.dart';

class WakeSettingsSheet extends StatefulWidget {
  const WakeSettingsSheet({
    super.key,
    required this.device,
    required this.service,
    required this.onSave,
  });
  final SavedDevice device;
  final WakeService service;
  final Future<void> Function(WakeConfig?) onSave;
  @override
  State<WakeSettingsSheet> createState() => _WakeSettingsSheetState();
}

class _WakeSettingsSheetState extends State<WakeSettingsSheet> {
  final _form = GlobalKey<FormState>();
  late String _method;
  late String _authHeader;
  late final TextEditingController _mac, _broadcast, _port, _endpoint, _entity;
  final _token = TextEditingController();
  bool _busy = false, _tokenLoaded = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final settings =
        widget.device.wake ??
        const WakeConfig(
          method: 'webhook',
          endpoint: 'http://100.101.246.19:3050/wake',
          mac: 'BC:FC:E7:1A:1D:AA',
          broadcast: '192.168.68.255',
        );
    _method = settings.method;
    _authHeader = settings.authHeader;
    _mac = TextEditingController(text: settings.mac);
    _broadcast = TextEditingController(text: settings.broadcast);
    _port = TextEditingController(text: '${settings.port}');
    _endpoint = TextEditingController(text: settings.endpoint);
    _entity = TextEditingController(text: settings.entity);
    _loadToken();
  }

  Future<void> _loadToken() async {
    try {
      final secret = await widget.service.token(widget.device.url);
      if (mounted) {
        _token.text = secret ?? '';
        setState(() => _tokenLoaded = true);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Couldn’t read the saved wake key. Close and reopen Wake settings.',
        );
      }
    }
  }

  @override
  void dispose() {
    for (final c in [_mac, _broadcast, _port, _endpoint, _entity, _token]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save({bool remove = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final config = WakeConfig(
        method: _method,
        mac: _mac.text.trim(),
        broadcast: _broadcast.text.trim(),
        port: int.tryParse(_port.text) ?? 0,
        endpoint: _endpoint.text.trim(),
        entity: _entity.text.trim(),
        authHeader: _authHeader,
      );
      if (!remove) {
        WakeService.validate(config);
        if (_method == 'homeAssistant' && _token.text.trim().isEmpty) {
          throw const WakeException('Add a Home Assistant access token.');
        }
      }
      // Persist the device first. A failed credential write restores its settings.
      await widget.onSave(remove ? null : config);
      try {
        await widget.service.saveToken(
          widget.device.url,
          remove ? '' : _token.text,
        );
      } catch (_) {
        await widget.onSave(widget.device.wake);
        rethrow;
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is WakeException
              ? e.message
              : 'Couldn’t save wake settings. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool secret = false,
    TextInputType? type,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextFormField(
      controller: controller,
      enabled: !_busy && _tokenLoaded,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: type,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        8,
        24,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Wake ${widget.device.name}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Turn your PC on before connecting. Wake settings stay available while it is offline.',
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<String>(
                initialValue: _method,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Wake method',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'webhook',
                    child: Text('Home server · Wake-on-LAN'),
                  ),
                  DropdownMenuItem(
                    value: 'lan',
                    child: Text('Direct Wake-on-LAN · home Wi-Fi'),
                  ),
                  DropdownMenuItem(
                    value: 'homeAssistant',
                    child: Text('Home Assistant · smart plug / wake'),
                  ),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value != null) setState(() => _method = value);
                      },
              ),
              const SizedBox(height: 16),
              if (_method == 'lan') ...[
                _field(_mac, 'PC MAC address', hint: 'AA:BB:CC:DD:EE:FF'),
                _field(
                  _broadcast,
                  'LAN broadcast address',
                  hint: '192.168.68.255',
                  type: TextInputType.number,
                ),
                _field(_port, 'UDP port', type: TextInputType.number),
                const Text(
                  'Use this on the same home Wi-Fi. Away from home, choose Home server so it can broadcast the packet on your LAN.',
                ),
              ] else ...[
                _field(
                  _endpoint,
                  _method == 'homeAssistant'
                      ? 'Home Assistant base URL'
                      : 'Wake endpoint',
                  hint: _method == 'homeAssistant'
                      ? 'http://home-server:8123'
                      : 'http://100.101.246.19:3050/wake',
                  type: TextInputType.url,
                ),
                if (_method == 'homeAssistant') ...[
                  _field(
                    _entity,
                    'Wake / power-on entity',
                    hint: 'switch.pc_power or button.wake_pc',
                  ),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 14),
                    child: Text(
                      'For a Tapo P100, use its Home Assistant switch entity. This action only turns power on. Your separate Tapo phone app still works as usual.',
                    ),
                  ),
                ] else ...[
                  DropdownButtonFormField<String>(
                    initialValue: _authHeader,
                    decoration: const InputDecoration(
                      labelText: 'Authentication',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'X-API-Key',
                        child: Text('API key · your home server'),
                      ),
                      DropdownMenuItem(
                        value: 'Authorization',
                        child: Text('Bearer token'),
                      ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(() => _authHeader = value);
                            }
                          },
                  ),
                  const SizedBox(height: 14),
                ],
                _field(
                  _token,
                  _method == 'homeAssistant'
                      ? 'Home Assistant access token'
                      : 'API key / token (if required)',
                  secret: true,
                ),
                if (_method == 'webhook')
                  const Text(
                    'Keep Tailscale enabled to reach your home server while away. A successful request means the wake packet was sent; the app then waits for NexusLink on the PC.',
                  ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy || !_tokenLoaded ? null : () => _save(),
                child: Text(_busy ? 'Saving…' : 'Save wake settings'),
              ),
              if (widget.device.wake != null)
                TextButton(
                  onPressed: _busy || !_tokenLoaded
                      ? null
                      : () => _save(remove: true),
                  child: const Text('Remove wake settings'),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
