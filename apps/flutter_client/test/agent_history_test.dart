import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/rpc/models.dart';
import 'package:nexuslink/src/state/agent_history.dart';

AgentEvent ev(int seq, String text) => AgentEvent(
      seq: seq,
      ts: seq,
      kind: 'text',
      text: text,
    );

void main() {
  group('mergeAgentHistory', () {
    test('keeps live events that arrived after the host snapshot', () {
      final history = [ev(1, 'a'), ev(2, 'b'), ev(3, 'c')];
      final live = [ev(1, 'stale'), ev(3, 'c'), ev(4, 'live')];
      final merged = mergeAgentHistory(history, live);
      expect(merged.map((e) => e.seq).toList(), [1, 2, 3, 4]);
      expect(merged.last.text, 'live');
      expect(merged.first.text, 'a');
    });

    test('replaces an empty snapshot with the live transcript', () {
      final live = [ev(1, 'only')];
      expect(mergeAgentHistory(const [], live).single.text, 'only');
    });
  });
}
