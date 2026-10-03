import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import '../rpc/rpc_client.dart';
import 'documents.dart';

Future<void> openEditor(BuildContext context, String path, {int? line}) =>
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditorScreen(path: path, line: line),
      ),
    );

class EditorScreen extends ConsumerStatefulWidget {
  final String path;
  final int? line;
  const EditorScreen({super.key, required this.path, this.line});
  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen>
    with WidgetsBindingObserver {
  RemoteDocument? _document;
  String? _error;
  bool _wrap = false, _preview = false, _find = false, _leaving = false;
  double _fontSize = 14;
  CodeFindController? _finder;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  Future<void> _open() async {
    try {
      final doc = await ref.read(documentRepositoryProvider).open(widget.path);
      if (!mounted) return;
      setState(() {
        _document = doc;
        _finder = CodeFindController(doc.controller);
      });
      if (widget.line != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _goTo(widget.line!);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _document?.persist();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _document?.persist();
    _finder?.dispose();
    super.dispose();
  }

  void _goTo(int line) {
    final c = _document!.controller;
    final index = (line - 1).clamp(0, c.codeLines.length - 1);
    c.selection = CodeLineSelection.collapsed(index: index, offset: 0);
    c.makeCursorCenterIfInvisible();
  }

  Future<String?> _input(String title, {String initial = ''}) async {
    var value = initial;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          onChanged: (text) => value = text,
          onFieldSubmitted: (_) => Navigator.pop(ctx, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, value),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    try {
      await _document!.save();
    } on RpcException catch (e) {
      if (e.code == 'REVISION_CONFLICT' && mounted) {
        await _conflict();
      } else if (mounted)
        _toast('$e');
    } catch (e) {
      if (mounted) _toast('$e');
    }
  }

  void _toast(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  Future<void> _conflict() async {
    final doc = _document!;
    final latest = await doc.latest();
    if (!mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('File changed on the PC'),
        content: const Text(
          'Your edits are safe. Compare before replacing the PC version.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'compare'),
            child: const Text('Compare'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'reload'),
            child: const Text('Reload PC'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'saveas'),
            child: const Text('Save as'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Keep editing'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'reload') {
      await doc.reload();
      return;
    }
    if (choice == 'saveas') {
      final path = await _input(
        'Save as: absolute PC path',
        initial: '${doc.path}.copy',
      );
      if (path != null) await doc.save(asPath: path);
      return;
    }
    if (choice == 'compare') {
      final replace = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (ctx) => DefaultTabController(
            length: 2,
            child: Scaffold(
              appBar: AppBar(
                title: const Text('Compare versions'),
                bottom: const TabBar(
                  tabs: [
                    Tab(text: 'Your edits'),
                    Tab(text: 'PC version'),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Replace PC'),
                  ),
                ],
              ),
              body: TabBarView(
                children: [
                  for (final text in [
                    doc.controller.text,
                    latest['content'] as String,
                  ])
                    SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        text,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      if (replace == true) {
        try {
          await doc.save(replacementRevision: latest['revision'] as String);
        } catch (e) {
          if (mounted) _toast('$e');
        }
      }
    }
  }

  Future<void> _leave() async {
    final doc = _document;
    if (doc == null || !doc.dirty) {
      setState(() => _leaving = true);
      Navigator.pop(context);
      return;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unsaved edits'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('Save'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'keep'),
            child: const Text('Keep draft'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (choice == null) return;
    if (choice == 'save') {
      await _save();
      if (doc.dirty) return;
    }
    if (choice == 'discard') {
      await doc.discard();
    } else {
      await doc.persist();
    }
    if (mounted) {
      setState(() => _leaving = true);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = _document;
    if (doc == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Editor')),
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : Text(_error!),
        ),
      );
    }
    return AnimatedBuilder(
      animation: doc,
      builder: (context, _) => PopScope(
        canPop: _leaving || !doc.dirty,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _leave();
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text('${doc.dirty ? '• ' : ''}${doc.path.split('/').last}'),
            actions: [
              IconButton(
                tooltip: 'Open documents',
                icon: const Icon(Icons.tab),
                onPressed: () async {
                  final docs = ref
                      .read(documentRepositoryProvider)
                      .documents
                      .values
                      .where((d) => d.host == doc.host);
                  final path = await showModalBottomSheet<String>(
                    context: context,
                    builder: (ctx) => ListView(
                      shrinkWrap: true,
                      children: [
                        for (final d in docs)
                          ListTile(
                            title: Text('${d.dirty ? '• ' : ''}${d.path}'),
                            onTap: () => Navigator.pop(ctx, d.path),
                          ),
                      ],
                    ),
                  );
                  if (path != null && context.mounted) {
                    openEditor(context, path);
                  }
                },
              ),
              IconButton(
                tooltip: 'Save to PC',
                onPressed: doc.writable && doc.dirty && !doc.saving
                    ? _save
                    : null,
                icon: doc.saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(),
                      )
                    : const Icon(Icons.save_outlined),
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Text(
                  doc.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              if (!doc.writable)
                ListTile(
                  title: Text(doc.data['readOnlyReason'] ?? 'Read only'),
                  trailing: doc.data['requestedPath'] != doc.path
                      ? TextButton(
                          onPressed: () => openEditor(context, doc.path),
                          child: const Text('Open target'),
                        )
                      : null,
                ),
              if (doc.restored)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    'Recovered unsaved draft. Save checks the PC version.',
                  ),
                ),
              if (doc.error != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    doc.error!,
                    style: const TextStyle(color: Colors.amber),
                  ),
                ),
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    IconButton(
                      tooltip: 'Undo',
                      onPressed: doc.writable ? doc.controller.undo : null,
                      icon: const Icon(Icons.undo),
                    ),
                    IconButton(
                      tooltip: 'Redo',
                      onPressed: doc.writable ? doc.controller.redo : null,
                      icon: const Icon(Icons.redo),
                    ),
                    IconButton(
                      tooltip: 'Find / replace',
                      onPressed: () => setState(() {
                        _find = !_find;
                        if (_find) {
                          _finder!.findMode();
                        } else {
                          _finder!.close();
                        }
                      }),
                      icon: const Icon(Icons.search),
                    ),
                    IconButton(
                      tooltip: 'Go to line',
                      onPressed: () async {
                        final text = await _input('Line number');
                        final line = int.tryParse(text ?? '');
                        if (line != null) _goTo(line);
                      },
                      icon: const Icon(Icons.format_list_numbered),
                    ),
                    IconButton(
                      tooltip: 'Wrap lines',
                      onPressed: () => setState(() => _wrap = !_wrap),
                      icon: Icon(
                        Icons.wrap_text,
                        color: _wrap ? Colors.blue : null,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Font size',
                      onPressed: () => setState(
                        () => _fontSize = _fontSize >= 22 ? 12 : _fontSize + 1,
                      ),
                      icon: const Icon(Icons.text_fields),
                    ),
                    IconButton(
                      tooltip: 'Indent',
                      onPressed: doc.writable
                          ? doc.controller.applyIndent
                          : null,
                      icon: const Icon(Icons.format_indent_increase),
                    ),
                    IconButton(
                      tooltip: 'Unindent',
                      onPressed: doc.writable
                          ? doc.controller.applyOutdent
                          : null,
                      icon: const Icon(Icons.format_indent_decrease),
                    ),
                    if (doc.path.endsWith('.md'))
                      IconButton(
                        tooltip: 'Markdown preview',
                        onPressed: () => setState(() => _preview = !_preview),
                        icon: const Icon(Icons.preview),
                      ),
                  ],
                ),
              ),
              if (_find)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _finder!.findInputController,
                              decoration: const InputDecoration(
                                hintText: 'Find',
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: _finder!.previousMatch,
                            icon: const Icon(Icons.arrow_upward),
                          ),
                          IconButton(
                            onPressed: _finder!.nextMatch,
                            icon: const Icon(Icons.arrow_downward),
                          ),
                        ],
                      ),
                      if (doc.writable)
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _finder!.replaceInputController,
                                decoration: const InputDecoration(
                                  hintText: 'Replace',
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: _finder!.replaceMatch,
                              child: const Text('Replace'),
                            ),
                            TextButton(
                              onPressed: _finder!.replaceAllMatches,
                              child: const Text('All'),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              Expanded(
                child: _preview
                    ? Markdown(data: doc.controller.text, selectable: true)
                    : CodeEditor(
                        controller: doc.controller,
                        findController: _finder,
                        readOnly: !doc.writable,
                        wordWrap: _wrap,
                        style: CodeEditorStyle(
                          fontFamily: 'monospace',
                          fontSize: _fontSize,
                          backgroundColor: const Color(0xFF0B0D12),
                          textColor: const Color(0xFFF2F4F8),
                          codeTheme: _theme(doc.path),
                        ),
                        indicatorBuilder: (context, editing, chunk, notifier) =>
                            DefaultCodeLineNumber(
                              controller: editing,
                              notifier: notifier,
                            ),
                        toolbarController: MobileSelectionToolbarController(
                          builder:
                              ({
                                required context,
                                required anchors,
                                required controller,
                                required onDismiss,
                                required onRefresh,
                              }) => AdaptiveTextSelectionToolbar.buttonItems(
                                anchors: anchors,
                                buttonItems: [
                                  ContextMenuButtonItem(
                                    label: 'Copy',
                                    onPressed: () {
                                      controller.copy();
                                      onDismiss();
                                    },
                                  ),
                                  if (doc.writable) ...[
                                    ContextMenuButtonItem(
                                      label: 'Cut',
                                      onPressed: () {
                                        controller.cut();
                                        onDismiss();
                                      },
                                    ),
                                    ContextMenuButtonItem(
                                      label: 'Paste',
                                      onPressed: () {
                                        controller.paste();
                                        onDismiss();
                                      },
                                    ),
                                  ],
                                  ContextMenuButtonItem(
                                    label: 'Select all',
                                    onPressed: () {
                                      controller.selectAll();
                                      onRefresh();
                                    },
                                  ),
                                ],
                              ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  CodeHighlightTheme? _theme(String path) {
    final ext = path.split('.').last;
    final mode = switch (ext) {
      'dart' => langDart,
      'ts' || 'tsx' || 'js' || 'jsx' => langTypescript,
      'py' => langPython,
      'json' => langJson,
      'sh' => langBash,
      _ => null,
    };
    return mode == null
        ? null
        : CodeHighlightTheme(
            languages: {ext: CodeHighlightThemeMode(mode: mode)},
            theme: atomOneDarkTheme,
          );
  }
}
