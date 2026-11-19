import 'package:asciicast_editor/asciicast_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sampleV2Cast = '''
{"version": 2, "width": 100, "height": 30, "idle_time_limit": 2, "title": "Unit Test Cast"}
[0.5, "o", "echo hello\\r\\n"]
[1.0, "m", "Step 1"]
[1.5, "o", "hello\\r\\n"]
[6.5, "o", "secret_token=abc123xyz\\r\\n"]
[8.0, "m", "Step 2"]
[9.0, "o", "done\\r\\n"]
''';

  test('parses asciicast v2 header, events, and markers accurately', () {
    final doc = AsciicastDocument.parse(sampleV2Cast);
    expect(doc.header.version, 2);
    expect(doc.header.width, 100);
    expect(doc.header.height, 30);
    expect(doc.header.idleTimeLimit, 2.0);
    expect(doc.header.title, 'Unit Test Cast');
    expect(doc.markers.length, 2);
    expect(doc.markers[0].label, 'Step 1');
    expect(doc.markers[0].time, 1.0);
    expect(doc.markers[1].label, 'Step 2');
    expect(doc.markers[1].time, 8.0);
    expect(doc.clips.single.events.length, 4);
  });

  test(
    'supports NLE razor split, speed scaling, ripple delete, and undo/redo',
    () {
      final controller = AsciicastEditorController(
        initialCastContent: sampleV2Cast,
      );
      addTearDown(controller.dispose);

      expect(controller.clips.length, 1);
      final didSplit = controller.splitClipAt(2.0);
      expect(didSplit, isTrue);
      expect(controller.clips.length, 2);
      expect(controller.canUndo, isTrue);

      final secondClipId = controller.clips[1].id;
      controller.setClipSpeed(secondClipId, 2.0);
      expect(controller.clips[1].speed, 2.0);

      // Undo speed change
      controller.undo();
      expect(controller.clips[1].speed, 1.0);

      // Redo speed change
      controller.redo();
      expect(controller.clips[1].speed, 2.0);

      // Ripple delete first clip
      final deleted = controller.deleteClip(controller.clips.first.id);
      expect(deleted, isTrue);
      expect(controller.clips.length, 1);
    },
  );

  test('supports idle time compression, text redaction, and cast export', () {
    final controller = AsciicastEditorController(
      initialCastContent: sampleV2Cast,
    );
    addTearDown(controller.dispose);

    final replaced = controller.redactText(
      pattern: 'abc123xyz',
      replacement: '***REDACTED***',
    );
    expect(replaced, 1);

    controller.compressIdleTime(maxIdleSeconds: 1.0);
    controller.addMarker(0.2, 'Start Marker');

    final exportedV2 = controller.exportCast(versionOverride: 2);
    expect(exportedV2, contains('***REDACTED***'));
    expect(exportedV2, isNot(contains('abc123xyz')));
    expect(exportedV2, contains('Start Marker'));

    final reparsed = AsciicastDocument.parse(exportedV2);
    expect(reparsed.markers.any((m) => m.label == 'Start Marker'), isTrue);
  });

  test('renders terminal buffer at playhead and jumps to final result', () {
    final controller = AsciicastEditorController(
      initialCastContent: sampleV2Cast,
    );
    addTearDown(controller.dispose);

    controller.jumpToFinalResult();
    expect(controller.playheadTime, closeTo(controller.totalDuration, 1e-3));
    final bufferChars = controller.virtualTerminal.buffer.characters.join();
    expect(bufferChars, contains('done'));
  });

  testWidgets(
    'timeline fills full viewport width when recording duration is short',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const shortCast = '''
{"version": 2, "width": 80, "height": 24}
[0.2, "o", "hi\\r\\n"]
[0.8, "o", "bye\\r\\n"]
''';
      final controller = AsciicastEditorController(
        initialCastContent: shortCast,
      );
      addTearDown(controller.dispose);
      controller.setTimelineZoom(32.0); // 10s * 32px = 320px < viewport

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              height: 220,
              child: AsciicastTimelinePanel(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final scrollViewBox = tester.getSize(find.byType(SingleChildScrollView));
      // Right scrollable area = 1200 - 148 (headers) - 1 (divider) = 1051
      expect(scrollViewBox.width, closeTo(1051.0, 1.0));

      // The inner SizedBox inside SingleChildScrollView must match viewport width, not 600
      final innerSizedBoxes = tester
          .widgetList<SizedBox>(
            find.descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(SizedBox),
            ),
          )
          .where((box) => box.width != null)
          .toList();
      expect(innerSizedBoxes.first.width, closeTo(1051.0, 1.0));
    },
  );

  testWidgets(
    'Spacebar keeps toggling play/pause after clicking buttons and dialogs, and DaVinci shortcuts work',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = AsciicastEditorController(
        initialCastContent: sampleV2Cast,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AsciicastEditor(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();

      // Click the Play button so the FilledButton takes primary focus
      await tester.tap(find.text('播放'));
      await tester.pump();
      expect(controller.isPlaying, isTrue);

      // Spacebar must pause (not re-trigger or get swallowed by focused button)
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(controller.isPlaying, isFalse);

      // Click another button (e.g. jump to start) to move focus to an IconButton
      await tester.tap(find.byIcon(Icons.skip_previous));
      await tester.pump();

      // Spacebar must still play!
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(controller.isPlaying, isTrue);

      // DaVinci K stops playback
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.pump();
      expect(controller.isPlaying, isFalse);

      // DaVinci L starts playback and steps up speed
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(controller.isPlaying, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(controller.playbackSpeed, greaterThan(1.0));

      // DaVinci J pauses and steps backward
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pump();
      expect(controller.isPlaying, isFalse);

      // DaVinci B selects Blade/Razor, A selects Pointer
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.pump();
      expect(controller.activeTool, NleToolMode.razor);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      expect(controller.activeTool, NleToolMode.pointer);

      // DaVinci Ctrl+B splits at playhead
      controller.seek(2.0);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(controller.clips.length, 2);

      // DaVinci D toggles mute on selected clip
      final selectedId = controller.selectedClipId!;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.pump();
      expect(
        controller.clips.firstWhere((c) => c.id == selectedId).muted,
        isTrue,
      );

      // DaVinci Ctrl+L toggles looping
      expect(controller.isLooping, isFalse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(controller.isLooping, isTrue);

      // DaVinci Shift+Z fits timeline to viewport
      controller.setTimelineZoom(20.0);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(controller.timelineZoom, greaterThan(20.0));

      // Open Marker dialog with M: Space inside dialog TextField must NOT toggle play
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(controller.isPlaying, isFalse);

      // Close dialog and verify Spacebar works again immediately
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(controller.isPlaying, isTrue);

      // Clean up playback timer before widget disposal
      controller.pause();
    },
  );

  test('supports auto-slicing clips by output lines and by input events', () {
    const multiLineAndInputCast = '''
{"version": 2, "width": 80, "height": 24}
[0.2, "i", "l"]
[0.5, "o", "line 1\\r\\n"]
[1.2, "i", "pwd\\r"]
[1.5, "o", "/home/user\\r\\n"]
[2.4, "i", "exit\\r"]
[2.8, "o", "bye\\r\\n"]
''';
    // 1. Slice by output line
    final lineCtrl = AsciicastEditorController(
      initialCastContent: multiLineAndInputCast,
    );
    addTearDown(lineCtrl.dispose);

    final addedByLine = lineCtrl.autoSliceClips(
      mode: AutoSliceMode.byLine,
      minClipDuration: 0.2,
    );
    expect(addedByLine, 2);
    expect(lineCtrl.clips.length, 3);

    // Undo restores single clip
    lineCtrl.undo();
    expect(lineCtrl.clips.length, 1);

    // 2. Slice by input event
    final inputCtrl = AsciicastEditorController(
      initialCastContent: multiLineAndInputCast,
    );
    addTearDown(inputCtrl.dispose);

    final addedByInput = inputCtrl.autoSliceClips(
      mode: AutoSliceMode.byInput,
      minClipDuration: 0.2,
    );
    expect(addedByInput, 2);
    expect(inputCtrl.clips.length, 3);
  });

  testWidgets('toggles skip-marker-pause via Ctrl+M and transport button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AsciicastEditorController(
      initialCastContent: sampleV2Cast,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AsciicastEditor(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.pauseOnMarkers, isTrue);

    // Toggle via Ctrl+M
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(controller.pauseOnMarkers, isFalse);

    // Toggle back via transport deck flag button
    await tester.tap(find.byIcon(Icons.outlined_flag));
    await tester.pump();
    expect(controller.pauseOnMarkers, isTrue);
  });

  testWidgets(
    'marker drag and clip trim drag track pointer 1:1 without offset',
    (tester) async {
      const castWithIdle = '''
{"version": 2, "width": 80, "height": 24, "idle_time_limit": 2.0}
[0.5, "o", "start\\r\\n"]
[1.5, "m", "MarkA"]
[12.0, "o", "end\\r\\n"]
''';
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = AsciicastEditorController(
        initialCastContent: castWithIdle,
      );
      addTearDown(controller.dispose);
      controller.setTimelineZoom(50.0); // 50px = 1.0s

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              height: 220,
              child: AsciicastTimelinePanel(controller: controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Drag marker MarkA by +25px -> should move +0.5s exactly
      final initialMarkerTime = controller.markers.single.time;
      final markerFinder = find.text('MarkA');
      await tester.drag(markerFinder, const Offset(25.0, 0.0));
      await tester.pumpAndSettle();
      expect(
        controller.markers.single.time,
        closeTo(initialMarkerTime + 0.5, 0.05),
      );

      // Undo should restore marker to exact pre-drag time
      controller.undo();
      expect(controller.markers.single.time, closeTo(initialMarkerTime, 0.01));

      // 2. Drag clip right trim handle by -50px -> should shrink span by -1.0s
      final initialEnd = controller.computeClipSpans().single.end;
      final clipTopLeft = tester.getTopLeft(
        find.text(controller.clips.single.name),
      );
      // Right trim handle is at x = 149 + initialEnd * 50 - 4
      final handleStart = Offset(
        149.0 + initialEnd * 50.0 - 4.0,
        clipTopLeft.dy + 20.0,
      );
      await tester.dragFrom(handleStart, const Offset(-50.0, 0.0));
      await tester.pumpAndSettle();
      final updatedEnd = controller.computeClipSpans().single.end;
      expect(updatedEnd, closeTo(initialEnd - 1.0, 0.15));
    },
  );

  testWidgets(
    'allows editing marker text, keystroke input, and terminal output',
    (tester) async {
      const castWithInputAndOutput = '''
{"version": 2, "width": 80, "height": 24}
[0.3, "i", "ls\\r"]
[0.6, "o", "file1\\r\\n"]
[1.0, "m", "OldMarker"]
''';
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = AsciicastEditorController(
        initialCastContent: castWithInputAndOutput,
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AsciicastEditor(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Double-tap marker pill on timeline to edit marker text
      final markerFinder = find.text('OldMarker');
      await tester.tap(markerFinder);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(markerFinder);
      await tester.pumpAndSettle();
      expect(find.text('编辑关键标记'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'NewMarker');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(controller.markers.single.label, 'NewMarker');

      // 2. Open Events/History tab, filter to input (i), and edit keystroke input
      await tester.tap(find.text('事件帧/历史'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('按键输入 (i)'));
      await tester.pumpAndSettle();
      final editBtn = find.byIcon(Icons.edit_note);
      expect(editBtn, findsOneWidget);
      await tester.tap(editBtn);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('编辑按键输入 (i)'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, r'pwd\r');
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(
        controller.clips.single.events.firstWhere((e) => e.type == 'i').data,
        'pwd\r',
      );

      // 3. Filter to output (o) and edit terminal output
      await tester.tap(find.text('终端输出 (o)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.edit_note).first);
      await tester.pumpAndSettle();
      expect(find.textContaining('编辑终端输出 (o)'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, r'/workspace\r\n');
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(
        controller.clips.single.events.firstWhere((e) => e.type == 'o').data,
        '/workspace\r\n',
      );
    },
  );

  test(
    'pure-Dart VirtualTerminal handles ANSI colors, cursor, alt screen, and wide chars',
    () {
      const ansiCast = '''
{"version": 2, "width": 20, "height": 5}
[0.1, "o", "\\u001b[31;1mHi\\u001b[0m 中文"]
[0.2, "o", "\\u001b[?1049hALT\\u001b[?1049l"]
[0.3, "o", "\\r\\n\\u001b[38;2;10;20;30mRGB\\u001b[K"]
''';
      final controller = AsciicastEditorController(
        initialCastContent: ansiCast,
      );
      addTearDown(controller.dispose);

      controller.jumpToFinalResult();
      final buf = controller.virtualTerminal.buffer;
      expect(buf.getCharacter(0, 0), 'H');
      expect(buf.getCharacter(1, 0), 'i');
      expect(buf.getCharacter(3, 0), '中');
      expect(buf.getCharacter(4, 0), '');
      expect(buf.getCharacter(5, 0), '文');
      expect(buf.getCharacter(0, 1), 'R');
      expect(buf.getForeground(0, 1), 0xFF0A141E);
      expect(controller.virtualTerminal.isUsingAlternateScreen, isFalse);
    },
  );
}
