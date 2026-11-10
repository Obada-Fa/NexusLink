// Agents → New chat: pick or create a folder (the existing picker), then
// choose between a chat here in Nexus (unchanged) and a session started on
// the PC for the Claude app.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../screens/cwd_picker.dart';
import '../state/connection.dart';
import '../theme/nexus_theme.dart';
import 'claude_app_session_screen.dart';
import 'claude_app_sessions.dart';

/// Runs the New chat flow. [openNexusChat] opens today's Nexus chat for a
/// folder (null: let the chat screen ask, as before).
Future<void> startNewChatFlow({
  required BuildContext context,
  required WidgetRef ref,
  required void Function(String? folder) openNexusChat,
  String? folder,
}) async {
  final client = ref.read(activeClientProvider);
  if (client == null) {
    openNexusChat(folder);
    return;
  }
  final cwd =
      folder ?? await pickWorkingDirectory(context: context, client: client);
  if (cwd == null || !context.mounted) return;
  final choice = await showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: const Color(0xFF151522),
    builder: (_) => NewChatChoiceSheet(cwd: cwd),
  );
  if (!context.mounted || choice == null) return;
  if (choice is ClaudeAppSession) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ClaudeAppSessionScreen(session: choice),
      ),
    );
  } else {
    openNexusChat(cwd);
  }
}

/// Pops with `'nexus'` for a Nexus chat, or with the started
/// [ClaudeAppSession].
class NewChatChoiceSheet extends ConsumerStatefulWidget {
  const NewChatChoiceSheet({super.key, required this.cwd});
  final String cwd;
  @override
  ConsumerState<NewChatChoiceSheet> createState() => _NewChatChoiceSheetState();
}

class _NewChatChoiceSheetState extends ConsumerState<NewChatChoiceSheet> {
  late final TextEditingController _name = TextEditingController(
    text: defaultSessionName(widget.cwd),
  );
  bool _naming = false, _starting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_starting || cleanSessionName(_name.text).isEmpty) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final session = await ref
          .read(claudeAppSessionsProvider.notifier)
          .start(cwd: widget.cwd, name: _name.text);
      if (mounted) Navigator.pop(context, session);
    } catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = 'Could not start it: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final windows = isWindowsHostPath(widget.cwd);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(NX.pad, 8, NX.pad, NX.pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _naming ? 'Start for Claude app' : 'New chat',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                const Icon(Icons.folder_outlined, size: 16, color: NX.textDim),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.cwd,
                    key: const ValueKey('new-chat-folder'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: NX.textDim, fontSize: 12.5),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (!_naming) ...[
              _Option(
                key: const ValueKey('choice-nexus-chat'),
                icon: Icons.chat_bubble_outline,
                title: 'Chat here in Nexus',
                subtitle: 'Chat with a code agent in this app.',
                onTap: () => Navigator.pop(context, 'nexus'),
              ),
              const SizedBox(height: 10),
              _Option(
                key: const ValueKey('choice-claude-app'),
                icon: Icons.open_in_new,
                title: 'Start for Claude app',
                subtitle: windows
                    ? 'Needs a Linux or macOS PC.'
                    : 'Runs Claude Code on your PC in this folder so you can '
                          'follow it in the Claude app; it ends if the PC '
                          'host restarts.',
                onTap: windows ? null : () => setState(() => _naming = true),
              ),
            ] else ...[
              TextField(
                key: const ValueKey('claude-app-name'),
                controller: _name,
                enabled: !_starting,
                maxLength: maxSessionNameLength,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _start(),
                decoration: const InputDecoration(
                  labelText: 'Session name',
                  helperText: 'Shown in the Claude app.',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: NX.failed)),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _starting
                          ? null
                          : () => setState(() => _naming = false),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      child: const Text('Back'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('start-claude-app'),
                      onPressed:
                          _starting || cleanSessionName(_name.text).isEmpty
                          ? null
                          : _start,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      child: _starting
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Start'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: NX.surface2,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(NX.radiusSm),
      side: BorderSide(color: NX.line.withValues(alpha: .7)),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              Icon(icon, color: onTap == null ? NX.textFaint : NX.accent),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                        color: onTap == null ? NX.textFaint : NX.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(fontSize: 12.5, color: NX.textDim),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: NX.textFaint),
            ],
          ),
        ),
      ),
    ),
  );
}
