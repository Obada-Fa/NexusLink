import 'package:flutter/material.dart';

/// A choice applies to this Codex chat from its next turn onward.
class ChatPermissionSheet extends StatelessWidget {
  const ChatPermissionSheet({super.key, this.permissionMode});
  final String? permissionMode;

  @override
  Widget build(BuildContext context) => ListView(
    shrinkWrap: true,
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
    children: [
      const ListTile(
        title: Text('Permissions'),
        subtitle: Text('For this Codex chat, starting with your next message.'),
      ),
      if (permissionMode == null)
        const ListTile(
          title: Text('Using PC settings'),
          subtitle: Text(
            'Your PC configuration currently controls access and approval prompts.',
          ),
        ),
      for (final mode in ['ask', 'full-access'])
        ListTile(
          leading: Icon(
            mode == 'ask' ? Icons.shield_outlined : Icons.lock_open_outlined,
          ),
          title: Text(mode == 'ask' ? 'Ask for approval' : 'Full access'),
          subtitle: Text(
            mode == 'ask'
                ? 'Work in this project. Safe reads can run automatically; other commands and broader access can ask you first.'
                : 'Access your PC and network without sandboxing or approval prompts.',
          ),
          trailing: permissionMode == mode ? const Icon(Icons.check) : null,
          onTap: () => Navigator.pop(context, mode),
        ),
    ],
  );
}
