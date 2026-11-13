import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

class DesktopWindow {
  const DesktopWindow({
    required this.id,
    required this.desktop,
    required this.wmClass,
    required this.title,
    required this.appName,
    required this.isActive,
    required this.isMinimized,
    required this.isMaximized,
    this.icon,
  });

  final String id;
  final int desktop;
  final String wmClass;
  final String title;
  final String appName;
  final bool isActive;
  final bool isMinimized;
  final bool isMaximized;
  final String? icon;

  factory DesktopWindow.fromJson(Map<String, dynamic> json) {
    return DesktopWindow(
      id: json['id']?.toString() ?? '',
      desktop: (json['desktop'] as num?)?.toInt() ?? 0,
      wmClass: json['wm_class']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      appName: json['app_name']?.toString() ?? 'Window',
      isActive: json['is_active'] == true,
      isMinimized: json['is_minimized'] == true,
      isMaximized: json['is_maximized'] == true,
      icon: json['icon'] as String?,
    );
  }
}

class DesktopApp {
  const DesktopApp({
    required this.id,
    required this.name,
    this.icon,
    this.exec,
  });

  final String id;
  final String name;
  final String? icon;
  final String? exec;

  factory DesktopApp.fromJson(Map<String, dynamic> json) {
    return DesktopApp(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      icon: json['icon'] as String?,
      exec: json['exec'] as String?,
    );
  }
}

/// Everything the session needs to reach and authenticate to one PC's Remote
/// companion. Built by the host app from its saved target; never persisted here.
class RemoteEndpoint {
  const RemoteEndpoint({
    required this.hosts,
    required this.port,
    required this.fingerprint,
    required this.hostId,
    required this.token,
    this.pcName = 'PC',
  });

  /// Addresses tried in order.
  final List<String> hosts;
  final int port;

  /// Pinned SHA-256 of the DER certificate, 64 upper-case hex characters.
  final String fingerprint;
  final String hostId;
  final String token;
  final String pcName;
}

class RemoteSession extends ChangeNotifier {
  RemoteSession(this.endpoint, {this.onUnauthorized, this.databasePath});

  final RemoteEndpoint endpoint;

  /// Called once when the PC rejects the token (revoked / re-enrolled).
  final VoidCallback? onUnauthorized;

  /// Test hook: override the sqlite file location.
  final String? databasePath;

  String get hostId => endpoint.hostId;
  String get fingerprint => endpoint.fingerprint;
  Database? _db;
  WebSocket? _socket;
  Timer? _heartbeat;
  Timer? _reconnect;
  Timer? _windowsTimer;
  int _reconnectAttempt = 0;
  bool _terminalAuthFailure = false;
  bool _unauthorizedReported = false;
  bool _connecting = false;
  bool _disposed = false;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  /// The host that is connected (or was last tried).
  String address = '';
  String draft = '';
  String transcriptionStatus = '';
  String? pendingRecording;
  String status = 'Disconnected';
  String? error;
  bool connected = false;
  bool inputSupported = false;
  bool speechSupported = false;
  bool mediaSupported = false;
  bool windowsSupported = false;
  List<DesktopWindow> openWindows = [];
  List<DesktopApp> installedApps = [];
  String platform = '';
  int _draftRevision = 0;
  double touchpadSensitivity = 1.75;
  bool precisionMode = false;

  Future<void> setTouchpadSensitivity(double value) async {
    touchpadSensitivity = value.clamp(0.25, 3.0);
    notifyListeners();
    try {
      await _db?.insert(
        'settings',
        {'key': 'touchpad_sensitivity', 'value': touchpadSensitivity.toString()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }

  Future<void> setPrecisionMode(bool enabled) async {
    precisionMode = enabled;
    notifyListeners();
    try {
      await _db?.insert(
        'settings',
        {'key': 'precision_mode', 'value': precisionMode ? '1' : '0'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }

  Future<void> initialize() async {
    _db = await openDatabase(
      databasePath ?? '${await getDatabasesPath()}/nexus_remote.sqlite',
      version: 3,
      onCreate: (db, version) async {
        await _createTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        await _createTables(db);
      },
    );
    try {
      final rows = await _db?.query('settings');
      if (rows != null) {
        for (final row in rows) {
          final k = row['key'] as String;
          final v = row['value'] as String;
          if (k == 'touchpad_sensitivity') {
            final parsed = double.tryParse(v);
            if (parsed != null) touchpadSensitivity = parsed.clamp(0.25, 3.0);
          } else if (k == 'precision_mode') {
            precisionMode = v == '1' || v == 'true';
          }
        }
      }
    } catch (_) {}
    final rows = await _db!.query('drafts', where: 'host_id=?', whereArgs: [hostId]);
    if (rows.isNotEmpty) {
      draft = rows.first['text'] as String;
      _draftRevision = rows.first['revision'] as int;
    }
    final recordings = await _db!.query('recordings', where: 'host_id=?', whereArgs: [hostId], limit: 1);
    if (recordings.isNotEmpty) pendingRecording = recordings.first['path'] as String;
    status = 'Disconnected';
    notifyListeners();
    await connect();
  }

  static Future<void> _createTables(Database db) async {
    // 'hosts' (v1/v2 standalone app) is intentionally not created: endpoints
    // come from the host app now. An old table in an existing file is ignored.
    await db.execute('CREATE TABLE IF NOT EXISTS drafts (host_id TEXT PRIMARY KEY, text TEXT NOT NULL, revision INTEGER NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS recordings (id TEXT PRIMARY KEY, host_id TEXT NOT NULL, path TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS applied_results (id TEXT PRIMARY KEY, host_id TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  }

  HttpClient _pinnedClient(String pin) {
    final expected = pin.replaceAll(':', '').replaceAll(' ', '').toUpperCase();
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false));
    client.badCertificateCallback = (certificate, host, port) {
      final actual = sha256.convert(certificate.der).toString().toUpperCase();
      return expected.length == 64 && actual == expected;
    };
    client.connectionTimeout = const Duration(seconds: 8);
    return client;
  }

  /// Closes the connection and stops reconnecting. [retry] resumes.
  Future<void> disconnect() async {
    _terminalAuthFailure = true;
    _reconnect?.cancel();
    _reconnect = null;
    final socket = _socket;
    _socket = null;
    connected = false;
    status = 'Disconnected';
    _heartbeat?.cancel();
    _windowsTimer?.cancel();
    notifyListeners();
    await socket?.close();
  }

  Future<void> retry() async {
    _terminalAuthFailure = false;
    _unauthorizedReported = false;
    _reconnect?.cancel();
    _reconnect = null;
    _reconnectAttempt = 0;
    _socket?.close();
    _socket = null;
    connected = false;
    error = null;
    status = 'Connecting';
    notifyListeners();
    await connect();
  }

  Uri _addressUri(String address, String path) {
    var input = address.trim();
    for (final scheme in ['https://', 'http://', 'wss://', 'ws://']) {
      if (input.startsWith(scheme)) input = input.substring(scheme.length);
    }
    while (input.endsWith('/')) {
      input = input.substring(0, input.length - 1);
    }
    final uri = Uri.parse('https://$input');
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const FormatException('Invalid computer address');
    }
    return uri.replace(port: uri.hasPort ? uri.port : endpoint.port, path: path, query: '', fragment: '');
  }

  Future<void> connect() async {
    if (connected || _connecting || _disposed) return;
    _connecting = true;
    status = 'Connecting';
    error = null;
    notifyListeners();
    try {
      Object? lastError;
      var sawHandshake = false;
      var unauthorized = false;
      for (final host in endpoint.hosts) {
        if (_disposed) return;
        try {
          final uri = _addressUri(host, '/ws').replace(scheme: 'wss');
          _socket = await WebSocket.connect(uri.toString(),
              headers: {'Authorization': 'Bearer ${endpoint.token}'},
              customClient: _pinnedClient(endpoint.fingerprint));
          address = host;
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          if (_isAuthFailure(e)) {
            unauthorized = true;
            break;
          }
          if (e is HandshakeException) sawHandshake = true;
        }
      }
      if (unauthorized) {
        _terminalAuthFailure = true;
        status = 'Credential revoked';
        error = lastError.toString();
        _onDisconnect();
        _reportUnauthorized();
        return;
      }
      if (_socket == null || lastError != null) {
        if (sawHandshake) status = 'Certificate changed';
        _onDisconnect();
        error = (lastError ?? 'No address configured').toString();
        notifyListeners();
        return;
      }
      connected = true;
      _reconnect?.cancel();
      _reconnectAttempt = 0;
      status = 'Connected';
      notifyListeners();
      _socket!.listen(_onMessage, onDone: _onDisconnect, onError: (_) => _onDisconnect(),
          cancelOnError: true);
      try {
        final host = await rpc('host.info', {});
        platform = host['platform']?.toString() ?? '';
        final capabilities = Map<String, dynamic>.from(host['capabilities'] as Map);
        inputSupported = capabilities['input'] == 'supported';
        speechSupported = capabilities['speech'] == 'supported';
        mediaSupported = capabilities['media'] == 'supported';
        windowsSupported = capabilities['windows'] == 'supported';
        notifyListeners();
        await rpc('controller.acquire', {});
        _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
          unawaited(rpc('controller.heartbeat', {}).then((_) {}, onError: (Object _) {}));
        });
        _windowsTimer?.cancel();
        if (windowsSupported) {
          _windowsTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
            unawaited(refreshWindows());
          });
          unawaited(refreshWindows());
          unawaited(refreshApps());
        }
      } catch (e) {
        _onDisconnect();
        error = e.toString();
        notifyListeners();
      }
    } finally {
      _connecting = false;
    }
  }

  static bool _isAuthFailure(Object e) {
    final text = e.toString();
    return text.contains('401') || text.contains('403');
  }

  void _reportUnauthorized() {
    if (_unauthorizedReported) return;
    _unauthorizedReported = true;
    onUnauthorized?.call();
  }

  void _onMessage(dynamic data) {
    if (data is! String) return;
    try {
      final message = jsonDecode(data) as Map<String, dynamic>;
      final pending = _pending.remove(message['id']?.toString());
      if (pending == null) return;
      if (message['error'] is Map) {
        pending.completeError(StateError((message['error'] as Map)['message'].toString()));
      } else {
        pending.complete(Map<String, dynamic>.from(message['result'] as Map));
      }
    } catch (_) {}
  }

  void _onDisconnect() {
    final previousSocket = _socket;
    connected = false;
    inputSupported = false;
    speechSupported = false;
    mediaSupported = false;
    windowsSupported = false;
    openWindows = [];
    installedApps = [];
    _windowsTimer?.cancel();
    _windowsTimer = null;
    if (!_terminalAuthFailure && status != 'Certificate changed') status = 'Disconnected';
    _heartbeat?.cancel();
    _heartbeat = null;
    _socket = null;
    previousSocket?.close();
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(StateError('Connection lost'));
    }
    _pending.clear();
    notifyListeners();
    if (!_terminalAuthFailure && !_disposed && _reconnect == null) {
      const delays = [1, 2, 4, 8, 15];
      final seconds = delays[_reconnectAttempt.clamp(0, delays.length - 1)];
      _reconnectAttempt++;
      final jitter = 0.9 + math.Random().nextDouble() * 0.2;
      _reconnect = Timer(Duration(milliseconds: (seconds * jitter * 1000).round()), () {
        _reconnect = null;
        if (!connected && !_disposed) unawaited(connect());
      });
    }
  }

  Future<Map<String, dynamic>> rpc(String method, Map<String, dynamic> params) async {
    if (!connected || _socket == null) throw StateError('Computer disconnected');
    final id = const Uuid().v4();
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _socket!.add(jsonEncode({'version': 1, 'id': id, 'method': method, 'params': params}));
    try {
      return await completer.future.timeout(const Duration(seconds: 8));
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> move(int dx, int dy) => rpc('input.move', {'dx': dx, 'dy': dy}).then((_) {});
  Future<void> scroll(int dx, int dy) => rpc('input.scroll', {'dx': dx, 'dy': dy}).then((_) {});
  Future<void> button(int button, bool down) =>
      rpc('input.button', {'button': button, 'down': down}).then((_) {});
  Future<void> key(String key) => rpc('input.key', {'key': key}).then((_) {});
  Future<void> click(int button) async {
    await this.button(button, true);
    await this.button(button, false);
  }

  Future<String> insert(String text) async {
    if (utf8.encode(text).length > 65536) throw StateError('Text exceeds 64 KiB');
    final id = const Uuid().v4();
    final response = await rpc('text.insert', {'operation_id': id, 'text': text});
    return response['status'] as String;
  }

  Future<String> transcribeRecording(String path, {String language = 'auto'}) async {
    final token = endpoint.token;
    final file = File(path);
    final bytes = await file.readAsBytes();
    if (bytes.length > 10 * 1024 * 1024) throw StateError('Recording exceeds 10 MiB');
    final jobId = path.split(Platform.pathSeparator).last.replaceAll('.wav', '');
    await _db!.insert('recordings', {'id': jobId, 'host_id': hostId, 'path': path},
        conflictAlgorithm: ConflictAlgorithm.replace);
    pendingRecording = path;
    transcriptionStatus = 'Uploading recording';
    notifyListeners();
    final client = _pinnedClient(endpoint.fingerprint);
    try {
      final request = await client.postUrl(_addressUri(address.isEmpty ? endpoint.hosts.first : address, '/transcribe'));
      request.headers.set('Authorization', 'Bearer $token');
      request.headers.set('X-Job-ID', jobId);
      request.headers.set('X-Language', language);
      request.headers.set('X-Content-SHA256', sha256.convert(bytes).toString());
      request.headers.contentType = ContentType('audio', 'wav');
      request.contentLength = bytes.length;
      request.add(bytes);
      transcriptionStatus = 'Transcribing on computer';
      notifyListeners();
      final response = await request.close().timeout(const Duration(minutes: 7));
      final result = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, dynamic>;
      if (response.statusCode != 200) throw StateError(result['error']?.toString() ?? 'Transcription failed');
      final state = result['status']?.toString();
      if (state == 'no_speech') {
        transcriptionStatus = 'No speech detected';
        notifyListeners();
        return '';
      }
      if (state != 'completed') throw StateError('Transcription did not complete');
      final text = result['text'] as String;
      await _db!.transaction((tx) async {
        final applied = await tx.query('applied_results', where: 'id=?', whereArgs: [jobId]);
        if (applied.isNotEmpty) return;
        final rows = await tx.query('drafts', where: 'host_id=?', whereArgs: [hostId]);
        final current = rows.isEmpty ? '' : rows.first['text'] as String;
        draft = current.isEmpty ? text : '$current\n$text';
        _draftRevision++;
        await tx.insert('drafts', {'host_id': hostId, 'text': draft, 'revision': _draftRevision},
            conflictAlgorithm: ConflictAlgorithm.replace);
        await tx.insert('applied_results', {'id': jobId, 'host_id': hostId});
      });
      transcriptionStatus = 'Transcription added to draft';
      notifyListeners();
      return text;
    } catch (e) {
      transcriptionStatus = 'Transcription failed. Recording is saved for retry.';
      notifyListeners();
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<void> rememberRecording(String path) async {
    final id = path.split(Platform.pathSeparator).last.replaceAll('.wav', '');
    await _db!.insert('recordings', {'id': id, 'host_id': hostId, 'path': path},
        conflictAlgorithm: ConflictAlgorithm.replace);
    pendingRecording = path;
    transcriptionStatus = 'Recording saved. Connect and retry transcription.';
    notifyListeners();
  }

  Future<void> discardPendingRecording() async {
    final path = pendingRecording;
    if (path == null) return;
    final file = File(path);
    if (await file.exists()) await file.delete();
    await _db!.delete('recordings', where: 'path=?', whereArgs: [path]);
    final remaining = await _db!.query('recordings', where: 'host_id=?', whereArgs: [hostId], limit: 1);
    pendingRecording = remaining.isEmpty ? null : remaining.first['path'] as String;
    transcriptionStatus = 'Saved recording discarded';
    notifyListeners();
  }

  Future<void> saveDraft(String value) async {
    draft = value;
    _draftRevision++;
    await _db!.insert('drafts', {'host_id': hostId, 'text': value, 'revision': _draftRevision},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> refreshWindows() async {
    if (!connected || !windowsSupported) return;
    try {
      final res = await rpc('window.list', {});
      if (res['windows'] is List) {
        openWindows = (res['windows'] as List)
            .map((e) => DesktopWindow.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> windowAction(String windowId, String action) async {
    try {
      await rpc('window.action', {'window_id': windowId, 'action': action});
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await refreshWindows();
    } catch (_) {}
  }

  Future<void> activateWindow(String windowId) => windowAction(windowId, 'activate');
  Future<void> minimizeWindow(String windowId) => windowAction(windowId, 'minimize');
  Future<void> maximizeWindow(String windowId) => windowAction(windowId, 'maximize');
  Future<void> closeWindow(String windowId) => windowAction(windowId, 'close');
  Future<void> showDesktop() => windowAction('', 'show_desktop');

  Future<void> refreshApps() async {
    if (!connected) return;
    try {
      final res = await rpc('apps.list', {});
      if (res['apps'] is List) {
        installedApps = (res['apps'] as List)
            .map((e) => DesktopApp.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> launchApp(String appId, [String? exec]) async {
    try {
      final params = <String, dynamic>{'app_id': appId};
      if (exec != null) params['exec'] = exec;
      await rpc('apps.launch', params);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await refreshWindows();
    } catch (_) {}
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnect?.cancel();
    _heartbeat?.cancel();
    _windowsTimer?.cancel();
    _socket?.close();
    _db?.close();
    super.dispose();
  }
}
