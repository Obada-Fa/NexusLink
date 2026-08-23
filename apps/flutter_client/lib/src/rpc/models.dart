// Dart mirrors of the RPC result types in packages/rpc-types/src/index.ts.
// Only the fields the client actually renders are modeled.

import 'dart:convert';

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
class AgentModelOption {
  final String id;
  final String name;
  final bool? supportsEffort;
  const AgentModelOption({required this.id, required this.name, this.supportsEffort});
  factory AgentModelOption.fromJson(Map<String, dynamic> j) => AgentModelOption(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? j['id'] as String,
        supportsEffort: j['supportsEffort'] as bool?,
      );
}

/// Strip thinking / effort suffixes (`-high`, `-thinking-high`, `-xhigh-fast`).
String modelFamilyId(String id) {
  return id
      .replaceAll(RegExp(r'-thinking(?=-|$)', caseSensitive: false), '')
      .replaceAll(RegExp(r'-(low|medium|high|xhigh|max)(-fast)?$', caseSensitive: false), '')
      .replaceAll(RegExp(r'-fast$', caseSensitive: false), '')
      .replaceAll(RegExp(r'-+$'), '');
}

/// Collapse CLI catalogs that encode thinking in the model id into one row
/// per family. The thinking chip picks the variant at send time.
List<AgentModelOption> collapseModelFamilies(List<AgentModelOption> models) {
  final seen = <String>{};
  final out = <AgentModelOption>[];
  for (final m in models) {
    final fam = modelFamilyId(m.id);
    if (fam.isEmpty || seen.contains(fam)) continue;
    seen.add(fam);
    final name = m.name
        .replaceAll(
            RegExp(r'\s*\((High|Medium|Low|Extra High|Max|Thinking).*?\)',
                caseSensitive: false),
            '')
        .replaceAll(RegExp(r'\s+Thinking\s*$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s*\(current.*\)$', caseSensitive: false), '')
        .trim();
    out.add(AgentModelOption(
      id: fam,
      name: name.isEmpty ? fam : name,
      supportsEffort: m.supportsEffort,
    ));
  }
  return out;
}

/// Check whether a model supports thinking/effort parameters.
bool isModelEffortSupported(String? agentId, String? modelId, [List<AgentModelOption>? catalog]) {
  final agent = (agentId ?? '').toLowerCase().trim();
  final m = (modelId ?? '').toLowerCase().trim();
  final fam = modelFamilyId(m);

  if (catalog != null && catalog.isNotEmpty) {
    for (final opt in catalog) {
      if (opt.id.toLowerCase() == m || modelFamilyId(opt.id).toLowerCase() == fam) {
        if (opt.supportsEffort != null) {
          return opt.supportsEffort!;
        }
      }
    }
  }

  if (agent == 'antigravity') {
    if (m.isEmpty || m == 'default' || m == 'auto') return true;
    if (m.contains('claude') || m.contains('gpt-') || m.contains('grok') || m.contains('composer')) {
      return false;
    }
    return m.contains('gemini');
  }

  if (agent == 'claude') {
    if (m.isEmpty || m == 'default' || m == 'sonnet' || m.contains('sonnet')) return true;
    if (m == 'opus' || m == 'haiku' || m.contains('opus') || m.contains('haiku')) return false;
    return true;
  }

  if (agent == 'cursor') {
    if (m == 'auto') return false;
    if (m.contains('haiku') || m == 'gpt-4o-mini' || m.contains('gpt-4o-mini')) return false;
    return true;
  }

  if (agent == 'opencode') {
    if (m.contains('non-reasoning') || m.contains('standard')) return false;
    return true;
  }

  if (agent == 'mock') {
    return true;
  }

  return true;
}

class AgentCapabilities {
  final List<String> modes;
  final List<String> thinkingLevels;
  final List<AgentModelOption> models;
  final bool images;
  /// OpenCode-only: 'go' | 'byok' | 'unknown'. Null for other agents.
  final String? plan;

  const AgentCapabilities({
    required this.modes,
    required this.thinkingLevels,
    required this.models,
    required this.images,
    this.plan,
  });

  static const empty = AgentCapabilities(
    modes: ['agent'],
    thinkingLevels: [],
    models: [],
    images: false,
  );

  factory AgentCapabilities.fromJson(dynamic raw) {
    if (raw is! Map) return AgentCapabilities.empty;
    final j = Map<String, dynamic>.from(raw);
    final modes = (j['modes'] as List?)
            ?.map((e) => '$e')
            .where((e) => e == 'agent' || e == 'plan' || e == 'ask')
            .toList() ??
        const ['agent'];
    final planRaw = j['plan'] as String?;
    return AgentCapabilities(
      modes: modes.isEmpty ? const ['agent'] : modes,
      thinkingLevels: (j['thinkingLevels'] as List?)
              ?.map((e) => '$e')
              .where((e) => e.isNotEmpty)
              .toList() ??
          const [],
      models: (j['models'] as List?)
              ?.whereType<Map>()
              .map((e) => AgentModelOption.fromJson(Map<String, dynamic>.from(e)))
              .toList() ??
          const [],
      images: j['images'] as bool? ?? false,
      plan: (planRaw == 'go' || planRaw == 'byok' || planRaw == 'unknown')
          ? planRaw
          : null,
    );
  }
}

class AgentInfo {
  final String id;
  final String name;
  final bool available;
  final String? icon; // data: URI
  final AgentCapabilities capabilities;

  AgentInfo({
    required this.id,
    required this.name,
    required this.available,
    this.icon,
    this.capabilities = AgentCapabilities.empty,
  });

  factory AgentInfo.fromJson(Map<String, dynamic> j) => AgentInfo(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? j['id'] as String,
        available: j['available'] as bool? ?? false,
        icon: j['icon'] as String?,
        capabilities: AgentCapabilities.fromJson(j['capabilities']),
      );
}

class AgentSessionInfo {
  final String agentSessionId;
  final String agent;
  final String cwd;
  final String title;
  final bool busy;
  final String status;
  final String? hostChatId;
  final String? icon;

  AgentSessionInfo({
    required this.agentSessionId,
    required this.agent,
    required this.cwd,
    required this.title,
    required this.busy,
    required this.status,
    this.hostChatId,
    this.icon,
  });

  factory AgentSessionInfo.fromJson(Map<String, dynamic> j) => AgentSessionInfo(
        agentSessionId: j['agentSessionId'] as String,
        agent: (j['agent'] as String?) ?? '',
        cwd: (j['cwd'] as String?) ?? '',
        title: (j['title'] as String?) ?? 'Agent',
        busy: j['busy'] as bool? ?? false,
        status: (j['status'] as String?) ?? 'running',
        hostChatId: j['hostChatId'] as String?,
        icon: j['icon'] as String?,
      );

  AgentSessionInfo copyWith({
    String? agentSessionId,
    String? agent,
    String? cwd,
    String? title,
    bool? busy,
    String? status,
    String? hostChatId,
    String? icon,
  }) =>
      AgentSessionInfo(
        agentSessionId: agentSessionId ?? this.agentSessionId,
        agent: agent ?? this.agent,
        cwd: cwd ?? this.cwd,
        title: title ?? this.title,
        busy: busy ?? this.busy,
        status: status ?? this.status,
        hostChatId: hostChatId ?? this.hostChatId,
        icon: icon ?? this.icon,
      );
}

class AgentHostChat {
  final String agent;
  final String hostChatId;
  final String title;
  final String cwd;
  final int updatedAt;
  final bool resumable;
  final String source;
  final String? icon;

  AgentHostChat({
    required this.agent,
    required this.hostChatId,
    required this.title,
    required this.cwd,
    required this.updatedAt,
    required this.resumable,
    required this.source,
    this.icon,
  });

  factory AgentHostChat.fromJson(Map<String, dynamic> j) => AgentHostChat(
        agent: (j['agent'] as String?) ?? '',
        hostChatId: (j['hostChatId'] as String?) ?? '',
        title: (j['title'] as String?) ?? 'Chat',
        cwd: (j['cwd'] as String?) ?? '',
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
        resumable: j['resumable'] as bool? ?? true,
        source: (j['source'] as String?) ?? '',
        icon: j['icon'] as String?,
      );
}

/// `git status` snapshot for the agent's current folder.
class GitWorkingTree {
  final String cwd;
  final String branch;
  final int ahead;
  final int behind;
  final int changed;
  final List<String> files;

  GitWorkingTree({
    required this.cwd,
    required this.branch,
    required this.ahead,
    required this.behind,
    required this.changed,
    required this.files,
  });

  factory GitWorkingTree.fromJson(Map<String, dynamic> j) => GitWorkingTree(
        cwd: (j['cwd'] as String?) ?? '',
        branch: (j['branch'] as String?) ?? '',
        ahead: (j['ahead'] as num?)?.toInt() ?? 0,
        behind: (j['behind'] as num?)?.toInt() ?? 0,
        changed: (j['changed'] as num?)?.toInt() ?? 0,
        files: (j['files'] as List?)?.map((e) => '$e').toList() ?? const [],
      );
}

String workingTreeSubtitle(GitWorkingTree git) {
  final bits = <String>[git.branch];
  if (git.ahead > 0) bits.add('ahead ${git.ahead}');
  if (git.behind > 0) bits.add('behind ${git.behind}');
  if (git.changed > 0) {
    bits.add('${git.changed} changed');
  } else {
    bits.add('clean');
  }
  return bits.join(' · ');
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
  final List<String> images;

  AgentEvent({
    required this.seq,
    required this.ts,
    required this.kind,
    this.text,
    this.toolName,
    this.toolInput,
    this.toolOutput,
    this.refId,
    this.images = const [],
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
        images: (j['images'] as List?)?.map((e) => '$e').toList() ?? const [],
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

bool isAgentToolEvent(AgentEvent e) =>
    (e.kind == 'tool-start' || e.kind == 'tool-end') &&
    e.toolName != 'ask_question' &&
    e.toolName != 'askQuestion';

/// Collapse a tool-start + matching tool-end into one row.
List<AgentEvent> mergeToolEvents(List<AgentEvent> events) {
  final out = <AgentEvent>[];
  final startIdx = <String, int>{};

  for (final e in events) {
    final ref = e.refId ?? '';
    if (e.kind == 'tool-start' && ref.isNotEmpty) {
      startIdx[ref] = out.length;
      out.add(e);
      continue;
    }
    if (e.kind == 'tool-end' && ref.isNotEmpty && startIdx.containsKey(ref)) {
      final i = startIdx.remove(ref)!;
      final start = out[i];
      out[i] = AgentEvent(
        seq: e.seq,
        ts: e.ts,
        kind: 'tool-end',
        toolName: e.toolName ?? start.toolName,
        toolInput: start.toolInput,
        toolOutput: e.toolOutput,
        refId: ref,
      );
      continue;
    }
    out.add(e);
  }
  return out;
}

class AgentDisplayItem {
  final AgentEvent? event;
  final List<AgentEvent>? tools;

  const AgentDisplayItem.event(this.event) : tools = null;
  const AgentDisplayItem.tools(this.tools) : event = null;

  bool get isToolGroup => tools != null;
}

bool _isAssistantTextEvent(AgentEvent e) =>
    e.kind == 'text' || e.kind == 'text-delta';

/// Consecutive tools become one expandable group so a Cursor run doesn't
/// flood the chat with a card per edit/shell.
/// Consecutive assistant text chunks are unified into a single markdown bubble.
List<AgentDisplayItem> groupAgentDisplay(List<AgentEvent> events) {
  final merged = mergeToolEvents(events);
  final out = <AgentDisplayItem>[];
  var i = 0;
  while (i < merged.length) {
    if (isAgentToolEvent(merged[i])) {
      final tools = <AgentEvent>[];
      while (i < merged.length && isAgentToolEvent(merged[i])) {
        tools.add(merged[i]);
        i++;
      }
      out.add(AgentDisplayItem.tools(tools));
    } else if (_isAssistantTextEvent(merged[i])) {
      final first = merged[i];
      final buffer = StringBuffer(first.text ?? '');
      i++;
      while (i < merged.length && _isAssistantTextEvent(merged[i])) {
        buffer.write(merged[i].text ?? '');
        i++;
      }
      out.add(AgentDisplayItem.event(AgentEvent(
        seq: first.seq,
        ts: first.ts,
        kind: 'text',
        text: buffer.toString(),
      )));
    } else {
      out.add(AgentDisplayItem.event(merged[i]));
      i++;
    }
  }
  return out;
}

bool toolGroupRunning(List<AgentEvent> tools) =>
    tools.any((e) => e.kind == 'tool-start');

/// True when a tool-start never got a matching tool-end (host died, cancel
/// never arrived, etc.).
bool transcriptHasOpenTools(List<AgentEvent> events) =>
    mergeToolEvents(events).any((e) => e.kind == 'tool-start');

/// Pair leftover tool-starts with tool-end so the chat can leave "Working".
List<AgentEvent> closeOpenTools(
  List<AgentEvent> events, {
  String output = 'Interrupted.',
}) {
  final open = mergeToolEvents(events)
      .where((e) => e.kind == 'tool-start')
      .toList();
  if (open.isEmpty) return events;
  var seq = 0;
  for (final e in events) {
    if (e.seq > seq) seq = e.seq;
  }
  final ts = DateTime.now().millisecondsSinceEpoch;
  return [
    ...events,
    for (final e in open)
      AgentEvent(
        seq: ++seq,
        ts: ts,
        kind: 'tool-end',
        toolName: e.toolName,
        toolInput: e.toolInput,
        toolOutput: output,
        refId: (e.refId ?? '').isNotEmpty ? e.refId : 'orphan-$seq',
      ),
  ];
}

String toolGroupTitle(List<AgentEvent> tools) {
  final n = tools.length;
  final steps = n == 1 ? 'step' : 'steps';
  return toolGroupRunning(tools) ? 'Working…' : 'Finished $n $steps';
}

String _friendlyToolName(String name) {
  final l = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (l.contains('plan') || l == 'createroadmap' || l == 'settask' || l == 'todowrite') return 'Creating plan';
  if (l == 'glob' || l == 'grep' || l == 'search' || l == 'globfilesearch' || l == 'findbyname' || l == 'grepsearch') return 'Searching codebase';
  if (l == 'read' || l == 'readlints' || l == 'viewfile' || l == 'readfile') return 'Reading files';
  if (l == 'write' || l == 'edit' || l == 'replace' || l == 'editfile' || l == 'replacefilecontent' || l == 'writetofile' || l == 'writefile') return 'Editing files';
  if (l == 'shell' || l == 'bash' || l == 'runcommand' || l == 'task' || l == 'cmd') return 'Running command';
  if (l == 'list' || l == 'ls' || l == 'listdir') return 'Exploring folders';
  if (l == 'webfetch' || l == 'fetch' || l == 'readurlcontent' || l == 'searchweb') return 'Browsing web';
  if (l == 'askquestion' || l == 'askuser') return 'Asking a question';
  if (l == 'invokesubagent' || l == 'managesubagents' || l == 'sendmessage') return 'Coordinating agents';
  return name;
}

class ToolFileInfo {
  final String? filePath;
  final String? rawContent;
  final String title;
  final String? subtitle;
  final bool isPlan;
  final String? diff;

  const ToolFileInfo({
    this.filePath,
    this.rawContent,
    required this.title,
    this.subtitle,
    this.isPlan = false,
    this.diff,
  });
}

ToolFileInfo? extractToolFileInfo(AgentEvent e) {
  final name = (e.toolName ?? '').trim();
  if (name.isEmpty) return null;
  final norm = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  final isPlan = norm.contains('plan') ||
      norm == 'createroadmap' ||
      norm == 'settask' ||
      norm == 'todowrite';

  final isFile = norm == 'write' ||
      norm == 'read' ||
      norm == 'edit' ||
      norm == 'viewfile' ||
      norm == 'readfile' ||
      norm == 'writefile' ||
      norm == 'writetofile' ||
      norm == 'replacefilecontent' ||
      norm == 'editfile';

  Map<String, dynamic>? inputMap;
  if ((e.toolInput ?? '').trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(e.toolInput!);
      if (decoded is Map) {
        inputMap = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
  }

  Map<String, dynamic>? outputMap;
  if ((e.toolOutput ?? '').trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(e.toolOutput!);
      if (decoded is Map) {
        outputMap = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
  }

  String? filePath;
  String? rawContent;
  String? title;
  String? subtitle;

  if (inputMap != null) {
    final rawPath = inputMap['path'] ??
        inputMap['filePath'] ??
        inputMap['filepath'] ??
        inputMap['target_file'] ??
        inputMap['targetFile'] ??
        inputMap['TargetFile'] ??
        inputMap['AbsolutePath'] ??
        inputMap['absolute_path'] ??
        inputMap['planPath'] ??
        inputMap['plan_path'] ??
        inputMap['file'] ??
        inputMap['destination'] ??
        inputMap['Destination'];
    if (rawPath != null && '$rawPath'.trim().isNotEmpty) {
      filePath = '$rawPath'.trim();
    }

    final rawTitle = inputMap['title'] ??
        inputMap['name'] ??
        inputMap['Summary'] ??
        inputMap['description'];
    if (rawTitle != null && '$rawTitle'.trim().isNotEmpty) {
      title = '$rawTitle'.trim();
    }

    final rawText = inputMap['plan'] ??
        inputMap['CodeContent'] ??
        inputMap['code_content'] ??
        inputMap['content'] ??
        inputMap['markdown'] ??
        inputMap['text'] ??
        inputMap['ReplacementContent'];
    if (rawText != null && '$rawText'.trim().isNotEmpty) {
      rawContent = '$rawText'.trim();
    }

    final steps = inputMap['steps'] ?? inputMap['todos'] ?? inputMap['tasks'];
    if (steps is List && steps.isNotEmpty && rawContent == null) {
      final buf = StringBuffer('# ${title ?? "Implementation Plan"}\n\n');
      for (final s in steps) {
        if (s is Map) {
          final st = s['title'] ?? s['name'] ?? s['description'] ?? s['step'] ?? '';
          final sd = s['description'] ?? s['details'] ?? '';
          final status = '${s['status'] ?? ''}'.toLowerCase();
          final done = status == 'done' || status == 'completed' || s['completed'] == true;
          buf.writeln('- [${done ? "x" : " "}] **$st**${sd.isNotEmpty && sd != st ? "\n  $sd" : ""}');
        } else {
          buf.writeln('- [ ] $s');
        }
      }
      rawContent = buf.toString();
    }
  }

  if (outputMap != null) {
    if (filePath == null) {
      final rawPath = outputMap['path'] ?? outputMap['filePath'] ?? outputMap['targetFile'];
      if (rawPath != null && '$rawPath'.trim().isNotEmpty) filePath = '$rawPath'.trim();
    }
    if (rawContent == null) {
      final rawText = outputMap['plan'] ?? outputMap['content'] ?? outputMap['text'] ?? outputMap['result'];
      if (rawText != null && '$rawText'.trim().isNotEmpty) rawContent = '$rawText'.trim();
    }
  }

  final inputStr = (e.toolInput ?? '').trim();
  final outputStr = (e.toolOutput ?? '').trim();

  if (filePath == null && (inputStr.startsWith('/') || inputStr.startsWith('~/') || inputStr.startsWith('./') || inputStr.startsWith('file://'))) {
    filePath = inputStr;
  }

  if (rawContent == null) {
    if (isPlan) {
      if (inputStr.isNotEmpty && inputStr != name && !inputStr.startsWith('{')) {
        rawContent = inputStr.startsWith('#') ? inputStr : '# ${title ?? "Plan"}\n\n$inputStr';
      } else if (outputStr.isNotEmpty && !outputStr.startsWith('{')) {
        rawContent = outputStr.startsWith('#') ? outputStr : '# ${title ?? "Plan"}\n\n$outputStr';
      }
    }
  }

  if (isPlan) {
    title ??= 'Plan';
    subtitle ??= filePath ?? 'Agent Plan';
    rawContent ??= '# Plan\n\nPlan created by $name.';
    return ToolFileInfo(
      filePath: filePath,
      rawContent: rawContent,
      title: title,
      subtitle: subtitle,
      isPlan: true,
    );
  }

  if (filePath != null || isFile || (rawContent != null && rawContent.isNotEmpty)) {
    final cleanPath = filePath ?? '';
    final nameTitle = cleanPath.isNotEmpty ? cleanPath.split('/').last : name;
    return ToolFileInfo(
      filePath: filePath,
      rawContent: rawContent,
      title: title ?? nameTitle,
      subtitle: cleanPath.isNotEmpty ? cleanPath : null,
      isPlan: false,
    );
  }

  return null;
}

String toolGroupSummary(List<AgentEvent> tools) {
  final names = <String>[];
  for (final e in tools) {
    final n = (e.toolName ?? '').trim();
    if (n.isEmpty) continue;
    final friendly = _friendlyToolName(n);
    if (names.isEmpty || names.last != friendly) {
      names.add(friendly);
    }
  }
  return names.join(' · ');
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
