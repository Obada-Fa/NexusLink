import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rpc/models.dart';
import '../rpc/rpc_client.dart';
import 'ntfy.dart';
import 'ntfy_listener.dart';

const _topicPrefKey = 'nexuslink_ntfy_topic';
const _legacyTokenPrefKey = 'nexuslink_push_token';
const _legacyDeviceIdPrefKey = 'nexuslink_device_push_id';
const _ntfyChannel = MethodChannel('nexuslink/ntfy');

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  final Set<String> _processedEvents = <String>{};
  NtfyListener? _dartListener;
  String? _topic;

  Future<void> init() async {
    if (_initialized) return;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const linuxSettings = LinuxInitializationSettings(
      defaultActionName: 'Open',
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
      linux: linuxSettings,
    );

    try {
      await _plugin.initialize(
        settings: initSettings,
      );
      _initialized = true;
      await requestPermissions();
      await _ensureTopic();
      await startListener();
    } catch (e) {
      debugPrint('NotificationService init error: $e');
    }
  }

  Future<void> requestPermissions() async {
    if (kIsWeb) return;
    try {
      if (Platform.isAndroid) {
        final androidImpl = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        await androidImpl?.requestNotificationsPermission();
      } else if (Platform.isIOS) {
        final iosImpl = _plugin.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
        await iosImpl?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
      } else if (Platform.isMacOS) {
        final macImpl = _plugin.resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin>();
        await macImpl?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
      }
    } catch (e) {
      debugPrint('Error requesting notification permissions: $e');
    }
  }

  Future<String> _ensureTopic() async {
    if (_topic != null && isNtfyTopic(_topic!)) return _topic!;
    final prefs = await SharedPreferences.getInstance();
    var topic = prefs.getString(_topicPrefKey) ??
        prefs.getString(_legacyTokenPrefKey) ??
        prefs.getString(_legacyDeviceIdPrefKey);
    if (topic == null || !isNtfyTopic(topic)) {
      topic = generateNtfyTopic();
    }
    _topic = topic;
    await prefs.setString(_topicPrefKey, topic);
    await prefs.setString(_legacyTokenPrefKey, topic);
    await prefs.setString('nexuslink_push_provider', 'ntfy');
    await prefs.setString(
        'nexuslink_push_endpoint', ntfyEndpointForTopic(topic));
    return topic;
  }

  Future<void> registerWithHost(RpcClient client) async {
    try {
      final topic = await _ensureTopic();
      final deviceName = Platform.isAndroid
          ? 'Android Device'
          : Platform.isIOS
              ? 'iOS Device'
              : 'Desktop/Web Device';
      final payload = ntfyRegistrationPayload(
        topic: topic,
        deviceName: deviceName,
      );
      await client.request('push.registerToken', payload);
      await startListener();
    } catch (e) {
      debugPrint(
          '[NotificationService] failed to register push token with host: $e');
    }
  }

  Future<void> startListener() async {
    final topic = await _ensureTopic();
    if (kIsWeb) return;
    try {
      if (Platform.isAndroid) {
        await _ntfyChannel.invokeMethod('start', {'topic': topic});
        await _dartListener?.stop();
        return;
      }
    } on MissingPluginException {
      // init() runs before the Android activity binds the channel. Retry happens
      // from registerWithHost after the engine is up. Dart SSE cannot survive
      // Android backgrounding, so do not fall back to it here.
      if (Platform.isAndroid) {
        debugPrint('[ntfy] native listener not ready yet');
        return;
      }
    } catch (e) {
      debugPrint('[ntfy] native listener failed: $e');
      if (Platform.isAndroid) return;
    }
    _dartListener ??= NtfyListener(applyNtfyPayload);
    await _dartListener!.start(topic);
  }

  Future<Map<String, dynamic>> sendTestAlert(RpcClient client) async {
    await registerWithHost(client);
    final raw = await client.request('push.sendTest', {
      'title': 'NexusLink test',
      'body': 'Background alerts are working.',
    });
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return {};
  }

  void applyNtfyPayload(NtfyPayload payload) {
    final kind = payload.kind ?? '';
    if (kind == 'result' || kind == 'permission-request' || kind == 'error') {
      handleAgentEvent(
        payload.agentSessionId,
        AgentEvent(
          seq: payload.seq ?? 0,
          ts: DateTime.now().millisecondsSinceEpoch,
          kind: kind,
          text: payload.body,
        ),
        sessionTitle: payload.sessionTitle,
      );
      return;
    }
    unawaited(showAgentFinishedNotification(
      sessionTitle: payload.sessionTitle ?? 'Test',
      summary: payload.body.isEmpty ? payload.title : payload.body,
    ));
  }

  void handleAgentEvent(
    String? sessionId,
    AgentEvent event, {
    String? sessionTitle,
  }) {
    if (sessionId != null) {
      final key = agentEventKey(sessionId, event.seq, event.kind);
      if (_processedEvents.contains(key)) return;
      _processedEvents.add(key);
      if (_processedEvents.length > 500) {
        _processedEvents.removeAll(_processedEvents.take(100).toList());
      }
    }

    if (event.kind == 'result') {
      showAgentFinishedNotification(
        sessionTitle: sessionTitle,
        summary: event.text,
      );
    } else if (event.kind == 'permission-request') {
      showPermissionRequiredNotification(
        toolName: event.toolName ?? 'Action',
        sessionTitle: sessionTitle,
        input: event.toolInput,
      );
    } else if (event.kind == 'error') {
      final raw = (event.text ?? '').trim();
      final summary = (raw.isEmpty ||
              raw.toLowerCase().startsWith('declaring permissions: cortex tool') ||
              raw.toLowerCase().contains(
                  'is not a valid artifact path; artifacts must be in'))
          ? 'The agent has finished working.'
          : raw;
      showAgentFinishedNotification(
        sessionTitle: sessionTitle,
        summary: summary,
      );
    }
  }

  Future<void> showAgentFinishedNotification({
    String? sessionTitle,
    String? summary,
  }) async {
    final title = sessionTitle != null && sessionTitle.isNotEmpty
        ? 'Agent Done ($sessionTitle)'
        : 'Agent is Done';
    final body = (summary != null && summary.trim().isNotEmpty)
        ? summary.trim()
        : 'The agent has finished working.';

    await _show(
      id: 1001,
      title: title,
      body: body,
      channelId: 'agent_status',
      channelName: 'Agent Status',
      channelDescription: 'Notifications when an AI agent finishes working',
    );
  }

  Future<void> showPermissionRequiredNotification({
    required String toolName,
    String? sessionTitle,
    String? input,
  }) async {
    final title = sessionTitle != null && sessionTitle.isNotEmpty
        ? 'Permission Required ($sessionTitle)'
        : 'Agent Permission Required';
    final body =
        'Agent wants to run $toolName${input != null && input.isNotEmpty ? ': $input' : ''}';

    await _show(
      id: 1002,
      title: title,
      body: body,
      channelId: 'agent_permissions',
      channelName: 'Agent Permissions',
      channelDescription: 'Notifications when an AI agent requests permission',
    );
  }

  Future<void> _show({
    required int id,
    required String title,
    required String body,
    required String channelId,
    required String channelName,
    required String channelDescription,
  }) async {
    if (!_initialized) {
      await init();
    }

    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.max,
      priority: Priority.high,
      showWhen: true,
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const linuxDetails = LinuxNotificationDetails();

    final details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
      linux: linuxDetails,
    );

    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: details,
      );
    } catch (e) {
      debugPrint('Error displaying notification: $e');
    }
  }
}
