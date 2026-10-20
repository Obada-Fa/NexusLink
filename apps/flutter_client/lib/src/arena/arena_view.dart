import 'package:flutter/material.dart';
import '../chats/chat_models.dart';
import '../theme/nexus_theme.dart';
import 'office_models.dart';
import 'office_scene.dart';

/// The Arena's office view shares the live monitor's status and chat actions.
class ArenaView extends StatelessWidget {
  const ArenaView({
    super.key,
    required this.chats,
    required this.offline,
    required this.onOpen,
    this.onLongPress,
  });
  final List<ChatSummary> chats;
  final bool offline;
  final ValueChanged<ChatSummary> onOpen;
  final ValueChanged<ChatSummary>? onLongPress;

  @override
  Widget build(BuildContext context) {
    final projects = officeProjects(chats);
    final working = chats.where((c) => c.running).length;
    final attention = chats.where((c) => c.needsAttention).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(NX.pad, 16, NX.pad, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'THE OFFICE',
            style: TextStyle(
              fontSize: 23,
              fontWeight: FontWeight.w900,
              letterSpacing: 3,
              color: Color(0xFFF2DFB9),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            offline
                ? 'Offline · last known positions. Reconnect for live activity.'
                : '$working working · $attention ${attention == 1 ? 'needs' : 'need'} you · ${projects.length} ${projects.length == 1 ? 'project' : 'projects'}',
            style: TextStyle(
              color: offline ? NX.waiting : NX.textDim,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'One room per project. Puppets move with reported activity. Tap an agent to open its chat.',
            style: TextStyle(color: NX.textDim, fontSize: 12, height: 1.5),
          ),
          if (chats.isEmpty)
            Container(
              margin: const EdgeInsets.only(top: 16),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: NX.surface2,
                border: Border.all(color: NX.line),
              ),
              child: const Column(
                children: [
                  Icon(Icons.desk_outlined, color: Color(0xFFF2DFB9), size: 36),
                  SizedBox(height: 12),
                  Text(
                    'The office is quiet.',
                    style: TextStyle(
                      color: NX.text,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Start a task to give an agent a desk. Your current filters also apply here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: NX.textDim, height: 1.5),
                  ),
                ],
              ),
            ),
          for (final project in projects)
            _ProjectRoom(
              key: ValueKey(project.id),
              project: project,
              offline: offline,
              onOpen: onOpen,
              onLongPress: onLongPress,
            ),
        ],
      ),
    );
  }
}

class _ProjectRoom extends StatelessWidget {
  const _ProjectRoom({
    super.key,
    required this.project,
    required this.offline,
    required this.onOpen,
    this.onLongPress,
  });
  final OfficeProject project;
  final bool offline;
  final ValueChanged<ChatSummary> onOpen;
  final ValueChanged<ChatSummary>? onLongPress;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 20),
    decoration: BoxDecoration(
      color: const Color(0xFF141D26),
      border: Border.all(color: const Color(0xFF3B4A50), width: 2),
      borderRadius: BorderRadius.circular(6),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(
                Icons.apartment_rounded,
                color: Color(0xFFE6C58B),
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  project.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: NX.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${project.chats.length} agents',
                style: const TextStyle(color: NX.textDim, fontSize: 11),
              ),
            ],
          ),
        ),
        // Additional floors prevent crowding without hiding active agents.
        for (var start = 0; start < project.chats.length; start += 8) ...[
          if (project.chats.length > 8)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Text(
                'FLOOR ${start ~/ 8 + 1}',
                style: const TextStyle(
                  color: NX.textDim,
                  fontSize: 10,
                  letterSpacing: 2,
                ),
              ),
            ),
          OfficeScene(
            key: ValueKey('${project.id}:$start'),
            chats: project.chats.skip(start).take(8).toList(),
            offline: offline,
            numberOffset: start,
            onOpen: onOpen,
            onLongPress: onLongPress,
          ),
          for (
            var i = start;
            i < (start + 8).clamp(0, project.chats.length);
            i++
          )
            _AgentRow(
              chat: project.chats[i],
              number: i + 1,
              offline: offline,
              onTap: () => onOpen(project.chats[i]),
              onLongPress: onLongPress == null
                  ? null
                  : () => onLongPress!(project.chats[i]),
            ),
        ],
        const SizedBox(height: 6),
      ],
    ),
  );
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({
    required this.chat,
    required this.number,
    required this.offline,
    required this.onTap,
    this.onLongPress,
  });
  final ChatSummary chat;
  final int number;
  final bool offline;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final status = offline ? NX.idle : Status.color(chat.liveState);
    final label = offline
        ? '${Status.label(chat.liveState)} · last known'
        : Status.label(chat.liveState);
    return Semantics(
      button: true,
      label:
          'Agent $number, ${Providers.name(chat.source)}, ${chat.title}, $label',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 26,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Providers.color(chat.source).withValues(alpha: .16),
                    border: Border.all(color: Providers.color(chat.source)),
                  ),
                  child: Text(
                    '$number',
                    style: TextStyle(
                      color: Providers.color(chat.source),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        chat.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: NX.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${Providers.name(chat.source)} · $label · ${officeStationFor(chat).label}',
                        style: TextStyle(
                          color: status,
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                      if (chat.stepLabel.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          chat.stepLabel,
                          maxLines: chat.needsAttention ? 3 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: NX.textDim,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  chat.needsAttention
                      ? Icons.priority_high_rounded
                      : Icons.chevron_right,
                  color: status,
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
