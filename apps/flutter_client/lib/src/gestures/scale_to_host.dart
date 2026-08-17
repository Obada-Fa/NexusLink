// Dart port of `scaleToHost` from the NexusLink gesture engine
// (packages/gesture-engine/src/index.ts).
//
// Pure function, no Flutter imports, so it is unit-testable in isolation.

/// How the remote frame is fitted into the phone view.
enum ScaleFit {
  /// Letterbox bars (CSS object-fit: contain). Desktop / adopted windows.
  contain,

  /// Stretch to the view. Virtual phone sessions are 1:1 — no bars.
  fill,
}

/// Map a touch point within a (possibly letterboxed) view to the corresponding
/// pixel on the host screen.
///
/// [ScaleFit.contain] (default): whichever axis has spare room gets symmetric
/// letterbox bars, and touches inside the bars clamp to the nearest host edge.
/// [ScaleFit.fill]: stretch, so a tap at view (x,y) maps to the same relative
/// host pixel — used for virtual sessions that match the phone stage.
({double x, double y}) scaleToHost(
  double touchX,
  double touchY,
  double viewWidth,
  double viewHeight,
  double hostWidth,
  double hostHeight, [
  ScaleFit fit = ScaleFit.contain,
]) {
  if (viewWidth <= 0 || viewHeight <= 0 || hostWidth <= 0 || hostHeight <= 0) {
    return (x: 0, y: 0);
  }

  if (fit == ScaleFit.fill) {
    final scaledX = (touchX / viewWidth) * hostWidth;
    final scaledY = (touchY / viewHeight) * hostHeight;
    return (
      x: scaledX.roundToDouble().clamp(0, hostWidth),
      y: scaledY.roundToDouble().clamp(0, hostHeight),
    );
  }

  final hostAspect = hostWidth / hostHeight;
  final viewAspect = viewWidth / viewHeight;

  double contentWidth;
  double contentHeight;
  double offsetX;
  double offsetY;

  if (viewAspect > hostAspect) {
    contentWidth = viewWidth;
    contentHeight = viewWidth / hostAspect;
    offsetX = 0;
    offsetY = (viewHeight - contentHeight) / 2;
  } else {
    contentHeight = viewHeight;
    contentWidth = viewHeight * hostAspect;
    offsetX = (viewWidth - contentWidth) / 2;
    offsetY = 0;
  }

  if (contentWidth <= 0 || contentHeight <= 0) {
    return (x: 0, y: 0);
  }

  final scaledX = ((touchX - offsetX) / contentWidth) * hostWidth;
  final scaledY = ((touchY - offsetY) / contentHeight) * hostHeight;

  return (
    x: scaledX.roundToDouble().clamp(0, hostWidth),
    y: scaledY.roundToDouble().clamp(0, hostHeight),
  );
}
