import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/widgets/agent_activity_icon.dart';

void main() {
  testWidgets('AgentActivityIcon shows agent icon', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AgentActivityIcon(agentId: 'antigravity'),
        ),
      ),
    );
    expect(find.byType(AgentMark), findsOneWidget);
  });

  testWidgets('AgentActivityIcon animates when active', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AgentActivityIcon(agentId: 'cursor', active: true),
        ),
      ),
    );
    expect(find.byType(AgentMark), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));
  });

  testWidgets('AgentActivityIcon shows Cursor logo', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AgentActivityIcon(agentId: 'cursor'),
        ),
      ),
    );
    expect(find.byType(AgentMark), findsOneWidget);
    expect(find.byIcon(Icons.code), findsNothing);
  });

  test('hasOfficialAgentLogo is true for official coding agents', () {
    expect(hasOfficialAgentLogo('cursor'), isTrue);
    expect(hasOfficialAgentLogo('antigravity'), isTrue);
    expect(hasOfficialAgentLogo('claude'), isTrue);
    expect(hasOfficialAgentLogo('opencode'), isTrue);
    expect(hasOfficialAgentLogo('future-bot'), isFalse);
  });

  testWidgets('AgentMark renders raster image when data URI is provided',
      (tester) async {
    const pngDataUri =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AgentMark(agentId: 'antigravity', icon: pngDataUri),
        ),
      ),
    );
    expect(find.byType(Image), findsOneWidget);
  });

  test('iconForAgent does not use rocket icon for antigravity', () {
    expect(iconForAgent('antigravity'), isNot(Icons.rocket_launch_outlined));
  });

  test('chatListSubtitle matches Cursor-style source · folder', () {
    expect(chatListSubtitle(agent: 'opencode', cwd: '/tmp/proj'),
        'OpenCode · /tmp/proj');
    expect(
      chatListSubtitle(agent: 'claude', cwd: '/home/me', resumable: false),
      'Claude Code · /home/me · view only',
    );
    expect(agentSourceLabel('future-bot'), 'Future Bot');
  });
}
