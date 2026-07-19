// Dart port of `scaleToHost` from the NexusLink gesture engine
// (packages/gesture-engine/src/index.ts).
//
// Pure function, no Flutter imports, so it is unit-testable in isolation.

/// Map a touch point within a (possibly letterboxed) view to the corresponding
/// pixel on the host screen.
///
/// The remote frame is rendered "contain"-style inside the view: whichever
/// axis has spare room gets symmetric letterbox bars, and touches inside the
/// bars clamp to the nearest host edge. Mirrors the TS implementation exactly
/// (round, then clamp to `[0, host]`).
({double x, double y}) scaleToHost(
  double touchX,
  double touchY,
  double viewWidth,
  double viewHeight,
  double hostWidth,
  double hostHeight,
) {
  if (viewWidth <= 0 || viewHeight <= 0 || hostWidth <= 0 || hostHeight <= 0) {
    return (x: 0, y: 0);
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
