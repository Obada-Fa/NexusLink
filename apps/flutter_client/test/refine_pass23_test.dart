// Refine plan passes 2–3: labels that say what state you are in.

import 'package:flutter_test/flutter_test.dart';
import 'package:nexuslink/src/screens/mirror_screen.dart';
import 'package:nexuslink/src/shell/shell_navigator.dart';
import 'package:nexuslink/src/theme/nexus_theme.dart';
import 'package:nexuslink/src/workspace/changes_screen.dart';
import 'package:nexuslink/src/workspace/editor_screen.dart';
import 'package:nexuslink/src/workspace/workspace_shell.dart';

void main() {
  test('editor save state reads as words with meaning colours', () {
    expect(
      editorSaveState(dirty: true, saving: false, writable: true),
      ('Unsaved · not on PC yet', NX.waiting),
    );
    expect(
      editorSaveState(dirty: false, saving: false, writable: true),
      ('Saved to PC', NX.working),
    );
    expect(
      editorSaveState(dirty: true, saving: true, writable: true).$1,
      'Saving to PC…',
    );
    expect(
      editorSaveState(dirty: true, saving: false, writable: true, failed: true)
          .$1,
      'Not saved · see below',
    );
    expect(
      editorSaveState(dirty: false, saving: false, writable: false).$1,
      'Read only',
    );
  });

  test('changes header names the project', () {
    expect(changesProjectName('/home/me/code/NexusLink'), 'NexusLink');
    expect(changesProjectName(r'C:\code\app\'), 'app');
  });

  test('a module returned to shows its own workspace tab', () {
    expect(workspaceTabForModule('agents'), WorkspaceTabs.monitor);
    expect(workspaceTabForModule('terminal'), WorkspaceTabs.terminal);
    expect(workspaceTabForModule('files'), WorkspaceTabs.files);
    expect(workspaceTabForModule('desktop'), WorkspaceTabs.pc);
    expect(workspaceTabForModule('remote'), isNull);
    for (final tab in WorkspaceTabs.all) {
      expect(workspaceTabForModule(moduleForWorkspaceTab(tab)), tab);
    }
  });

  test('mirror input mode in words', () {
    expect(mirrorInputModeLabel(viewOnly: true, mouse: true), 'View only');
    expect(mirrorInputModeLabel(viewOnly: false, mouse: true), 'Trackpad');
    expect(mirrorInputModeLabel(viewOnly: false, mouse: false), 'Direct touch');
  });
}
