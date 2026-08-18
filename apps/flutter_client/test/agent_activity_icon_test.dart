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
    expect(find.byIcon(Icons.rocket_launch_outlined), findsOneWidget);
  });

  testWidgets('AgentActivityIcon animates when active', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AgentActivityIcon(agentId: 'cursor', active: true),
        ),
      ),
    );
    expect(find.byIcon(Icons.code), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));
  });
}
