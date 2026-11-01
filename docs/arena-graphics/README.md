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

## Shared office arena — 2026-11-01

Arena retains a spatial pixel-art office: drag to move around, pinch to zoom, use
+/− buttons, or fit the whole office. The earlier task-card dashboard has been
replaced after user feedback that exploration and zoom must remain part of Arena.

Active and attention-needed agents share one room, with no agent cap. Stable desk
ordering survives live updates; agents move between desks, shelves, the server
corner, and the help area according to activity. Tap agents for live details and
existing approval controls. Selected labels include the project and current step.
The status chips focus matching agents, and List everyone provides readable details
without hunting around the room. Idle/completed chats stay in a counted drawer.

A clickable receptionist stands at the entrance, and the permanently visible New
chat button opens the same searchable project picker. Project selection, default
folder, retry, offline disabling, host-change checks, and explicit pagination remain.
The project filter stays above the scene. Reduced motion and offline mode stop the
animation ticker entirely; camera movement remains available.

Previews: [busy](shared-office-busy.png), [empty](shared-office-empty.png),
[320 px / 1.8× text](shared-office-large-text.png).

Validation: 46 tests passed across shared_office_test, arena_world_test,
arena_graphics_test, chat_library_test, monitor_states_test, and agent_monitor_test.
Targeted analysis is clean. Tests cover drag/pinch/button zoom and fit, all 40 agents
being retained and camera focus reaching the last one, project filtering/selection,
retry, default folder, cancellation/offline behavior, stable ordering, completion,
animation frame changes, and reduced-motion screenshot equality. Physical-phone
acceptance and a new installable APK are still pending.

Regenerate shared-office captures from apps/flutter_client:

```sh
flutter test --no-pub test/shared_office_test.dart --dart-define=OFFICE_CAPTURE=true
```

Optionally pass `--dart-define=ARENA_FONT=/absolute/path/to/Roboto-Regular.ttf` for
readable text in exported test screenshots. Output is in build/arena-review.
