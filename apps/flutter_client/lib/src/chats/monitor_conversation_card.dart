import 'package:flutter/material.dart';
import '../widgets/agent_activity_icon.dart';
import 'chat_models.dart';

/// One conversation, one current state. Activity belongs inside its card.
class MonitorConversationCard extends StatelessWidget {
  const MonitorConversationCard({
    super.key,
    required this.chat,
    required this.offline,
    required this.onOpen,
  });
  final ChatSummary chat;
  final bool offline;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = offline
        ? colors.onSurfaceVariant
        : chat.needsAttention
        ? (chat.execution == 'needsReply'
              ? (theme.brightness == Brightness.dark
                    ? const Color(0xFFEBC36D)
                    : const Color(0xFF8A6415))
              : colors.error)
        : chat.running
        ? (theme.brightness == Brightness.dark
              ? const Color(0xFF74D9BB)
              : const Color(0xFF137760))
        : colors.onSurfaceVariant;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      elevation: 0,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: chat.needsAttention && !offline
              ? accent.withValues(alpha: .4)
              : colors.outlineVariant.withValues(alpha: .5),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AgentMark(agentId: chat.source, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${chat.sourceName} · ${chat.folderName}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.arrow_outward,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                chat.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (chat.preview.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  chat.preview.replaceAll(RegExp(r'\s+'), ' '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${chat.monitorStatus}${offline ? ' · last known' : ''}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    chatRelativeTime(chat.activity),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    chat.canReply
                        ? 'Remote reply available'
                        : chat.running
                        ? 'Open live conversation'
                        : 'Open conversation',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
