import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/rpc/models.dart';
import 'package:nexuslink/src/state/agent_history.dart';

AgentEvent ev(int seq, String text, {String kind = 'text'}) => AgentEvent(
      seq: seq,
      ts: seq,
      kind: kind,
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

    test('keeps live events missing from a gapped host snapshot', () {
      final history = [ev(1, 'user'), ev(30, 'placeholder')];
      final live = [
        ev(1, 'user'),
        ev(25, 'part'),
        ev(26, 'ial'),
        ev(27, ' reply'),
      ];
      final merged = mergeAgentHistory(history, live);
      expect(merged.map((e) => e.seq).toList(), [1, 25, 26, 27, 30]);
      expect(merged.where((e) => e.seq == 25).single.text, 'part');
    });

    test('adds live-only seqs not present in the host snapshot', () {
      final history = [ev(1, 'user'), ev(2, 'done')];
      final live = [ev(1, 'user'), ev(2, 'done'), ev(3, 'still streaming')];
      final merged = mergeAgentHistory(history, live);
      expect(merged.map((e) => e.seq).toList(), [1, 2, 3]);
      expect(merged.last.text, 'still streaming');
    });
  });

  group('normalizeTranscriptSeqs', () {
    test('renumbers duplicate zero seq rows instead of collapsing them', () {
      final raw = [
        ev(0, 'user'),
        ev(0, 'assistant'),
      ];
      final out = normalizeTranscriptSeqs(raw);
      expect(out.map((e) => e.text).toList(), ['user', 'assistant']);
      expect(out.map((e) => e.seq).toList(), [1, 2]);
    });
  });

  group('applyAgentHistorySnapshot', () {
    test('never replaces a rendered transcript with an empty snapshot', () {
      final current = [ev(1, 'hello'), ev(2, 'world')];
      expect(
        applyAgentHistorySnapshot(const [], current, busy: false),
        current,
      );
    });

    test('does not shrink an in-flight transcript', () {
      final current = [ev(1, 'a'), ev(2, 'b'), ev(3, 'live')];
      expect(
        applyAgentHistorySnapshot(const [], current, busy: true),
        current,
      );
    });
  });
}
