import 'package:flutter/material.dart';

bool chatUsesTurnApproval(String agent) =>
    !['claude', 'codex', 'mock'].contains(agent);

String chatPermissionLabel(String? mode, String agent) => switch (mode) {
  'ask' =>
    chatUsesTurnApproval(agent) ? 'Approve each turn' : 'Ask for approval',
  'full-access' => agent == 'codex' ? 'Full access' : 'Auto-approve',
  _ => 'Using PC settings',
};

/// A choice applies to this agent chat from its next turn onward.
class ChatPermissionSheet extends StatelessWidget {
  const ChatPermissionSheet({
    super.key,
    this.permissionMode,
    this.agentId = 'codex',
  });
  final String? permissionMode;
  final String agentId;

  @override
  Widget build(BuildContext context) => ListView(
    shrinkWrap: true,
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
    children: [
      const ListTile(
        title: Text('Permissions'),
        subtitle: Text('For this chat, starting with your next message.'),
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
          title: Text(chatPermissionLabel(mode, agentId)),
          subtitle: Text(
            mode == 'ask'
                ? chatUsesTurnApproval(agentId)
                      ? 'Before the agent starts, approve the entire turn, including its edits, commands and network use. Individual tools will not ask again during that turn.'
                      : 'Safe actions can run automatically. Other tool requests ask you here in Nexus.'
                : agentId == 'codex'
                ? 'Access your PC and network without sandboxing or approval prompts.'
                : 'Run without Nexus approval prompts. Agent and administrator restrictions still apply.',
          ),
          trailing: permissionMode == mode ? const Icon(Icons.check) : null,
          onTap: () => Navigator.pop(context, mode),
        ),
    ],
  );
}
