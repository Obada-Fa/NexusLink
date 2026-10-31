# Arena graphics pass

Flutter-rendered previews at a 390 × 760 logical-pixel phone viewport, captured
at 2× resolution with identical fixture data and camera positions. These are
widget-test captures, not screenshots from a physical device.

| Scene | Before | After |
| --- | --- | --- |
| Busy office | [Before](before-busy.png) | [After](after-busy.png) |
| Quiet office | [Before](before-quiet.png) | [After](after-quiet.png) |

This pass updates the palette, furniture shading, floor textures, character
frames, and name/status labels. Room geometry and chat navigation are unchanged.
Labels stay visible at the initial phone zoom and retain contrast at night.
Overlapping labels are suppressed, with the selected agent taking priority;
selecting an agent also gives its title more space. Large text and long names
can still be truncated within the current room layout.

From `apps/flutter_client`, regenerate review captures with:

```sh
flutter test --no-pub test/arena_graphics_test.dart \
  --dart-define=ARENA_CAPTURE=after \
  --dart-define=ARENA_FONT=/absolute/path/to/Roboto-Regular.ttf
```

Captures are written to `build/arena-review/`, including night, larger-text,
long-title, and selected-agent views. The font path is optional for tests;
supply it for readable review images instead of Flutter's test font.
