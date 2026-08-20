import 'package:flutter/painting.dart';

import '../gestures/scale_to_host.dart';

/// WebRTC grabs a whole DISPLAY. Only virtual (phone-shaped) sessions match
/// the phone; physical windows stay on cropped MJPEG.
bool shouldUpgradeWebrtc({required bool isVirtual, String? sessionId}) =>
    isVirtual && sessionId != null && sessionId.isNotEmpty;

/// Adopted windows and virtual sessions are already phone-aspect — fill so
/// letterbox math cannot drift from the picture. Full-desktop mirror contains.
bool mirrorFillsView({required bool isVirtual, required bool hasWindow}) =>
    isVirtual || hasWindow;

ScaleFit mirrorScaleFit({required bool fill}) =>
    fill ? ScaleFit.fill : ScaleFit.contain;

BoxFit mirrorBoxFit({required bool fill}) =>
    fill ? BoxFit.fill : BoxFit.contain;
