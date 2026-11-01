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

## Shared office — 2026-11-01

The library's Arena now opens a single vertically scrolling office with reception,
readable task/project/status cards, and activity-specific pixel desk animations.
Attention comes first; ordering within each priority group stays stable when live
updates reorder the source list. Working and attention-needed chats remain visible;
idle/completed chats collapse into a counted list. A completed working chat briefly
shows a checkmark before leaving the active office. Archived chats are excluded.
There is no active-agent cap, and an explicit Load more chats action exposes further
library pages. Project filtering and status totals stay above the scrolling desks.

Reception opens a searchable project picker, loads all project pages from the
connected host, and reuses AgentScreen's new-chat flow with the selected folder.
It supports the default folder, cancellation, retry, offline disabling, and rejects
a selection if the connected client changes while the picker is open. Agent cards
reuse the existing details sheet and phone approval controls. Offline activity is
marked last known, and animations stop offline or with reduced motion enabled.

Previews: [busy](shared-office-busy.png), [empty](shared-office-empty.png),
[320 px / 1.8× text](shared-office-large-text.png).

Validation: 45 tests passed across shared_office_test, arena_world_test,
arena_graphics_test, chat_library_test, monitor_states_test, and agent_monitor_test.
Targeted Flutter analysis reports no issues. Nine new widget tests include stable
ordering, completion transitions, project selection/filtering, retry and default
folder, cancellation/offline behavior, 40 agents and pagination, animation frame
changes, and reduced-motion screenshot equality. Physical-phone acceptance and a
new installable APK are not part of this check. The previous campus renderer is
retained for its existing rendering tests, but is no longer the library entry point.

To regenerate shared-office captures from apps/flutter_client:

```sh
flutter test --no-pub test/shared_office_test.dart --dart-define=OFFICE_CAPTURE=true
```

Optionally pass `--dart-define=ARENA_FONT=/absolute/path/to/Roboto-Regular.ttf` for
readable text in exported test screenshots. Output is in build/arena-review.
