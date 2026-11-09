import 'package:flutter/material.dart';

class HomeWallpaper extends StatelessWidget {
  const HomeWallpaper({super.key});

  @override
  Widget build(BuildContext context) => SizedBox.expand(
    child: Image.asset(
      'assets/home/dusk.webp',
      fit: BoxFit.cover,
      color: const Color(0x5b0d1320),
      colorBlendMode: BlendMode.srcOver,
      excludeFromSemantics: true,
    ),
  );
}

/// Original miniature objects for the six built-in PC tools.
class HomeShortcutArt extends StatelessWidget {
  const HomeShortcutArt({super.key, required this.moduleId, this.size = 56});
  final String moduleId;
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _ShortcutPainter(moduleId));
}

class _ShortcutPainter extends CustomPainter {
  const _ShortcutPainter(this.module);
  final String module;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 64, size.height / 64);

    // All illustrations share an upper-left light, a soft cast shadow and
    // a 64-unit drawing grid, so their outlines sit together at phone sizes.
    Paint shade(Rect bounds, int light, int dark) =>
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(light), Color(dark)],
          ).createShader(bounds);
    void block(double x, double y, double w, double h, double r, int a, int b) {
      final rect = Rect.fromLTWH(x, y, w, h);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(r)),
        shade(rect, a, b),
      );
    }

    void shape(Path path, int light, int dark) =>
        canvas.drawPath(path, shade(path.getBounds(), light, dark));
    void line(
      double x,
      double y,
      double endX,
      double endY,
      double width,
      int color,
    ) => canvas.drawLine(
      Offset(x, y),
      Offset(endX, endY),
      Paint()
        ..color = Color(color)
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
    void dot(double x, double y, double radius, int color) =>
        canvas.drawCircle(Offset(x, y), radius, Paint()..color = Color(color));

    canvas.drawOval(
      const Rect.fromLTWH(9, 51, 47, 6),
      Paint()
        ..color = const Color(0x7008111c)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
    );

    switch (module) {
      case 'files':
        shape(
          Path()
            ..moveTo(6, 18)
            ..quadraticBezierTo(6, 13, 11, 13)
            ..lineTo(23, 13)
            ..lineTo(29, 18)
            ..lineTo(52, 18)
            ..quadraticBezierTo(57, 18, 57, 23)
            ..lineTo(55, 50)
            ..lineTo(8, 50)
            ..close(),
          0xfff2b055,
          0xffa9682d,
        );
        block(10, 22, 42, 23, 2, 0xfff5edda, 0xffd6cbac);
        block(13, 25, 41, 22, 2, 0xfffff6e5, 0xffc6bca3);
        shape(
          Path()
            ..moveTo(7, 29)
            ..quadraticBezierTo(7, 26, 11, 26)
            ..lineTo(56, 26)
            ..quadraticBezierTo(60, 26, 59, 31)
            ..lineTo(55, 50)
            ..quadraticBezierTo(54, 54, 50, 54)
            ..lineTo(12, 54)
            ..quadraticBezierTo(8, 54, 8, 50)
            ..close(),
          0xffffd784,
          0xffdc913a,
        );
        line(12, 28, 54, 28, 1.3, 0xffffe9bf);
        line(41, 46, 49, 46, 2.2, 0xffca8637);
      case 'desktop':
        block(27, 42, 10, 10, 1, 0xffa7b4c0, 0xff667789);
        block(18, 51, 28, 4, 2, 0xffe6e4dd, 0xff8d9baa);
        block(5, 10, 54, 36, 4, 0xfff1efe8, 0xff8b9caf);
        block(8, 13, 48, 28, 2, 0xffb2bfda, 0xff486088);
        final panel = RRect.fromRectAndRadius(
          const Rect.fromLTWH(8, 13, 48, 28),
          const Radius.circular(2),
        );
        canvas.save();
        canvas.clipRRect(panel);
        dot(20, 22, 4, 0xffffd29f);
        shape(
          Path()
            ..moveTo(8, 37)
            ..lineTo(28, 24)
            ..lineTo(44, 41)
            ..lineTo(8, 41)
            ..close(),
          0xffa7a0ca,
          0xff6b78a8,
        );
        shape(
          Path()
            ..moveTo(14, 41)
            ..lineTo(45, 22)
            ..lineTo(62, 34)
            ..lineTo(62, 42)
            ..close(),
          0xff7795ad,
          0xff3d597d,
        );
        canvas.restore();
        dot(32, 43.5, 1, 0xff607783);
      case 'terminal':
        block(6, 11, 52, 42, 6, 0xffa6b8ac, 0xff526760);
        block(8, 13, 48, 37, 4, 0xff374d48, 0xff172a2b);
        line(10, 21, 54, 21, 1, 0xff576b63);
        dot(14, 17, 1.3, 0xffe8b783);
        dot(19, 17, 1.3, 0xffa5be97);
        line(15, 29, 21, 34, 3.1, 0xffb4e9ab);
        line(21, 34, 15, 39, 3.1, 0xffb4e9ab);
        line(27, 39, 36, 39, 2.8, 0xffb4e9ab);
      case 'agents':
        block(23, 23, 33, 25, 8, 0xffbfb7ef, 0xff897bb6);
        shape(
          Path()
            ..moveTo(44, 44)
            ..lineTo(54, 53)
            ..lineTo(53, 42)
            ..close(),
          0xffa59acb,
          0xff8b80b3,
        );
        shape(
          Path()
            ..moveTo(11, 32)
            ..lineTo(10, 44)
            ..lineTo(23, 35)
            ..close(),
          0xfff1dcff,
          0xffc2acdf,
        );
        block(5, 10, 41, 27, 9, 0xfffaedff, 0xffc9b4e5);
        for (final x in [16.0, 25.5, 35.0]) {
          dot(x, 23, 2.4, 0xff76618a);
        }
      case 'remote':
        canvas.save();
        canvas.translate(32, 32);
        canvas.rotate(-0.15);
        canvas.translate(-32, -32);
        block(15, 6, 34, 49, 7, 0xffe5f5e8, 0xff7ea69d);
        block(18, 9, 28, 38, 5, 0xffb9e2d5, 0xff7bb8ad);
        shape(
          Path()
            ..moveTo(26, 19)
            ..lineTo(39, 29)
            ..lineTo(33, 30)
            ..lineTo(35, 36)
            ..lineTo(31, 37)
            ..lineTo(29, 31)
            ..lineTo(25, 35)
            ..close(),
          0xfffcfcf0,
          0xffe1eedb,
        );
        line(27, 50, 37, 50, 1.7, 0xff678e87);
        canvas.restore();
      case 'audio':
        final arch = Path()
          ..moveTo(12, 39)
          ..lineTo(12, 30)
          ..cubicTo(12, 3, 52, 3, 52, 30)
          ..lineTo(52, 39);
        canvas.drawPath(
          arch,
          Paint()
            ..color = const Color(0xff995e4f)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 7
            ..strokeCap = StrokeCap.round,
        );
        canvas.drawPath(
          arch.shift(const Offset(0, -2)),
          Paint()
            ..color = const Color(0xfff2b794)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4
            ..strokeCap = StrokeCap.round,
        );
        block(8, 32, 13, 20, 5, 0xfffac6a2, 0xffca7e6a);
        block(17, 30, 7, 23, 3, 0xff694f55, 0xff40363f);
        block(43, 32, 13, 20, 5, 0xfffac6a2, 0xffca7e6a);
        block(40, 30, 7, 23, 3, 0xff694f55, 0xff40363f);
    }
  }

  @override
  bool shouldRepaint(_ShortcutPainter oldDelegate) =>
      oldDelegate.module != module;
}
