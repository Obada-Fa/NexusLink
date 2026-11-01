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

## Project campus — 2026-11-01

The single shared office was dropped because it hid which project each agent was
on. Arena is a pannable campus again, with one room per project.

A strip of project chips under the status chips names every project and its state
(`NexusLink · 1 need you`), marks the room in view, and flies there when tapped.
It replaces the project filter dropdown.

Every chat stays on the map. Finished agents walk to their room's lounge; recently
stopped sessions (host state `idle`) go there too, labelled Stopped instead of Done
because idle does not imply success. After 3 hours they sleep at their desk.

Desks stay stable across live updates, and active agents are never dropped by the
room or per-room caps. Each room has a reception desk that starts a chat in that
project; the New chat button opens the searchable project picker.

Previews: [busy](shared-office-busy.png), [empty](shared-office-empty.png),
[320 px / 1.8× text](shared-office-large-text.png). At 1.8× text the status chips
wrap and can cover the top of the first room. Physical-phone acceptance and a new
installable APK are still pending.

### Small rooms on a phone

With two or more projects on a phone, rooms shrink and sit two across, so about
eight projects and their live agents share one screen. Agents still walk between
desks, shelves, rack, sofa and door; labels stay inside their room. Pinch or use
the project chips to zoom in; the fit button returns to the overview. The small
rooms have no reception desk, so use New chat. One project, or a wider screen,
keeps the full-size room.

Preview: [compact](compact-busy.png).

Regenerate captures from apps/flutter_client:

```sh
flutter test --no-pub test/shared_office_test.dart --dart-define=OFFICE_CAPTURE=true
```

Optionally pass `--dart-define=ARENA_FONT=/absolute/path/to/Roboto-Regular.ttf` for
readable text in exported test screenshots. Output is in build/arena-review.
