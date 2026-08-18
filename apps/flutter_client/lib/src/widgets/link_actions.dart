// Blue markdown links (URLs, IPs) on the phone: tap or long-press to copy
// or share. Bare IPv4 addresses are autolinked so they pick up the same
// treatment as `[text](url)` / `http://…` links.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:share_plus/share_plus.dart';

final ipAutolinkPattern = RegExp(
  r'(?<![\d])(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)(?::\d{1,5})?(?![\d])',
);

String linkActionValue(String text, String? href) {
  final h = href?.trim() ?? '';
  if (h.isNotEmpty) return h;
  return text.trim();
}

class IpAutolinkSyntax extends md.InlineSyntax {
  IpAutolinkSyntax() : super(ipAutolinkPattern.pattern);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final raw = match[0]!;
    final href = raw.contains('://') ? raw : 'http://$raw';
    final el = md.Element.text('a', raw);
    el.attributes['href'] = href;
    parser.addNode(el);
    return true;
  }
}

class LinkActionBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final text = element.textContent;
    final href = element.attributes['href'] ?? text;
    final style = (preferredStyle ?? parentStyle ?? const TextStyle()).copyWith(
      color: const Color(0xFF93C5FD),
      decoration: TextDecoration.underline,
      decorationColor: const Color(0xFF93C5FD),
    );
    return GestureDetector(
      onTap: () => showLinkActions(context, text, href),
      onLongPress: () {
        HapticFeedback.mediumImpact();
        showLinkActions(context, text, href);
      },
      child: Text(text, style: style),
    );
  }
}

Future<void> showLinkActions(
  BuildContext context,
  String text,
  String? href,
) async {
  final value = linkActionValue(text, href);
  if (value.isEmpty) return;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF151522),
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                value,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy'),
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: value));
                if (sheetContext.mounted) Navigator.pop(sheetContext);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied')),
                  );
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Share'),
              onTap: () async {
                if (sheetContext.mounted) Navigator.pop(sheetContext);
                await SharePlus.instance.share(ShareParams(text: value));
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
