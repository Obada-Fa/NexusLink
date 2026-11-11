// Sub-agent UI for the chat: the compact agents strip above the composer,
// the card that replaces an `Agent` spawn call in a timeline, and the agent
// view sheet. Colours and shapes follow the chat's tool cards and the NX
// palette; dark theme first.

import 'package:flutter/material.dart';

import '../rpc/models.dart';
import '../theme/nexus_theme.dart';
import '../theme/nx_widgets.dart';
import 'subagents.dart';

const _panel = Color(0xFF141821);
const _surface = Color(0xFF0B0D12);

Color subagentStatusColor(SubagentStatus s) => switch (s) {
  SubagentStatus.running => NX.working,
  SubagentStatus.completed => NX.done,
  SubagentStatus.failed => NX.failed,
  SubagentStatus.stopped => NX.idle,
};

Duration _motion(BuildContext context, int ms) =>
    (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
    ? Duration.zero
    : Duration(milliseconds: ms);

/// Status glyph whose shape differs per state (pulsing dot, check, cross,
/// stop square), so the state reads without colour.
class SubagentStatusIcon extends StatelessWidget {
  const SubagentStatusIcon(this.status, {super.key, this.size = 16});
  final SubagentStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = subagentStatusColor(status);
    final Widget glyph = switch (status) {
      SubagentStatus.running => LiveDot(color: color, size: size * .5),
      SubagentStatus.completed => Icon(
        Icons.check_circle,
        size: size,
        color: color,
      ),
      SubagentStatus.failed => Icon(Icons.cancel, size: size, color: color),
      SubagentStatus.stopped => Icon(
        Icons.stop_circle_outlined,
        size: size,
        color: color,
      ),
    };
    return SizedBox.square(
      dimension: size * 1.15,
      child: AnimatedSwitcher(
        duration: _motion(context, 220),
        child: KeyedSubtree(
          key: ValueKey(status),
          child: Center(child: glyph),
        ),
      ),
    );
  }
}

String agentsCountLabel(int n) => n == 1 ? '1 agent' : '$n agents';

/// The compact "agents" strip. Shown only while the chat has sub-agents in
/// the current turn or still running ([SubagentState.stripAgents]).
class SubagentStrip extends StatelessWidget {
  const SubagentStrip({
    super.key,
    required this.agents,
    required this.runningCount,
    required this.onOpen,
    required this.onShowAll,
  });

  /// Strip order: running roots first, each followed by its descendants.
  final List<SubagentRecord> agents;

  /// Running sub-agents of the whole chat (host count or local, whichever is
  /// larger).
  final int runningCount;
  final void Function(String agentId) onOpen;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    if (agents.isEmpty && runningCount == 0) return const SizedBox.shrink();
    final running = runningCount;
    final total = agents.length > running ? agents.length : running;
    final summary = running > 0
        ? '${agentsCountLabel(running)} running'
        : '${agentsCountLabel(total)} · done';
    return Padding(
      key: const ValueKey('subagent-strip'),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Semantics(
            button: true,
            label: '$summary. Show all agents',
            excludeSemantics: true,
            child: _SummaryButton(
              count: running > 0 ? running : total,
              caption: running > 0 ? 'running' : 'done',
              live: running > 0,
              onTap: onShowAll,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            // Soft edges say "more this way" without a scrollbar.
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => const LinearGradient(
                colors: [
                  Colors.transparent,
                  Colors.black,
                  Colors.black,
                  Colors.transparent,
                ],
                stops: [0, .03, .93, 1],
              ).createShader(rect),
              child: SingleChildScrollView(
                key: const ValueKey('subagent-strip-scroll'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(left: 4, right: 20),
                child: Row(
                  children: [
                    for (var i = 0; i < agents.length; i++) ...[
                      if (i > 0) const SizedBox(width: 6),
                      SubagentChip(
                        key: ValueKey('subagent-chip-${agents[i].id}'),
                        agent: agents[i],
                        nested:
                            agents[i].parentId != null &&
                            agents.any((a) => a.id == agents[i].parentId),
                        onTap: () => onOpen(agents[i].id),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryButton extends StatelessWidget {
  const _SummaryButton({
    required this.count,
    required this.caption,
    required this.live,
    required this.onTap,
  });
  final int count;
  final String caption;
  final bool live;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _panel,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: const ValueKey('subagent-strip-all'),
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: NX.line.withValues(alpha: .8)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.account_tree_outlined,
                    size: 14,
                    color: live ? NX.working : NX.textDim,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '$count',
                    style: const TextStyle(
                      color: NX.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      fontFeatures: NX.tabular,
                    ),
                  ),
                ],
              ),
              Text(
                caption,
                style: const TextStyle(color: NX.textDim, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One agent in the strip: state glyph, name, and the latest progress line
/// (running) or the outcome word (ended).
class SubagentChip extends StatelessWidget {
  const SubagentChip({
    super.key,
    required this.agent,
    required this.onTap,
    this.nested = false,
  });
  final SubagentRecord agent;
  final VoidCallback onTap;
  final bool nested;

  @override
  Widget build(BuildContext context) {
    final color = subagentStatusColor(agent.status);
    final second = agent.running ? agent.activity : agent.statusLabel;
    return Semantics(
      button: true,
      label:
          '${agent.label}, ${agent.statusLabel}'
          '${agent.running ? ', ${agent.activity}' : ''}'
          '${nested ? ', started by another agent' : ''}',
      excludeSemantics: true,
      child: Material(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: AnimatedContainer(
            duration: _motion(context, 250),
            constraints: const BoxConstraints(
              minHeight: 48,
              minWidth: 96,
              maxWidth: 200,
            ),
            padding: const EdgeInsets.fromLTRB(8, 5, 10, 5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: agent.status == SubagentStatus.completed
                    ? NX.line.withValues(alpha: .8)
                    : color.withValues(alpha: .45),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (nested)
                  const Padding(
                    padding: EdgeInsets.only(right: 2),
                    child: Icon(
                      Icons.subdirectory_arrow_right,
                      size: 14,
                      color: NX.textFaint,
                    ),
                  ),
                SubagentStatusIcon(agent.status, size: 15),
                const SizedBox(width: 6),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        agent.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: NX.text,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 1),
                      AnimatedSwitcher(
                        duration: _motion(context, 200),
                        child: Text(
                          second,
                          key: ValueKey(second),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: agent.running ? NX.textDim : color,
                            fontSize: 11,
                            fontWeight: agent.running
                                ? FontWeight.w400
                                : FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Replaces the `Agent` tool card in a timeline: the agent's real state
/// (running until its `agent-end`, not until the call's `tool-end`), tap to
/// open the agent.
class SubagentSpawnCard extends StatelessWidget {
  const SubagentSpawnCard({
    super.key,
    required this.agent,
    required this.onTap,
    this.borderColor = const Color(0xFF243047),
  });
  final SubagentRecord agent;
  final VoidCallback onTap;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    final color = subagentStatusColor(agent.status);
    final kind = [
      'Agent',
      if ((agent.type ?? '').isNotEmpty) agent.type!,
      if (agent.background) 'background',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: _panel,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          key: ValueKey('subagent-card-${agent.id}'),
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: AnimatedContainer(
            duration: _motion(context, 250),
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: agent.running
                    ? color.withValues(alpha: .45)
                    : borderColor,
              ),
            ),
            child: Row(
              children: [
                SubagentStatusIcon(agent.status, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        kind,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: NX.textFaint,
                          fontSize: 11,
                        ),
                      ),
                      Text(
                        agent.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        agent.activity,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                NxPill(
                  agent.statusLabel,
                  color: color,
                  dense: true,
                  icon: agent.running ? null : _statusIcon(agent.status),
                  live: agent.running,
                ),
                const Icon(Icons.chevron_right, size: 20, color: NX.textFaint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

IconData _statusIcon(SubagentStatus s) => switch (s) {
  SubagentStatus.running => Icons.circle,
  SubagentStatus.completed => Icons.check,
  SubagentStatus.failed => Icons.close,
  SubagentStatus.stopped => Icons.stop,
};

/// Which agent the sheet shows; empty means "all agents".
class SubagentSheetController extends ValueNotifier<List<String>> {
  SubagentSheetController([List<String>? stack]) : super(stack ?? const []);
  void push(String id) {
    if (value.isNotEmpty && value.last == id) return;
    value = [...value, id];
  }

  bool pop() {
    if (value.isEmpty) return false;
    value = value.sublist(0, value.length - 1);
    return true;
  }
}

/// The agent view: name, type, status, the task (collapsed), live progress,
/// its streamed steps when there are any, the final summary, and its child
/// agents. Works from `agent-*` records alone. Rebuilds whenever [listenable]
/// fires, so it stays live while open.
class SubagentSheet extends StatefulWidget {
  const SubagentSheet({
    super.key,
    required this.controller,
    required this.listenable,
    required this.read,
    required this.eventBuilder,
    required this.textBuilder,
    this.onStopAll,
    this.scrollController,
  });

  final SubagentSheetController controller;
  final Listenable listenable;
  final SubagentState Function() read;

  /// Renders one of the agent's own events (tool card, text, permission,
  /// nested spawn card) with the chat's existing widgets.
  final Widget Function(AgentEvent e) eventBuilder;

  /// Renders markdown text (the final summary) like an agent bubble.
  final Widget Function(String text) textBuilder;

  /// Stops the chat (main agent and every sub-agent); null hides the action.
  final Future<void> Function()? onStopAll;
  final ScrollController? scrollController;

  @override
  State<SubagentSheet> createState() => _SubagentSheetState();
}

class _SubagentSheetState extends State<SubagentSheet> {
  bool _promptOpen = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.listenable, widget.controller]),
      builder: (context, _) {
        final state = widget.read();
        final stack = widget.controller.value;
        final agent = stack.isEmpty ? null : state[stack.last];
        return PopScope(
          canPop: stack.isEmpty,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              setState(() => _promptOpen = false);
              widget.controller.pop();
            }
          },
          child: agent == null
              ? _allAgents(context, state)
              : _agentView(context, state, agent, stack.length > 1),
        );
      },
    );
  }

  Widget _header(
    BuildContext context, {
    required Widget title,
    Widget? leading,
    bool canBack = false,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          if (canBack)
            IconButton(
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back),
              onPressed: () {
                setState(() => _promptOpen = false);
                widget.controller.pop();
              },
            )
          else
            const SizedBox(width: 12),
          if (leading != null) ...[leading, const SizedBox(width: 8)],
          Expanded(child: title),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _allAgents(BuildContext context, SubagentState state) {
    final strip = state.stripAgents();
    final shown = {for (final a in strip) a.id};
    final earlier = state.all.where((a) => !shown.contains(a.id)).toList()
      ..sort((a, b) => b.updatedSeq.compareTo(a.updatedSeq));
    final running = state.runningCount;
    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _header(
          context,
          title: Text(
            running > 0
                ? '${agentsCountLabel(running)} running'
                : 'Agents in this chat',
            style: const TextStyle(
              color: NX.text,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (strip.isEmpty && earlier.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No agents yet.', style: TextStyle(color: NX.textDim)),
          ),
        for (final a in strip) _agentRow(a, indent: _indent(state, a)),
        if (earlier.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'EARLIER',
              style: TextStyle(
                color: NX.textFaint,
                fontSize: 11.5,
                letterSpacing: .6,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final a in earlier) _agentRow(a),
        ],
        if (running > 0 && widget.onStopAll != null) _stopAll(context),
      ],
    );
  }

  int _indent(SubagentState state, SubagentRecord a) {
    var depth = 0;
    var p = state[a.parentId];
    while (p != null && depth < 4) {
      depth++;
      p = state[p.parentId];
    }
    return depth;
  }

  Widget _agentRow(SubagentRecord a, {int indent = 0}) => Padding(
    padding: EdgeInsets.fromLTRB(12.0 + indent * 16, 0, 12, 0),
    child: SubagentSpawnCard(
      agent: a,
      onTap: () => widget.controller.push(a.id),
    ),
  );

  Widget _stopAll(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    child: OutlinedButton.icon(
      key: const ValueKey('subagent-stop-all'),
      style: OutlinedButton.styleFrom(
        foregroundColor: NX.failed,
        side: BorderSide(color: NX.failed.withValues(alpha: .5)),
        minimumSize: const Size.fromHeight(48),
      ),
      onPressed: () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Stop all agents?'),
            content: const Text(
              'This stops the chat on the PC: the main agent and every agent '
              'it started.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep running'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Stop all'),
              ),
            ],
          ),
        );
        if (ok == true) await widget.onStopAll?.call();
      },
      icon: const Icon(Icons.stop),
      label: const Text('Stop all agents'),
    ),
  );

  Widget _section(String title, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: NX.textFaint,
              fontSize: 11.5,
              letterSpacing: .6,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );

  Widget _agentView(
    BuildContext context,
    SubagentState state,
    SubagentRecord agent,
    bool canBack,
  ) {
    final color = subagentStatusColor(agent.status);
    final parent = state[agent.parentId];
    final children = state.childrenOf(agent.id);
    final childIds = {for (final c in children) c.refId};
    // Spawn calls for children render as cards via eventBuilder; children
    // whose spawn call was not streamed (depth ≥ 2 parents stream nothing)
    // are listed separately.
    final ownEvents = mergeToolEvents(agent.events);
    final streamedSpawns = {
      for (final e in ownEvents)
        if (childIds.contains(e.refId)) e.refId,
    };
    final unlistedChildren = [
      for (final c in children)
        if (!streamedSpawns.contains(c.refId)) c,
    ];
    final prompt = (agent.prompt ?? '').trim();
    final summary = (agent.summary ?? '').trim();
    return ListView(
      key: ValueKey('subagent-view-${agent.id}'),
      controller: widget.scrollController,
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _header(
          context,
          canBack: canBack,
          leading: SubagentStatusIcon(agent.status, size: 20),
          title: Text(
            agent.label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: NX.text,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              NxPill(
                agent.statusLabel,
                color: color,
                live: agent.running,
                icon: agent.running ? null : _statusIcon(agent.status),
              ),
              if ((agent.type ?? '').isNotEmpty)
                NxPill(agent.type!, color: NX.textDim),
              if (agent.background)
                const NxPill(
                  'Background',
                  color: NX.accent2,
                  icon: Icons.layers_outlined,
                ),
              if (agent.runs > 1)
                NxPill('Run ${agent.runs}', color: NX.textDim),
            ],
          ),
        ),
        if (parent != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
            child: TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: NX.textDim,
                minimumSize: const Size(48, 48),
                alignment: Alignment.centerLeft,
              ),
              onPressed: () => widget.controller.push(parent.id),
              icon: const Icon(Icons.subdirectory_arrow_left, size: 16),
              label: Text(
                'Started by ${parent.label}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        if (agent.running)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: NxCard(
              accent: NX.working,
              flat: true,
              color: _panel,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: LiveDot(color: NX.working, size: 7),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AnimatedSwitcher(
                          duration: _motion(context, 200),
                          child: Text(
                            agent.activity,
                            key: ValueKey(agent.activity),
                            style: const TextStyle(
                              color: NX.text,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if ((agent.lastTool ?? '').isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              'Last tool: ${agent.lastTool}',
                              style: const TextStyle(
                                color: NX.textDim,
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (prompt.isNotEmpty) ...[
          _section('Task'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _PromptBox(
              prompt: prompt,
              open: _promptOpen,
              onToggle: () => setState(() => _promptOpen = !_promptOpen),
            ),
          ),
        ],
        if (!agent.running) ...[
          _section(switch (agent.status) {
            SubagentStatus.failed => 'Failed',
            SubagentStatus.stopped => 'Stopped',
            _ => 'Result',
          }),
          if (summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: widget.textBuilder(summary),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                agent.status == SubagentStatus.completed
                    ? 'Finished without a summary.'
                    : 'No reason was given.',
                style: const TextStyle(color: NX.textDim, fontSize: 13),
              ),
            ),
        ],
        if (unlistedChildren.isNotEmpty) ...[
          _section('Agents it started'),
          for (final c in unlistedChildren)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SubagentSpawnCard(
                agent: c,
                onTap: () => widget.controller.push(c.id),
              ),
            ),
        ],
        if (ownEvents.isNotEmpty) ...[
          _section('Steps'),
          for (final e in ownEvents)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: widget.eventBuilder(e),
            ),
        ] else if (agent.running)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text(
              'This agent’s steps are not sent to the phone. Its progress '
              'line above updates as it works.',
              style: TextStyle(color: NX.textFaint, fontSize: 12.5),
            ),
          ),
        if (state.runningCount > 0 && widget.onStopAll != null)
          _stopAll(context),
      ],
    );
  }
}

/// The task prompt: two lines until tapped. Short prompts are shown whole,
/// without an expand control.
class _PromptBox extends StatelessWidget {
  const _PromptBox({
    required this.prompt,
    required this.open,
    required this.onToggle,
  });
  final String prompt;
  final bool open;
  final VoidCallback onToggle;

  static const _style = TextStyle(fontSize: 13, height: 1.35);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          // Measure with the style Text will really use (theme font).
          text: TextSpan(
            text: prompt,
            style: DefaultTextStyle.of(context).style.merge(_style),
          ),
          maxLines: 2,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: (constraints.maxWidth - 48).clamp(0, 2000));
        final long = painter.didExceedMaxLines;
        painter.dispose();
        final box = Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: EdgeInsets.fromLTRB(12, 10, long ? 8 : 12, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: NX.line.withValues(alpha: .7)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: open || !long
                    ? SelectableText(
                        prompt,
                        style: _style.copyWith(color: NX.text),
                      )
                    : Text(
                        prompt,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: _style.copyWith(color: NX.textDim),
                      ),
              ),
              if (long)
                Icon(
                  open ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: NX.textDim,
                  semanticLabel: open ? 'Hide the task' : 'Show the whole task',
                ),
            ],
          ),
        );
        return Material(
          color: _panel,
          borderRadius: BorderRadius.circular(12),
          child: long
              ? InkWell(
                  key: const ValueKey('subagent-prompt'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: onToggle,
                  child: box,
                )
              : KeyedSubtree(
                  key: const ValueKey('subagent-prompt'),
                  child: box,
                ),
        );
      },
    );
  }
}

/// Opens the agent view (or the list of all agents when [agentId] is null)
/// as a draggable bottom sheet.
Future<void> showSubagentSheet({
  required BuildContext context,
  required SubagentSheetController controller,
  required Listenable listenable,
  required SubagentState Function() read,
  required Widget Function(AgentEvent e) eventBuilder,
  required Widget Function(String text) textBuilder,
  Future<void> Function()? onStopAll,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: _surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(NX.radius)),
    ),
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: .8,
      minChildSize: .4,
      maxChildSize: 1,
      builder: (ctx, scroll) => SubagentSheet(
        controller: controller,
        listenable: listenable,
        read: read,
        eventBuilder: eventBuilder,
        textBuilder: textBuilder,
        onStopAll: onStopAll,
        scrollController: scroll,
      ),
    ),
  );
}
