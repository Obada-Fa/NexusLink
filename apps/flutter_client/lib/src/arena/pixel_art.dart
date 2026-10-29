// Original pixel art for the Arena, drawn in code: palette-indexed sprites for the
// agents and a few pixel helpers for furniture. Sprites are recorded once into
// Pictures (anti-aliasing off) and replayed every frame.

import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import '../chats/chat_models.dart';
import '../theme/nexus_theme.dart';

class Sprite {
  const Sprite(this.name, this.rows);
  final String name;
  final List<String> rows;
  int get width => rows.first.length;
  int get height => rows.length;
}

/// Left halves are mirrored into symmetric 12-pixel rows; full rows pass through.
List<String> _m(List<String> rows) => [
  for (final r in rows) r.length == 6 ? r + r.split('').reversed.join() : r,
];

// Palette keys: o outline, h hair, H hair highlight, s skin, S skin shadow, r blush,
// e eye, c shirt, C shirt shadow, k shirt highlight, t tie, p pants, P pants
// shadow, b shoes, L light, w white.
final _frontTop = [
  '...ooo',
  '..ohhh',
  '.ohhHH',
  '.ohhhh',
  '.ohsss',
  '.osess',
  '.orsss',
  '..osss',
  '..oCck',
  '.oCcct',
  'osCcct',
  'osCcct',
  '.oCcct',
  '..oppp',
  '..oppP',
];
final front = Sprite('front', _m([..._frontTop, '..oppo', '..obbo', '..ooo.']));
final walkA = Sprite(
  'walkA',
  _m([..._frontTop, '..oppooppo..', '..obbooppo..', '..ooo.obbo..']),
);
final walkB = Sprite(
  'walkB',
  _m([..._frontTop, '..oppooppo..', '..oppoobbo..', '..obbo.ooo..']),
);
final _backTop = [
  '...ooo',
  '..ohhh',
  '.ohhhH',
  '.ohhhh',
  '.ohhhh',
  '.ohhhh',
  '..ohhh',
  '..oCcc',
  '.oCccc',
];
final back = Sprite(
  'back',
  _m([
    ..._backTop,
    'oCcccc',
    'oCcccc',
    '.oCccc',
    '.oCccc',
    '..oppp',
    '..oppo',
    '..obbo',
    '..ooo.',
  ]),
);
final typeA = Sprite(
  'typeA',
  _m([..._backTop, 'osCccc', 'oCcccc', '.oCccc', '.oPppp', '..oooo']),
);
final typeB = Sprite(
  'typeB',
  _m([
    ..._backTop.sublist(0, 8),
    '.osCcccccCo.',
    'oCcccccccCso',
    'oCcccccccCo.',
    '.oCccccccCo.',
    '.oPpppppppo.',
    '..oooooooo..',
  ]),
);
final sit = Sprite(
  'sit',
  _m([..._frontTop.sublist(0, 13), '.opppp', 'obbopp', 'ooo.oo']),
);
final bot = Sprite('bot', [
  '...LL...',
  '...oo...',
  '.oooooo.',
  'okkkkkko',
  'okecceko',
  'okkkkkko',
  '.occcco.',
  '..o..o..',
]);

/// How one agent looks: provider shirt, a seeded skin and hair, boss tie.
class Look {
  const Look({
    required this.key,
    required this.palette,
    required this.accessory,
  });
  final String key;
  final Map<String, Color> palette;
  final String accessory;
}

Color _shade(Color c, double f) => Color.from(
  alpha: c.a,
  red: (c.r * f).clamp(0, 1),
  green: (c.g * f).clamp(0, 1),
  blue: (c.b * f).clamp(0, 1),
);
Color _tint(Color c, double f) => Color.lerp(c, const Color(0xFFFFFFFF), f)!;

const _skins = [
  (Color(0xFFF2C9A0), Color(0xFFD9A57A)),
  (Color(0xFFD9A06E), Color(0xFFB47A4C)),
  (Color(0xFFA46B45), Color(0xFF7E4E31)),
  (Color(0xFF6E4630), Color(0xFF51321F)),
];
const _hairs = [
  Color(0xFF2B1D16),
  Color(0xFF5A3A22),
  Color(0xFF1C1C24),
  Color(0xFFB8843D),
  Color(0xFF8C3B2E),
  Color(0xFFD9D2C5),
];

int _seed(String s) {
  var h = 0;
  for (final u in s.codeUnits) {
    h = (h * 31 + u) & 0x7fffffff;
  }
  return h;
}

Look lookFor(ChatSummary chat, {bool boss = false}) {
  final seed = _seed(chat.id);
  final shirt = Providers.color(chat.source);
  final skin = _skins[seed % _skins.length];
  final hair = _hairs[(seed ~/ 7) % _hairs.length];
  final accessory = switch (chat.source) {
    'claude' => 'spark',
    'codex' => 'headphones',
    'antigravity' || 'gemini' => 'cap',
    'cursor' => 'glasses',
    'opencode' => 'beanie',
    _ => 'none',
  };
  return Look(
    key: '${chat.source}:${seed % 24}:$boss',
    accessory: accessory,
    palette: {
      'o': const Color(0xFF14121C),
      'h': hair,
      'H': _tint(hair, .25),
      's': skin.$1,
      'S': skin.$2,
      'r': Color.lerp(skin.$1, const Color(0xFFE77A7A), .35)!,
      'e': const Color(0xFF1B1626),
      'c': shirt,
      'C': _shade(shirt, .72),
      'k': _tint(shirt, .3),
      't': boss ? const Color(0xFFE5484D) : shirt,
      'p': const Color(0xFF353A52),
      'P': const Color(0xFF262A3D),
      'b': const Color(0xFF1E1A22),
      'L': NX.working,
      'w': const Color(0xFFFFFFFF),
    },
  );
}

/// Records sprites once per look; replaying a Picture is cheap.
class SpriteBook {
  final _pictures = <String, ui.Picture>{};
  final _paint = Paint()..isAntiAlias = false;

  ui.Picture picture(Sprite sprite, Map<String, Color> palette, String key) =>
      _pictures.putIfAbsent('${sprite.name}|$key', () {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        for (var y = 0; y < sprite.height; y++) {
          final row = sprite.rows[y];
          var x = 0;
          while (x < row.length) {
            final ch = row[x];
            var run = 1;
            while (x + run < row.length && row[x + run] == ch) {
              run++;
            }
            final color = palette[ch];
            if (ch != '.' && color != null) {
              canvas.drawRect(
                Rect.fromLTWH(x.toDouble(), y.toDouble(), run.toDouble(), 1),
                _paint..color = color,
              );
            }
            x += run;
          }
        }
        return recorder.endRecording();
      });

  /// Draws [sprite] with its feet at [feet] (bottom-centre).
  void draw(
    Canvas canvas,
    Sprite sprite,
    Look look,
    Offset feet, {
    bool flip = false,
    double opacity = 1,
  }) {
    canvas.save();
    canvas.translate(
      (feet.dx - sprite.width / 2).roundToDouble(),
      (feet.dy - sprite.height).roundToDouble(),
    );
    if (flip) {
      canvas.translate(sprite.width.toDouble(), 0);
      canvas.scale(-1, 1);
    }
    if (opacity < 1) {
      canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
    }
    canvas.drawPicture(picture(sprite, look.palette, look.key));
    if (opacity < 1) canvas.restore();
    canvas.restore();
  }

  /// Provider accessory on a front- or back-facing character at [feet].
  void accessory(Canvas canvas, Sprite sprite, Look look, Offset feet) {
    final x = (feet.dx - sprite.width / 2).roundToDouble();
    final y = (feet.dy - sprite.height).roundToDouble();
    final backView =
        sprite.name.startsWith('back') || sprite.name.startsWith('type');
    void p(double dx, double dy, double w, double h, Color c) =>
        canvas.drawRect(Rect.fromLTWH(x + dx, y + dy, w, h), _paint..color = c);
    final accent = look.palette['c']!;
    switch (look.accessory) {
      case 'headphones':
        p(1, 2, 10, 1, const Color(0xFF14121C));
        p(0, 3, 2, 3, accent);
        p(10, 3, 2, 3, accent);
      case 'cap':
        p(2, 0, 8, 2, accent);
        p(3, 0, 6, 1, _tint(accent, .3));
        if (!backView) p(1, 2, 10, 1, _shade(accent, .7));
      case 'beanie':
        p(2, 0, 8, 3, accent);
        p(2, 2, 8, 1, _shade(accent, .7));
        p(5, -1, 2, 1, _tint(accent, .4));
      case 'glasses':
        if (!backView) {
          p(2, 5, 3, 1, const Color(0xFF14121C));
          p(7, 5, 3, 1, const Color(0xFF14121C));
          p(5, 5, 2, 1, const Color(0xFF6B6B75));
        }
      case 'spark':
        if (!backView && sprite.height > 14) {
          p(3, 10, 1, 1, const Color(0xFFFFE2C6));
          p(2, 11, 3, 1, const Color(0xFFFFE2C6));
          p(3, 12, 1, 1, const Color(0xFFFFE2C6));
        }
    }
  }
}

/// Pixel rectangle helper for furniture: art-pixel coordinates, no anti-aliasing.
class Px {
  Px(this.canvas);
  final Canvas canvas;
  final _paint = Paint()..isAntiAlias = false;
  void r(double x, double y, double w, double h, Color c) =>
      canvas.drawRect(Rect.fromLTWH(x, y, w, h), _paint..color = c);

  /// A shaded block: fill, lit top edge, dark bottom edge, outline.
  void block(
    double x,
    double y,
    double w,
    double h,
    Color fill, {
    bool outline = true,
  }) {
    if (outline) r(x - 1, y - 1, w + 2, h + 2, const Color(0xFF14121C));
    r(x, y, w, h, fill);
    r(x, y, w, 1, _tint(fill, .22));
    r(x, y + h - 1, w, 1, _shade(fill, .7));
  }
}

Color shade(Color c, double f) => _shade(c, f);
Color tint(Color c, double f) => _tint(c, f);
