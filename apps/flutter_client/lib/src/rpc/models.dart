// Dart mirrors of the RPC result types in packages/rpc-types/src/index.ts.
// Only the fields the client actually renders are modeled.

class WindowInfo {
  final String windowId;
  final String title;
  final String wmClass;
  final int desktop;
  final String? icon; // data: URI
  final String? appId;

  WindowInfo({
    required this.windowId,
    required this.title,
    required this.wmClass,
    required this.desktop,
    this.icon,
    this.appId,
  });

  factory WindowInfo.fromJson(Map<String, dynamic> j) => WindowInfo(
        windowId: j['windowId'] as String,
        title: (j['title'] as String?) ?? '',
        wmClass: (j['wmClass'] as String?) ?? '',
        desktop: (j['desktop'] as num?)?.toInt() ?? 0,
        icon: j['icon'] as String?,
        appId: j['appId'] as String?,
      );
}

class AppInfo {
  final String appId;
  final String name;
  final String? icon; // data: URI
  final String? wmClass;

  AppInfo({required this.appId, required this.name, this.icon, this.wmClass});

  factory AppInfo.fromJson(Map<String, dynamic> j) => AppInfo(
        appId: j['appId'] as String,
        name: (j['name'] as String?) ?? j['appId'] as String,
        icon: j['icon'] as String?,
        wmClass: j['wmClass'] as String?,
      );
}

class FileEntry {
  final String name;
  final String path;
  final int size;
  final bool isDirectory;
  final String modifiedAt;
  final String mimeType;

  FileEntry({
    required this.name,
    required this.path,
    required this.size,
    required this.isDirectory,
    required this.modifiedAt,
    required this.mimeType,
  });

  factory FileEntry.fromJson(Map<String, dynamic> j) => FileEntry(
        name: j['name'] as String,
        path: j['path'] as String,
        size: (j['size'] as num?)?.toInt() ?? 0,
        isDirectory: j['isDirectory'] as bool? ?? false,
        modifiedAt: (j['modifiedAt'] as String?) ?? '',
        mimeType: (j['mimeType'] as String?) ?? '',
      );
}

/// A phone-shaped virtual display on the PC running one app (Tier 1).
class AppSessionInfo {
  final String sessionId;
  final String appId;
  final String name;
  final String? icon;
  final String display;
  final int width;
  final int height;
  final double dpr;
  final String status; // starting | running | exited

  AppSessionInfo({
    required this.sessionId,
    required this.appId,
    required this.name,
    this.icon,
    required this.display,
    required this.width,
    required this.height,
    required this.dpr,
    required this.status,
  });

  factory AppSessionInfo.fromJson(Map<String, dynamic> j) => AppSessionInfo(
        sessionId: j['sessionId'] as String,
        appId: (j['appId'] as String?) ?? '',
        name: (j['name'] as String?) ?? 'App',
        icon: j['icon'] as String?,
        display: (j['display'] as String?) ?? '',
        width: (j['width'] as num?)?.toInt() ?? 0,
        height: (j['height'] as num?)?.toInt() ?? 0,
        dpr: (j['dpr'] as num?)?.toDouble() ?? 1,
        status: (j['status'] as String?) ?? 'running',
      );
}

/// An AI agent CLI on the PC (Claude Code, Cursor CLI, demo agent).
class AgentInfo {
  final String id;
  final String name;
  final bool available;

  AgentInfo({required this.id, required this.name, required this.available});

  factory AgentInfo.fromJson(Map<String, dynamic> j) => AgentInfo(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? j['id'] as String,
        available: j['available'] as bool? ?? false,
      );
}

class AgentSessionInfo {
  final String agentSessionId;
  final String agent;
  final String cwd;
  final String title;
  final bool busy;
  final String status;

  AgentSessionInfo({
    required this.agentSessionId,
    required this.agent,
    required this.cwd,
    required this.title,
    required this.busy,
    required this.status,
  });

  factory AgentSessionInfo.fromJson(Map<String, dynamic> j) => AgentSessionInfo(
        agentSessionId: j['agentSessionId'] as String,
        agent: (j['agent'] as String?) ?? '',
        cwd: (j['cwd'] as String?) ?? '',
        title: (j['title'] as String?) ?? 'Agent',
        busy: j['busy'] as bool? ?? false,
        status: (j['status'] as String?) ?? 'running',
      );
}

/// Normalized event from the host agent gateway.
class AgentEvent {
  final int seq;
  final int ts;
  final String kind;
  final String? text;
  final String? toolName;
  final String? toolInput;
  final String? toolOutput;
  final String? refId;

  AgentEvent({
    required this.seq,
    required this.ts,
    required this.kind,
    this.text,
    this.toolName,
    this.toolInput,
    this.toolOutput,
    this.refId,
  });

  factory AgentEvent.fromJson(Map<String, dynamic> j) => AgentEvent(
        seq: (j['seq'] as num?)?.toInt() ?? 0,
        ts: (j['ts'] as num?)?.toInt() ?? 0,
        kind: (j['kind'] as String?) ?? 'status',
        text: j['text'] as String?,
        toolName: j['toolName'] as String?,
        toolInput: j['toolInput'] as String?,
        toolOutput: j['toolOutput'] as String?,
        refId: j['refId'] as String?,
      );
}

class CaptureRegion {
  final int x, y, width, height;
  CaptureRegion(this.x, this.y, this.width, this.height);

  factory CaptureRegion.fromJson(Map<String, dynamic> j) => CaptureRegion(
        (j['x'] as num).toInt(),
        (j['y'] as num).toInt(),
        (j['width'] as num).toInt(),
        (j['height'] as num).toInt(),
      );
}

/// "org.gnome.Calculator" → "orggnomecalculator". Dashes/dots vary between the
/// .desktop id and the runtime WM_CLASS, so fuzzy matching normalizes both.
/// Mirrors normClass() in apps/mobile-client/src/app/page.tsx.
String normClass(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// True if a running window belongs to an installed app.
bool windowMatchesApp(WindowInfo w, AppInfo a) {
  if (w.appId != null && w.appId == a.appId) return true;
  final nWin = normClass(w.wmClass.split('.').last);
  final nApp = normClass(a.wmClass ?? a.appId);
  return nWin.length >= 4 &&
      nApp.length >= 4 &&
      (nApp.contains(nWin) || nWin.contains(nApp));
}

/// Prefer an app's launcher name over the raw window title in the running row.
String bestWindowName(WindowInfo w, List<AppInfo> apps) {
  if (w.appId != null) {
    for (final a in apps) {
      if (a.appId == w.appId) return a.name;
    }
  }
  final cls = w.wmClass.split('.').last;
  if (cls.isEmpty) return w.title;
  final words = cls.replaceAll(RegExp(r'[-_]'), ' ').split(' ');
  return words
      .map((s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}')
      .join(' ');
}
