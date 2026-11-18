import 'package:asciicast_editor/asciicast_editor.dart';
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
}
