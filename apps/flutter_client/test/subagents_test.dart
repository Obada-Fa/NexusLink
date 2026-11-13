import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/agents/subagents.dart';
import 'package:nexuslink/src/rpc/models.dart';
import 'package:nexuslink/src/state/agent_history.dart';

/// Real sequences from docs/AGENT-SUBAGENT-EVENTS.md section 8, with seqs.
List<AgentEvent> seqd(List<Map<String, dynamic>> rows, {int from = 1}) => [
  for (var i = 0; i < rows.length; i++)
    AgentEvent.fromJson({'seq': from + i, 'ts': 1000 + from + i, ...rows[i]}),
];

const bgId = 'a3a31c1d935e8cfce';
const bgRef = 'toolu_012416RzUmsDV49c6yR436sj';
const bgRecord = {
  'agentId': bgId,
  'refId': bgRef,
  'agentName': 'Run delayed echo command',
  'agentType': 'general-purpose',
  'agentDepth': 1,
  'agentBackground': true,
};

/// 8.1 Background agent with a second round.
final background = <Map<String, dynamic>>[
  {'kind': 'user', 'text': 'Use the Agent tool exactly once ...'},
  {'kind': 'status', 'text': 'ready'},
  {'kind': 'thinking', 'text': ''},
  {
    'kind': 'tool-start',
    'toolName': 'Agent',
    'refId': bgRef,
    'toolInput': '{ "description": "Run delayed echo command" }',
  },
  {
    'kind': 'agent-start',
    ...bgRecord,
    'agentStatus': 'running',
    'agentPrompt': 'Run the shell command: sleep 5 && echo e2e-done ...',
  },
  {
    'kind': 'tool-end',
    'refId': bgRef,
    'toolOutput': 'Async agent launched successfully.',
  },
  {'kind': 'thinking', 'text': ''},
  {'kind': 'text', 'text': 'launched'},
  {
    'kind': 'tool-start',
    'toolName': 'Bash',
    'refId': 'toolu_01Qfp5qnPmHA4A7Qw5c7mu7H',
    'agentId': bgId,
    'toolInput': '{ "command": "sleep 5 && echo e2e-done" }',
  },
  {
    'kind': 'agent-update',
    ...bgRecord,
    'agentStatus': 'running',
    'text': 'Running Sleep 5 seconds then echo marker',
    'toolName': 'Bash',
  },
  {'kind': 'result', 'text': ''},
  // busy=false, runningAgents=1 from here.
  {
    'kind': 'tool-end',
    'refId': 'toolu_01Qfp5qnPmHA4A7Qw5c7mu7H',
    'agentId': bgId,
    'toolOutput': 'e2e-done',
  },
  {'kind': 'text', 'text': 'finished', 'agentId': bgId},
  {
    'kind': 'agent-end',
    ...bgRecord,
    'agentStatus': 'completed',
    'text': 'finished',
  },
  {'kind': 'status', 'text': 'ready'},
  {
    'kind': 'text',
    'text': 'The background agent finished; it ran `sleep 5 && echo e2e-done`.',
  },
  {'kind': 'result', 'text': ''},
];

const fgId = 'a981023569ae6ebcf';
const fgRef = 'toolu_017FWpGsGfNFM2DJV8N95h3S';
const fgRecord = {
  'agentId': fgId,
  'refId': fgRef,
  'agentName': 'Reply with pong',
  'agentType': 'general-purpose',
  'agentDepth': 1,
  'agentBackground': false,
};

/// 8.2 Foreground agent.
final foreground = <Map<String, dynamic>>[
  {'kind': 'user', 'text': 'spawn one agent'},
  {'kind': 'status', 'text': 'ready'},
  {'kind': 'tool-start', 'toolName': 'Agent', 'refId': fgRef},
  {
    'kind': 'agent-start',
    ...fgRecord,
    'agentStatus': 'running',
    'agentPrompt': 'Reply with exactly the word pong. Do not use any tools.',
  },
  {
    'kind': 'agent-end',
    ...fgRecord,
    'agentStatus': 'completed',
    'text': 'pong',
  },
  {
    'kind': 'tool-end',
    'refId': fgRef,
    'toolOutput': '[Subagent hand-back] ... pong ...',
  },
  {'kind': 'text', 'text': 'Subagent replied "pong", so it said: "pong".'},
  {'kind': 'result', 'text': ''},
];

const outerId = 'a5e3038f0d177146a';
const outerRef = 'toolu_01X9nYFTft2MJ5vTd6A7Rn4Z';
const innerId = 'a9462576fd733b1e6';
const innerRef = 'toolu_013MBeHPxxAyXR2uRGHSdHT5';
const outer = {
  'agentId': outerId,
  'refId': outerRef,
  'agentName': 'Nested sub-agent test',
  'agentType': 'general-purpose',
  'agentDepth': 1,
  'agentBackground': false,
};
const inner = {
  'agentId': innerId,
  'refId': innerRef,
  'agentName': 'Run python one-liner',
  'agentType': 'general-purpose',
  'agentDepth': 2,
  'agentParentId': outerId,
  'agentBackground': false,
};

/// 8.3 Nested agents with a depth-2 permission request.
final nested = <Map<String, dynamic>>[
  {'kind': 'user', 'text': 'nest'},
  {'kind': 'tool-start', 'toolName': 'Agent', 'refId': outerRef},
  {
    'kind': 'agent-start',
    ...outer,
    'agentStatus': 'running',
    'agentPrompt': 'Use the Agent tool yourself once ...',
  },
  {
    'kind': 'agent-update',
    ...outer,
    'agentStatus': 'running',
    'text': 'Run python one-liner',
    'toolName': 'Agent',
  },
  {
    'kind': 'tool-start',
    'toolName': 'Agent',
    'refId': innerRef,
    'agentId': outerId,
  },
  {
    'kind': 'agent-start',
    ...inner,
    'agentStatus': 'running',
    'agentPrompt': 'Run the shell command  python3 -c "print(6*7)" ...',
  },
  {
    'kind': 'agent-update',
    ...inner,
    'agentStatus': 'running',
    'text': 'Running Run python command printing 6*7',
    'toolName': 'Bash',
  },
  {
    'kind': 'permission-request',
    'refId': '237436a0-0e7c-46c9-abec-6aedd49d8fe5',
    'toolName': 'Bash',
    'agentId': innerId,
    'text': 'Allow Bash?',
  },
  {'kind': 'agent-end', ...inner, 'agentStatus': 'completed', 'text': '42'},
  {
    'kind': 'tool-end',
    'refId': innerRef,
    'agentId': outerId,
    'toolOutput': '...',
  },
  {'kind': 'agent-end', ...outer, 'agentStatus': 'completed', 'text': '42'},
  {'kind': 'tool-end', 'refId': outerRef, 'toolOutput': '...'},
  {'kind': 'text', 'text': 'The nested sub-agent returned 42.'},
];

void main() {
  group('event fields', () {
    test('agentId and record fields parse; main events have none', () {
      final events = seqd(nested);
      final start = events[5];
      expect(start.kind, 'agent-start');
      expect(start.agentId, innerId);
      expect(start.agentDepth, 2);
      expect(start.agentParentId, outerId);
      expect(start.agentBackground, isFalse);
      expect(start.agentStatus, 'running');
      expect(start.agentPrompt, contains('python3'));
      expect(start.isAgentRecord, isTrue);
      expect(events.last.agentId, isNull);
    });

    test('copyWith and history renumbering keep sub-agent fields', () {
      final e = seqd(nested)[5];
      final copy = e.copyWith(seq: 99);
      expect(copy.seq, 99);
      expect(copy.agentId, innerId);
      expect(copy.agentParentId, outerId);
      // normalizeTranscriptSeqs renumbers duplicates through copyWith.
      final renumbered = normalizeTranscriptSeqs([e, e]);
      expect(renumbered.map((x) => x.agentId), [innerId, innerId]);
    });

    test('session runningAgents and per-model thinking levels parse', () {
      final s = AgentSessionInfo.fromJson({
        'agentSessionId': 's',
        'busy': false,
        'runningAgents': 2,
      });
      expect(s.runningAgents, 2);
      expect(s.copyWith(busy: true).runningAgents, 2);
      expect(
        AgentSessionInfo.fromJson({'agentSessionId': 's'}).runningAgents,
        0,
      );
      final m = AgentModelOption.fromJson({
        'id': 'sonnet',
        'thinkingLevels': ['low', 'medium', 'high', 'ultracode'],
      });
      expect(m.thinkingLevels, contains('ultracode'));
      expect(
        collapseModelFamilies([m]).single.thinkingLevels,
        contains('ultracode'),
      );
      expect(AgentModelOption.fromJson({'id': 'opus'}).thinkingLevels, isNull);
    });

    test('Ultra Code falls back to the highest ordinary level', () {
      expect(fallbackThinking('ultracode', ['low', 'medium', 'high']), 'high');
      expect(
        fallbackThinking('ultracode', ['low', 'medium', 'high', 'ultracode']),
        'ultracode',
      );
      expect(
        fallbackThinking('ultracode', ['low', 'medium', 'high', 'max']),
        'max',
      );
      expect(fallbackThinking('minimal', ['low', 'medium', 'high']), 'medium');
      expect(fallbackThinking('high', const []), 'high');
    });
  });

  group('background agent (8.1)', () {
    final events = seqd(background);

    test('runs past the spawn tool-end and the first result', () {
      // Up to and including the first result.
      final atResult = buildSubagents(events.take(11));
      final a = atResult[bgId]!;
      expect(a.running, isTrue);
      expect(a.background, isTrue);
      expect(a.label, 'Run delayed echo command');
      expect(a.progress, 'Running Sleep 5 seconds then echo marker');
      expect(a.lastTool, 'Bash');
      expect(a.activity, 'Running Sleep 5 seconds then echo marker');
      expect(a.prompt, contains('sleep 5'));
      expect(atResult.runningCount, 1);
      expect(atResult.bySpawnRef(bgRef)?.id, bgId);
    });

    test('ends with its summary and keeps its own steps', () {
      final state = buildSubagents(events);
      final a = state[bgId]!;
      expect(a.status, SubagentStatus.completed);
      expect(a.summary, 'finished');
      expect(a.prompt, contains('sleep 5'), reason: 'kept across updates');
      expect(state.runningCount, 0);
      expect(a.events.map((e) => e.kind), ['tool-start', 'tool-end', 'text']);
      expect(mergeToolEvents(a.events).first.toolOutput, 'e2e-done');
      expect(mergeToolEvents(a.events).first.agentId, bgId);
    });

    test('main timeline drops agent events and keeps both rounds', () {
      final main = mainTimeline(events);
      expect(main.any((e) => e.agentId != null), isFalse);
      expect(main.any((e) => e.isAgentRecord), isFalse);
      expect(main.where((e) => e.kind == 'result'), hasLength(2));
      expect(main.where((e) => e.kind == 'text').map((e) => e.text), [
        'launched',
        startsWith('The background agent finished'),
      ]);
      // The sub-agent's open Bash call never counts as an open main tool.
      expect(transcriptHasOpenTools(events.take(11).toList()), isFalse);
    });

    test('still in the strip in the second round, gone after a new prompt', () {
      final state = buildSubagents(events);
      expect(state.stripAgents().map((a) => a.id), [bgId]);
      final next = buildSubagents([
        ...events,
        AgentEvent(seq: 100, ts: 100, kind: 'user', text: 'next'),
      ]);
      expect(next.stripAgents(), isEmpty);
      expect(next.all, hasLength(1), reason: 'still listed as earlier');
    });
  });

  group('foreground agent (8.2)', () {
    test('ends before the spawn tool-end, record alone is enough', () {
      final events = seqd(foreground);
      final mid = buildSubagents(events.take(4));
      expect(mid[fgId]!.running, isTrue);
      expect(mid[fgId]!.activity, 'Starting…');
      final state = buildSubagents(events);
      final a = state[fgId]!;
      expect(a.status, SubagentStatus.completed);
      expect(a.summary, 'pong');
      expect(a.hasOwnEvents, isFalse);
      expect(a.background, isFalse);
      expect(a.activity, 'pong');
      expect(mainTimeline(events).where((e) => e.kind == 'text'), hasLength(1));
    });
  });

  group('nested agents (8.3)', () {
    final events = seqd(nested);

    test('child records under the parent, permission stays main', () {
      final mid = buildSubagents(events.take(8));
      expect(mid.runningCount, 2);
      expect(mid[innerId]!.depth, 2);
      expect(mid[innerId]!.parentId, outerId);
      expect(mid.childrenOf(outerId).map((a) => a.id), [innerId]);
      expect(mid.stripAgents().map((a) => a.id), [outerId, innerId]);
      // The depth-2 permission request is answerable in the main chat.
      final main = mainTimeline(events.take(8));
      final ask = main.where((e) => e.kind == 'permission-request').single;
      expect(ask.agentId, innerId);
      expect(mid.nameOf(ask.agentId), 'Run python one-liner');
      // ...and also belongs to the agent's own steps.
      expect(mid[innerId]!.events.single.kind, 'permission-request');
      // The parent's own spawn call for the child is in the parent's steps.
      expect(mid[outerId]!.events.single.refId, innerRef);
      expect(mid.bySpawnRef(innerRef)?.id, innerId);
    });

    test('both complete, deepest first', () {
      final state = buildSubagents(events);
      expect(state[innerId]!.summary, '42');
      expect(state[outerId]!.summary, '42');
      expect(state[innerId]!.updatedSeq, lessThan(state[outerId]!.updatedSeq));
      expect(state.runningCount, 0);
    });
  });

  group('replay and restart', () {
    test('host restart replay: the stored stopped end wins', () {
      final events = seqd([
        ...background.take(10),
        {
          'kind': 'tool-end',
          'refId': 'toolu_01Qfp5qnPmHA4A7Qw5c7mu7H',
          'agentId': bgId,
          'toolOutput': 'Interrupted — host restarted.',
        },
        {
          'kind': 'agent-end',
          ...bgRecord,
          'agentStatus': 'stopped',
          'text': 'Interrupted — host restarted.',
        },
      ]);
      final state = buildSubagents(events);
      final a = state[bgId]!;
      expect(a.status, SubagentStatus.stopped);
      expect(a.statusLabel, 'Stopped');
      expect(a.activity, 'Interrupted — host restarted.');
      expect(state.runningCount, 0);
      expect(transcriptHasOpenTools(events), isFalse);
    });

    test('a page that starts after agent-start still yields a record', () {
      final events = seqd(background).skip(9).toList();
      final state = buildSubagents(events);
      expect(state[bgId]!.status, SubagentStatus.completed);
      expect(state[bgId]!.label, 'Run delayed echo command');
    });

    test('a new start for an ended id runs again and keeps old steps', () {
      final events = seqd([
        ...foreground.take(5),
        {'kind': 'text', 'text': 'first', 'agentId': fgId},
        {
          'kind': 'agent-start',
          ...fgRecord,
          'agentStatus': 'running',
          'agentPrompt': 'Again, please.',
        },
        {'kind': 'text', 'text': 'second', 'agentId': fgId},
      ]);
      final state = buildSubagents(events);
      final a = state[fgId]!;
      expect(a.running, isTrue);
      expect(a.runs, 2);
      expect(a.summary, isNull);
      expect(a.prompt, 'Again, please.');
      expect(a.events.map((e) => e.text), ['first', 'second']);
      expect(state.runningCount, 1);
    });
  });

  group('main timeline', () {
    test('a second result repeating the round text is blanked', () {
      final events = seqd([
        {'kind': 'user', 'text': 'go'},
        {'kind': 'text', 'text': 'All done.'},
        {'kind': 'result', 'text': 'All done.'},
        {'kind': 'text', 'text': 'Round two answer.'},
        {'kind': 'result', 'text': 'Round two answer.'},
        {'kind': 'result', 'text': 'Only in the result.'},
      ]);
      final results = mainTimeline(
        events,
      ).where((e) => e.kind == 'result').map((e) => e.text).toList();
      expect(results, ['', '', 'Only in the result.']);
    });

    test('spawn calls split out of tool groups', () {
      final events = seqd([
        {'kind': 'tool-start', 'toolName': 'Read', 'refId': 'r1'},
        {'kind': 'tool-end', 'refId': 'r1'},
        {'kind': 'tool-start', 'toolName': 'Agent', 'refId': fgRef},
        {'kind': 'tool-end', 'refId': fgRef},
        {'kind': 'tool-start', 'toolName': 'Bash', 'refId': 'r2'},
      ]);
      final items = splitSpawnCalls(
        groupAgentDisplay(events),
        (ref) => ref == fgRef,
      );
      expect(items, hasLength(3));
      expect(items[0].tools!.single.refId, 'r1');
      expect(items[1].event!.refId, fgRef);
      expect(items[2].tools!.single.refId, 'r2');
    });
  });
}
