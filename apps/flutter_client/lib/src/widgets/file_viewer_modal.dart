import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../rpc/rpc_client.dart';
import 'code_block_builder.dart';
import 'link_actions.dart';

/// Clean a raw link (e.g. file:///home/... -> /home/...).
String cleanFilePath(String raw) {
  var p = raw.trim();
  if (p.startsWith('file://')) {
    p = Uri.decodeComponent(p.replaceFirst(RegExp(r'^file://'), ''));
  }
  // Strip trailing line hash like #L10-L20
  if (p.contains('#')) {
    p = p.split('#').first;
  }
  return p;
}

bool isPathLike(String value) {
  final v = cleanFilePath(value);
  if (v.startsWith('/') || v.startsWith('~/') || v.startsWith('./')) return true;
  if (RegExp(r'\.(md|markdown|txt|json|dart|ts|js|py|rs|go|yaml|yml|toml|sh|html|css)$', caseSensitive: false).hasMatch(v)) {
    return true;
  }
  return false;
}

Future<void> showFileViewerModal({
  required BuildContext context,
  required RpcClient client,
  String? filePath,
  String? rawContent,
  String? title,
  String? subtitle,
  bool isPlan = false,
}) async {
  final clean = filePath != null && filePath.trim().isNotEmpty ? cleanFilePath(filePath) : '';
  final displayName = title?.isNotEmpty == true
      ? title!
      : (clean.isNotEmpty ? clean.split('/').last : (isPlan ? 'Plan' : 'Document'));

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF11111B),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (modalCtx) {
      return DraggableScrollableSheet(
        initialChildSize: 0.88,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (sheetCtx, scrollController) {
          return _FileViewerContent(
            client: client,
            filePath: clean,
            rawContent: rawContent,
            displayName: displayName,
            subtitle: subtitle,
            isPlan: isPlan,
            scrollController: scrollController,
          );
        },
      );
    },
  );
}

class _FileViewerContent extends StatefulWidget {
  final RpcClient client;
  final String filePath;
  final String? rawContent;
  final String displayName;
  final String? subtitle;
  final bool isPlan;
  final ScrollController scrollController;

  const _FileViewerContent({
    required this.client,
    required this.filePath,
    this.rawContent,
    required this.displayName,
    this.subtitle,
    this.isPlan = false,
    required this.scrollController,
  });

  @override
  State<_FileViewerContent> createState() => _FileViewerContentState();
}

class _FileViewerContentState extends State<_FileViewerContent> {
  String? _content;
  String? _error;
  bool _loading = true;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _loadFile();
  }

  Future<void> _loadFile() async {
    if (widget.filePath.isNotEmpty) {
      setState(() {
        _loading = true;
        _error = null;
      });
      try {
        final res = await widget.client.request('fs.read', {'path': widget.filePath});
        if (!mounted) return;
        setState(() {
          _content = res?.toString() ?? '';
          _loading = false;
        });
        return;
      } catch (e) {
        if (!mounted) return;
        if (widget.rawContent != null && widget.rawContent!.trim().isNotEmpty) {
          setState(() {
            _content = widget.rawContent;
            _loading = false;
            _error = null;
          });
          return;
        }
        setState(() {
          _error = e.toString();
          _loading = false;
        });
        return;
      }
    }

    if (widget.rawContent != null && widget.rawContent!.trim().isNotEmpty) {
      setState(() {
        _content = widget.rawContent;
        _loading = false;
        _error = null;
      });
      return;
    }

    setState(() {
      _content = 'No content available.';
      _loading = false;
    });
  }

  Future<void> _copyContent() async {
    final text = _content;
    if (text == null || text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Content copied to clipboard'),
        duration: Duration(seconds: 1),
      ),
    );
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final displaySubtitle = widget.subtitle?.isNotEmpty == true
        ? widget.subtitle!
        : (widget.filePath.isNotEmpty
            ? widget.filePath
            : (widget.isPlan ? 'Agent Implementation Plan' : ''));

    return Column(
      children: [
        // Drag handle & Header
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFF222233))),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Row(
                children: [
                  Icon(
                    widget.isPlan ? Icons.assignment_outlined : Icons.description_outlined,
                    size: 20,
                    color: widget.isPlan ? const Color(0xFFC084FC) : const Color(0xFF93C5FD),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        if (displaySubtitle.isNotEmpty)
                          Text(
                            displaySubtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF8A8A9A),
                              fontFamily: 'monospace',
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_content != null && _content!.isNotEmpty)
                    IconButton(
                      tooltip: 'Copy all',
                      icon: Icon(
                        _copied ? Icons.check : Icons.copy,
                        size: 18,
                        color: _copied ? Colors.greenAccent : Colors.white70,
                      ),
                      onPressed: _copyContent,
                    ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, size: 20, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Body content
        Expanded(
          child: _buildBody(),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Loading file…', style: TextStyle(color: Colors.white54, fontSize: 13)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 36, color: Color(0xFFEE5555)),
              const SizedBox(height: 12),
              Text(
                'Could not load file',
                style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
              ),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _loadFile,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final content = _content ?? '';
    final isMarkdown = widget.isPlan ||
        widget.filePath.endsWith('.md') ||
        widget.filePath.endsWith('.markdown') ||
        widget.filePath.isEmpty ||
        content.startsWith('#') ||
        content.contains('```') ||
        content.contains('- [ ]') ||
        content.contains('- [x]');

    if (isMarkdown) {
      return SingleChildScrollView(
        controller: widget.scrollController,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: MarkdownBody(
          data: content,
          selectable: true,
          inlineSyntaxes: [IpAutolinkSyntax()],
          builders: {
            'pre': CodeBlockBuilder(),
          },
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
            p: const TextStyle(color: Colors.white, fontSize: 14, height: 1.5),
            h1: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            h2: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
            h3: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
            code: const TextStyle(
              color: Color(0xFF6EE7B7),
              fontFamily: 'monospace',
              fontSize: 12.5,
            ),
            codeblockDecoration: BoxDecoration(
              color: const Color(0xFF1E1E2E),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF2A2A40)),
            ),
            blockquoteDecoration: BoxDecoration(
              color: const Color(0xFF1E1E2E),
              borderRadius: BorderRadius.circular(6),
              border: const Border(left: BorderSide(color: Color(0xFF38BDF8), width: 4)),
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      child: SelectableText(
        content,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12.5,
          color: Colors.white,
          height: 1.4,
        ),
      ),
    );
  }
}
