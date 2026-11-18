import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:termui/termui.dart' as termui;
import 'package:termui_flutter/termui_flutter.dart';
import 'package:termui_pty/termui_pty.dart';

import 'models.dart';

class _HistorySnapshot {
  const _HistorySnapshot({
    required this.description,
    required this.header,
    required this.clips,
    required this.markers,
    required this.selectedClipId,
    required this.selectedMarkerId,
  });

  final String description;
  final AsciicastHeader header;
  final List<AsciicastClip> clips;
  final List<AsciicastMarker> markers;
  final String? selectedClipId;
  final String? selectedMarkerId;
}

/// Flattened timeline event after applying non-linear clip trims and speed scaling.
typedef BakedTimelineEvent = ({
  double timelineTime,
  String type,
  String data,
  String clipId,
  String eventId,
});

/// State and non-linear editing controller for `asciicast_editor`.
class AsciicastEditorController extends ChangeNotifier {
  AsciicastEditorController({
    AsciicastDocument? initialDocument,
    String? initialCastContent,
    String initialClipName = 'Main Clip',
  }) {
    final doc =
        initialDocument ??
        (initialCastContent != null && initialCastContent.trim().isNotEmpty
            ? AsciicastDocument.parse(
                initialCastContent,
                clipName: initialClipName,
              )
            : AsciicastDocument.sampleDemo());
    _loadDocumentInternal(doc, resetHistory: true);
  }

  static const List<int> _clipPalette = <int>[
    0xFF0EA5E9,
    0xFF6366F1,
    0xFF10B981,
    0xFFF59E0B,
    0xFFEC4899,
    0xFF8B5CF6,
    0xFF14B8A6,
  ];

  late AsciicastHeader _header;
  late List<AsciicastClip> _clips;
  late List<AsciicastMarker> _markers;
  List<BakedTimelineEvent> _bakedEvents = <BakedTimelineEvent>[];

  final VirtualTerminal virtualTerminal = VirtualTerminal(
    width: 80,
    height: 24,
  );
  final FlutterTerminal flutterTerminal = FlutterTerminal(
    initialFontSize: 13.0,
  );

  /// Callback invoked by `AsciicastTerminalPreview` whenever the terminal buffer is updated.
  void Function(termui.Buffer buffer)? onFrameRedrawn;

  double _playheadTime = 0.0;
  double _totalDuration = 0.0;
  bool _isPlaying = false;
  bool _isLooping = false;
  bool _pauseOnMarkers = true;
  double _playbackSpeed = 1.0;
  double _timelineZoom = 64.0; // pixels per second
  double _timelineViewportWidth = 600.0;
  NleToolMode _activeTool = NleToolMode.pointer;
  TerminalPreviewTheme _previewTheme = TerminalPreviewTheme.termuiDark;
  double _fontSize = 13.0;

  String? _selectedClipId;
  String? _selectedMarkerId;
  String? _pausedAtMarkerLabel;

  final List<_HistorySnapshot> _undoStack = <_HistorySnapshot>[];
  final List<_HistorySnapshot> _redoStack = <_HistorySnapshot>[];
  static const int _maxHistoryDepth = 50;

  int _idSequence = 100;
  int _lastBakedEventIndex = 0;
  double _lastRenderedPlayhead = -1.0;
  Timer? _playbackTimer;
  DateTime _lastTickTime = DateTime.now();
  bool _isDisposed = false;

  AsciicastHeader get header => _header;
  List<AsciicastClip> get clips => List<AsciicastClip>.unmodifiable(_clips);
  List<AsciicastMarker> get markers =>
      List<AsciicastMarker>.unmodifiable(_markers);
  List<BakedTimelineEvent> get bakedEvents =>
      List<BakedTimelineEvent>.unmodifiable(_bakedEvents);

  double get playheadTime => _playheadTime;
  double get totalDuration => _totalDuration;
  bool get isPlaying => _isPlaying;
  bool get isLooping => _isLooping;
  bool get pauseOnMarkers => _pauseOnMarkers;
  double get playbackSpeed => _playbackSpeed;
  double get timelineZoom => _timelineZoom;
  NleToolMode get activeTool => _activeTool;
  TerminalPreviewTheme get previewTheme => _previewTheme;
  double get fontSize => _fontSize;
  String? get selectedClipId => _selectedClipId;
  String? get selectedMarkerId => _selectedMarkerId;
  String? get pausedAtMarkerLabel => _pausedAtMarkerLabel;

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;
  List<String> get undoHistoryDescriptions =>
      _undoStack.map((s) => s.description).toList(growable: false);

  AsciicastClip? get selectedClip {
    if (_selectedClipId == null) return null;
    for (final clip in _clips) {
      if (clip.id == _selectedClipId) return clip;
    }
    return null;
  }

  AsciicastMarker? get selectedMarker {
    if (_selectedMarkerId == null) return null;
    for (final marker in _markers) {
      if (marker.id == _selectedMarkerId) return marker;
    }
    return null;
  }

  /// Loads raw `.cast` text into the editor.
  void loadCastString(String rawCast, {String clipName = 'Clip 01'}) {
    pause();
    final doc = AsciicastDocument.parse(rawCast, clipName: clipName);
    _loadDocumentInternal(doc, resetHistory: true);
    notifyListeners();
  }

  void _loadDocumentInternal(
    AsciicastDocument doc, {
    required bool resetHistory,
  }) {
    _header = doc.header;
    _clips = List<AsciicastClip>.from(doc.clips);
    _markers = List<AsciicastMarker>.from(doc.markers);
    _selectedClipId = _clips.isNotEmpty ? _clips.first.id : null;
    _selectedMarkerId = null;
    _pausedAtMarkerLabel = null;
    if (resetHistory) {
      _undoStack.clear();
      _redoStack.clear();
    }
    virtualTerminal.resize(_header.width, _header.height);
    flutterTerminal.updateSize(math.Point<int>(_header.width, _header.height));
    _rebuildBakedTimeline(targetPlayhead: 0.0);
  }

  /// Records an undo snapshot of the current editor state before a live drag mutation.
  void recordHistorySnapshot(String description) {
    _recordSnapshot(description);
  }

  void _recordSnapshot(String description) {
    _undoStack.add(
      _HistorySnapshot(
        description: description,
        header: _header.copyWith(),
        clips: _clips.map((c) => c.copyWith()).toList(),
        markers: _markers.map((m) => m.copyWith()).toList(),
        selectedClipId: _selectedClipId,
        selectedMarkerId: _selectedMarkerId,
      ),
    );
    if (_undoStack.length > _maxHistoryDepth) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  /// Undoes the last non-linear editing operation.
  void undo() {
    if (_undoStack.isEmpty) return;
    pause();
    _redoStack.add(
      _HistorySnapshot(
        description: _undoStack.last.description,
        header: _header.copyWith(),
        clips: _clips.map((c) => c.copyWith()).toList(),
        markers: _markers.map((m) => m.copyWith()).toList(),
        selectedClipId: _selectedClipId,
        selectedMarkerId: _selectedMarkerId,
      ),
    );
    final prev = _undoStack.removeLast();
    _applySnapshot(prev);
  }

  /// Redoes the last undone editing operation.
  void redo() {
    if (_redoStack.isEmpty) return;
    pause();
    final next = _redoStack.removeLast();
    _undoStack.add(
      _HistorySnapshot(
        description: next.description,
        header: _header.copyWith(),
        clips: _clips.map((c) => c.copyWith()).toList(),
        markers: _markers.map((m) => m.copyWith()).toList(),
        selectedClipId: _selectedClipId,
        selectedMarkerId: _selectedMarkerId,
      ),
    );
    _applySnapshot(next);
  }

  void _applySnapshot(_HistorySnapshot snapshot) {
    _header = snapshot.header;
    _clips = snapshot.clips.map((c) => c.copyWith()).toList();
    _markers = snapshot.markers.map((m) => m.copyWith()).toList();
    _selectedClipId = snapshot.selectedClipId;
    _selectedMarkerId = snapshot.selectedMarkerId;
    virtualTerminal.resize(_header.width, _header.height);
    flutterTerminal.updateSize(math.Point<int>(_header.width, _header.height));
    _rebuildBakedTimeline(targetPlayhead: _playheadTime);
    notifyListeners();
  }

  void _rebuildBakedTimeline({double? targetPlayhead}) {
    final baked = <BakedTimelineEvent>[];
    var cursorTime = 0.0;
    final idleLimit = _header.idleTimeLimit;

    for (final clip in _clips) {
      if (clip.muted) continue;
      final speed = clip.speed <= 0 ? 1.0 : clip.speed;
      var prevSourceTime = clip.sourceStart;
      var localTimelineOffset = 0.0;

      for (final ev in clip.trimmedEvents) {
        var delta = math.max(0.0, (ev.time - prevSourceTime) / speed);
        if (idleLimit != null && idleLimit > 0 && delta > idleLimit) {
          delta = idleLimit;
        }
        localTimelineOffset += delta;
        prevSourceTime = ev.time;

        baked.add((
          timelineTime: cursorTime + localTimelineOffset,
          type: ev.type,
          data: ev.data,
          clipId: clip.id,
          eventId: ev.id,
        ));
      }

      // Compute total clip duration accounting for idle time limit
      var remainingTail = math.max(
        0.0,
        (clip.sourceEnd - prevSourceTime) / speed,
      );
      if (idleLimit != null && idleLimit > 0 && remainingTail > idleLimit) {
        remainingTail = idleLimit;
      }
      cursorTime += localTimelineOffset + remainingTail;
    }

    _bakedEvents = baked;
    final maxMarkerTime = _markers.isEmpty
        ? 0.0
        : _markers.map((m) => m.time).reduce(math.max);
    _totalDuration = math.max(cursorTime, math.max(maxMarkerTime, 0.1));

    _lastRenderedPlayhead = -1.0;
    _lastBakedEventIndex = 0;
    final nextPlayhead = (targetPlayhead ?? _playheadTime).clamp(
      0.0,
      _totalDuration,
    );
    _renderAtTime(nextPlayhead, forceReset: true);
  }

  /// Computes the timeline start & end bounds `[start, end]` of each clip on track `T1`.
  List<({AsciicastClip clip, double start, double end})> computeClipSpans() {
    final spans = <({AsciicastClip clip, double start, double end})>[];
    var cursor = 0.0;
    final idleLimit = _header.idleTimeLimit;

    for (final clip in _clips) {
      final speed = clip.speed <= 0 ? 1.0 : clip.speed;
      var prevSourceTime = clip.sourceStart;
      var clipDuration = 0.0;

      for (final ev in clip.trimmedEvents) {
        var delta = math.max(0.0, (ev.time - prevSourceTime) / speed);
        if (idleLimit != null && idleLimit > 0 && delta > idleLimit) {
          delta = idleLimit;
        }
        clipDuration += delta;
        prevSourceTime = ev.time;
      }
      var tail = math.max(0.0, (clip.sourceEnd - prevSourceTime) / speed);
      if (idleLimit != null && idleLimit > 0 && tail > idleLimit) {
        tail = idleLimit;
      }
      clipDuration += tail;
      if (clipDuration < 0.05) {
        clipDuration = 0.05;
      }

      final start = cursor;
      final end = cursor + (clip.muted ? clipDuration : clipDuration);
      spans.add((clip: clip, start: start, end: end));
      cursor = end;
    }
    return spans;
  }

  void _clearVirtualTerminal() {
    virtualTerminal.reset();
    virtualTerminal.resize(_header.width, _header.height);
    virtualTerminal.buffer.fillAttributes(
      char: ' ',
      fg: 0,
      bg: 0,
      modifiers: termui.Modifier.none,
    );
    virtualTerminal.cursorX = 0;
    virtualTerminal.cursorY = 0;
  }

  void _renderAtTime(double targetTime, {bool forceReset = false}) {
    final clamped = targetTime.clamp(0.0, _totalDuration);
    if (forceReset ||
        _lastRenderedPlayhead < 0 ||
        clamped < _lastRenderedPlayhead) {
      _clearVirtualTerminal();
      _lastBakedEventIndex = 0;
    }

    while (_lastBakedEventIndex < _bakedEvents.length &&
        _bakedEvents[_lastBakedEventIndex].timelineTime <= clamped + 1e-6) {
      final ev = _bakedEvents[_lastBakedEventIndex];
      if (ev.type == 'o') {
        virtualTerminal.writeString(ev.data);
      } else if (ev.type == 'r') {
        final parts = ev.data.split('x');
        if (parts.length == 2) {
          final cols = int.tryParse(parts[0]);
          final rows = int.tryParse(parts[1]);
          if (cols != null && rows != null && cols > 0 && rows > 0) {
            virtualTerminal.resize(cols, rows);
          }
        }
      }
      _lastBakedEventIndex++;
    }

    _playheadTime = clamped;
    _lastRenderedPlayhead = clamped;
    _emitCurrentBuffer();
  }

  void _emitCurrentBuffer() {
    if (_isDisposed) return;
    final rendered = virtualTerminal.renderBuffer();
    onFrameRedrawn?.call(rendered);
  }

  /// Forces the current terminal frame to be dispatched to `termui_flutter`.
  void refreshPreviewFrame() {
    _emitCurrentBuffer();
  }

  // ==================== Transport & Playback ====================

  void togglePlay() {
    if (_isPlaying) {
      pause();
    } else {
      play();
    }
  }

  void play() {
    if (_totalDuration <= 0) return;
    if (_playheadTime >= _totalDuration - 1e-4) {
      _renderAtTime(0.0, forceReset: true);
    }
    _pausedAtMarkerLabel = null;
    _isPlaying = true;
    _startPlaybackTimer();
    notifyListeners();
  }

  void pause() {
    if (!_isPlaying && _playbackTimer == null) return;
    _isPlaying = false;
    _playbackTimer?.cancel();
    _playbackTimer = null;
    notifyListeners();
  }

  void seek(double timelineSeconds) {
    _pausedAtMarkerLabel = null;
    _renderAtTime(timelineSeconds);
    notifyListeners();
  }

  /// Jumps directly to the beginning (`00:00`).
  void jumpToStart() {
    pause();
    seek(0.0);
  }

  /// Jumps directly to the final frame (`100%`) to inspect the final terminal output.
  void jumpToFinalResult() {
    pause();
    _pausedAtMarkerLabel = null;
    _renderAtTime(_totalDuration);
    notifyListeners();
  }

  /// Steps forward one output event frame.
  void stepForwardFrame() {
    pause();
    if (_lastBakedEventIndex >= _bakedEvents.length) return;
    final nextEvent = _bakedEvents[_lastBakedEventIndex];
    _renderAtTime(nextEvent.timelineTime);
    notifyListeners();
  }

  /// Steps backward one output event frame.
  void stepBackwardFrame() {
    pause();
    if (_bakedEvents.isEmpty || _lastBakedEventIndex <= 1) {
      seek(0.0);
      return;
    }
    final targetIdx = (_lastBakedEventIndex - 2).clamp(
      0,
      _bakedEvents.length - 1,
    );
    _renderAtTime(_bakedEvents[targetIdx].timelineTime, forceReset: true);
    notifyListeners();
  }

  void setPlaybackSpeed(double speed) {
    _playbackSpeed = speed.clamp(0.25, 8.0);
    notifyListeners();
  }

  void setLooping(bool loop) {
    _isLooping = loop;
    notifyListeners();
  }

  void setPauseOnMarkers(bool value) {
    _pauseOnMarkers = value;
    if (!value) {
      _pausedAtMarkerLabel = null;
    }
    notifyListeners();
  }

  void setActiveTool(NleToolMode tool) {
    if (_activeTool == tool) return;
    _activeTool = tool;
    notifyListeners();
  }

  void setTimelineZoom(double pixelsPerSecond) {
    _timelineZoom = pixelsPerSecond.clamp(16.0, 400.0);
    notifyListeners();
  }

  /// Updates the last measured timeline viewport width without triggering a rebuild.
  void updateTimelineViewportWidth(double width) {
    if (width.isFinite && width > 0) {
      _timelineViewportWidth = width;
    }
  }

  /// Fits the entire timeline duration into the current viewport width (DaVinci Shift+Z).
  void fitTimelineToViewport() {
    if (_timelineViewportWidth <= 0) return;
    final targetDuration = math.max(_totalDuration + 1.0, 1.0);
    setTimelineZoom(_timelineViewportWidth / targetDuration);
  }

  /// DaVinci Resolve `L` shuttle: starts playback or steps up forward speed.
  void shuttleForward() {
    if (!_isPlaying) {
      play();
      return;
    }
    const speeds = <double>[0.5, 1.0, 1.5, 2.0, 4.0];
    final next = speeds.firstWhere(
      (s) => s > _playbackSpeed + 0.05,
      orElse: () => speeds.last,
    );
    setPlaybackSpeed(next);
  }

  /// DaVinci Resolve `J` shuttle: pauses and steps backward 1 second.
  void shuttleBackward({double stepSeconds = 1.0}) {
    pause();
    seek(_playheadTime - stepSeconds);
  }

  /// Jumps playhead to the previous clip boundary / edit point (DaVinci Up Arrow).
  void jumpToPrevEditPoint() {
    final boundaries = <double>{0.0, _totalDuration};
    for (final span in computeClipSpans()) {
      boundaries.add(span.start);
      boundaries.add(span.end);
    }
    final sorted = boundaries.toList()..sort();
    for (var i = sorted.length - 1; i >= 0; i--) {
      if (sorted[i] < _playheadTime - 0.05) {
        seek(sorted[i]);
        return;
      }
    }
  }

  /// Jumps playhead to the next clip boundary / edit point (DaVinci Down Arrow).
  void jumpToNextEditPoint() {
    final boundaries = <double>{0.0, _totalDuration};
    for (final span in computeClipSpans()) {
      boundaries.add(span.start);
      boundaries.add(span.end);
    }
    final sorted = boundaries.toList()..sort();
    for (final t in sorted) {
      if (t > _playheadTime + 0.05) {
        seek(t);
        return;
      }
    }
  }

  void setPreviewTheme(TerminalPreviewTheme theme) {
    if (_previewTheme == theme) return;
    _previewTheme = theme;
    notifyListeners();
    _emitCurrentBuffer();
  }

  void setFontSize(double size) {
    final clamped = size.clamp(8.0, 28.0);
    if (_fontSize == clamped) return;
    _fontSize = clamped;
    flutterTerminal.setFontSize(clamped);
    notifyListeners();
  }

  void selectClip(String? clipId) {
    if (_selectedClipId == clipId) return;
    _selectedClipId = clipId;
    notifyListeners();
  }

  void selectMarker(String? markerId) {
    if (_selectedMarkerId == markerId) return;
    _selectedMarkerId = markerId;
    notifyListeners();
  }

  void _startPlaybackTimer() {
    _playbackTimer?.cancel();
    _lastTickTime = DateTime.now();
    _playbackTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (!_isPlaying || _isDisposed) {
        timer.cancel();
        return;
      }
      final now = DateTime.now();
      final elapsedSec = now.difference(_lastTickTime).inMicroseconds / 1e6;
      _lastTickTime = now;

      final prevTime = _playheadTime;
      final nextTime = prevTime + elapsedSec * _playbackSpeed;

      if (_pauseOnMarkers && _markers.isNotEmpty) {
        for (final marker in _markers) {
          if (marker.time > prevTime + 1e-4 && marker.time <= nextTime + 1e-4) {
            _renderAtTime(marker.time);
            _pausedAtMarkerLabel = marker.label;
            _selectedMarkerId = marker.id;
            pause();
            return;
          }
        }
      }

      if (nextTime >= _totalDuration) {
        if (_isLooping && _totalDuration > 0) {
          _renderAtTime(0.0, forceReset: true);
          notifyListeners();
        } else {
          _renderAtTime(_totalDuration);
          pause();
        }
        return;
      }

      _renderAtTime(nextTime);
      notifyListeners();
    });
  }

  // ==================== NLE Clip & Timeline Operations ====================

  String _nextId(String prefix) => '${prefix}_${++_idSequence}';

  /// Splits the clip at [timelineTime] into two independent clips (Razor / Blade cut).
  bool splitClipAt(double timelineTime, {String? clipId}) {
    final spans = computeClipSpans();
    for (var i = 0; i < spans.length; i++) {
      final span = spans[i];
      if (clipId != null && span.clip.id != clipId) continue;
      if (timelineTime <= span.start + 0.05 ||
          timelineTime >= span.end - 0.05) {
        continue;
      }

      final ratio =
          (timelineTime - span.start) / math.max(0.001, span.end - span.start);
      final splitSourceTime =
          span.clip.sourceStart + ratio * span.clip.sourceDuration;
      if (splitSourceTime <= span.clip.sourceStart + 0.02 ||
          splitSourceTime >= span.clip.sourceEnd - 0.02) {
        return false;
      }

      _recordSnapshot('剃刀切割片段 "${span.clip.name}"');
      final leftClip = span.clip.copyWith(
        id: _nextId('clip'),
        name: '${span.clip.name} (A)',
        sourceEnd: splitSourceTime,
      );
      final rightClip = span.clip.copyWith(
        id: _nextId('clip'),
        name: '${span.clip.name} (B)',
        sourceStart: splitSourceTime,
        colorValue: _clipPalette[(_clips.length + 1) % _clipPalette.length],
      );

      _clips.replaceRange(i, i + 1, <AsciicastClip>[leftClip, rightClip]);
      _selectedClipId = rightClip.id;
      _rebuildBakedTimeline(targetPlayhead: timelineTime);
      notifyListeners();
      return true;
    }
    return false;
  }

  /// Splits the clip under the current playhead (`Ctrl+B` / `Ctrl+K`).
  bool splitAtPlayhead() => splitClipAt(_playheadTime);

  /// Automatically slices clips on the timeline by output lines or input events.
  ///
  /// Returns the number of newly created clips (0 if no valid cut points were found).
  int autoSliceClips({
    required AutoSliceMode mode,
    String? clipId,
    double minClipDuration = 0.25,
  }) {
    final safeMinTimelineGap = math.max(0.02, minClipDuration);
    final nextClips = <AsciicastClip>[];
    var addedClips = 0;
    var colorIdx = _clips.length;
    var hasAnySlice = false;

    for (final clip in _clips) {
      if (clipId != null && clip.id != clipId) {
        nextClips.add(clip);
        continue;
      }

      final speed = clip.speed <= 0 ? 1.0 : clip.speed;
      final minSourceGap = safeMinTimelineGap * speed;
      final cutPoints = <double>[];
      var lastCut = clip.sourceStart;

      for (final ev in clip.trimmedEvents) {
        final isMatch = switch (mode) {
          AutoSliceMode.byLine => ev.type == 'o' && ev.data.contains('\n'),
          AutoSliceMode.byInput => ev.type == 'i',
        };
        if (!isMatch) continue;

        // Cut just after newline output (so the newline stays with its line),
        // or just before input (so the input starts the new clip).
        final candidate = mode == AutoSliceMode.byLine
            ? ev.time + 1e-4
            : ev.time - 1e-4;
        if (candidate - lastCut < minSourceGap) continue;
        if (clip.sourceEnd - candidate < minSourceGap) continue;

        cutPoints.add(candidate);
        lastCut = candidate;
      }

      if (cutPoints.isEmpty) {
        nextClips.add(clip);
        continue;
      }

      hasAnySlice = true;
      final boundaries = <double>[
        clip.sourceStart,
        ...cutPoints,
        clip.sourceEnd,
      ];
      for (var i = 0; i < boundaries.length - 1; i++) {
        nextClips.add(
          clip.copyWith(
            id: _nextId('clip'),
            name: '${clip.name} #${i + 1}',
            sourceStart: boundaries[i],
            sourceEnd: boundaries[i + 1],
            colorValue: i == 0
                ? clip.colorValue
                : _clipPalette[(colorIdx++) % _clipPalette.length],
          ),
        );
      }
      addedClips += boundaries.length - 2;
    }

    if (!hasAnySlice) return 0;

    final modeLabel = mode == AutoSliceMode.byLine ? '按行' : '按输入';
    _recordSnapshot('自动切片 ($modeLabel，新增 $addedClips 个片段)');
    _clips = nextClips;
    if (_selectedClipId == null ||
        !_clips.any((c) => c.id == _selectedClipId)) {
      _selectedClipId = _clips.isNotEmpty ? _clips.first.id : null;
    }
    _rebuildBakedTimeline(targetPlayhead: _playheadTime);
    notifyListeners();
    return addedClips;
  }

  /// Trims the In-point (`newSourceStart`) and/or Out-point (`newSourceEnd`) of a clip.
  void trimClip(
    String clipId, {
    double? newSourceStart,
    double? newSourceEnd,
    bool recordHistory = true,
  }) {
    final index = _clips.indexWhere((c) => c.id == clipId);
    if (index < 0) return;
    final clip = _clips[index];
    final maxPossible = clip.events.isEmpty
        ? clip.sourceEnd
        : math.max(clip.sourceEnd, clip.events.last.time);
    final start = (newSourceStart ?? clip.sourceStart)
        .clamp(0.0, clip.sourceEnd - 0.05)
        .toDouble();
    final end = (newSourceEnd ?? clip.sourceEnd)
        .clamp(start + 0.05, math.max(start + 0.05, maxPossible + 10.0))
        .toDouble();

    if ((start - clip.sourceStart).abs() < 1e-4 &&
        (end - clip.sourceEnd).abs() < 1e-4) {
      return;
    }

    if (recordHistory) {
      _recordSnapshot('裁剪片段 "${clip.name}" 入出点');
    }
    _clips[index] = clip.copyWith(sourceStart: start, sourceEnd: end);
    _rebuildBakedTimeline(targetPlayhead: _playheadTime);
    notifyListeners();
  }

  /// Trims a clip's In-point or Out-point by an exact timeline-seconds delta
  /// from its pre-drag state, accounting for clip `speed` and `idleTimeLimit`
  /// so visual drag distance matches pointer movement 1:1.
  void trimClipByTimelineDelta({
    required String clipId,
    required double initialSourceStart,
    required double initialSourceEnd,
    required double initialTimelineDuration,
    required double deltaTimelineSeconds,
    required bool trimStart,
  }) {
    final index = _clips.indexWhere((c) => c.id == clipId);
    if (index < 0) return;
    final clip = _clips[index];
    final speed = clip.speed <= 0 ? 1.0 : clip.speed;
    final idleLimit = _header.idleTimeLimit;

    if (!trimStart) {
      final targetDuration = math.max(
        0.05,
        initialTimelineDuration + deltaTimelineSeconds,
      );
      var prevSource = initialSourceStart;
      var accDuration = 0.0;
      double? resolvedEnd;

      for (final ev in clip.events) {
        if (ev.time < initialSourceStart - 1e-6) continue;
        final rawStep = math.max(0.0, (ev.time - prevSource) / speed);
        final cappedStep = (idleLimit != null && idleLimit > 0)
            ? math.min(rawStep, idleLimit)
            : rawStep;
        if (accDuration + cappedStep >= targetDuration) {
          final neededTimeline = math.max(0.0, targetDuration - accDuration);
          resolvedEnd = prevSource + neededTimeline * speed;
          break;
        }
        accDuration += cappedStep;
        prevSource = ev.time;
      }

      if (resolvedEnd == null) {
        var neededTimeline = math.max(0.0, targetDuration - accDuration);
        if (idleLimit != null && idleLimit > 0) {
          neededTimeline = math.min(neededTimeline, idleLimit);
        }
        resolvedEnd = prevSource + neededTimeline * speed;
      }

      trimClip(
        clipId,
        newSourceStart: initialSourceStart,
        newSourceEnd: resolvedEnd,
        recordHistory: false,
      );
    } else {
      final targetDuration = math.max(
        0.05,
        initialTimelineDuration - deltaTimelineSeconds,
      );
      var prevSource = initialSourceEnd;
      var accDuration = 0.0;
      double? resolvedStart;

      for (var i = clip.events.length - 1; i >= 0; i--) {
        final ev = clip.events[i];
        if (ev.time > initialSourceEnd + 1e-6) continue;
        final rawStep = math.max(0.0, (prevSource - ev.time) / speed);
        final cappedStep = (idleLimit != null && idleLimit > 0)
            ? math.min(rawStep, idleLimit)
            : rawStep;
        if (accDuration + cappedStep >= targetDuration) {
          final neededTimeline = math.max(0.0, targetDuration - accDuration);
          resolvedStart = prevSource - neededTimeline * speed;
          break;
        }
        accDuration += cappedStep;
        prevSource = ev.time;
      }

      if (resolvedStart == null) {
        var neededTimeline = math.max(0.0, targetDuration - accDuration);
        if (idleLimit != null && idleLimit > 0) {
          neededTimeline = math.min(neededTimeline, idleLimit);
        }
        resolvedStart = math.max(0.0, prevSource - neededTimeline * speed);
      }

      trimClip(
        clipId,
        newSourceStart: resolvedStart,
        newSourceEnd: initialSourceEnd,
        recordHistory: false,
      );
    }
  }

  /// Ripple-deletes a clip from the timeline and shifts subsequent markers if `ripple` is true.
  bool deleteClip(String clipId, {bool ripple = true}) {
    if (_clips.length <= 1) return false;
    final spans = computeClipSpans();
    final idx = spans.indexWhere((s) => s.clip.id == clipId);
    if (idx < 0) return false;

    final removedSpan = spans[idx];
    final removedDuration = removedSpan.end - removedSpan.start;
    _recordSnapshot('波纹删除片段 "${removedSpan.clip.name}"');

    _clips.removeAt(idx);
    if (ripple && removedDuration > 0) {
      _markers = _markers
          .where((m) => m.time < removedSpan.start || m.time > removedSpan.end)
          .map(
            (m) => m.time > removedSpan.end
                ? m.copyWith(time: math.max(0.0, m.time - removedDuration))
                : m,
          )
          .toList();
    }
    if (_selectedClipId == clipId) {
      _selectedClipId = _clips.isNotEmpty ? _clips.first.id : null;
    }
    _rebuildBakedTimeline(targetPlayhead: removedSpan.start);
    notifyListeners();
    return true;
  }

  /// Updates the speed multiplier of a specific clip.
  void setClipSpeed(String clipId, double speed) {
    final index = _clips.indexWhere((c) => c.id == clipId);
    if (index < 0) return;
    final clamped = speed.clamp(0.25, 8.0);
    if ((_clips[index].speed - clamped).abs() < 1e-3) return;
    _recordSnapshot('调整片段 "${_clips[index].name}" 倍速为 ${clamped}x');
    _clips[index] = _clips[index].copyWith(speed: clamped);
    _rebuildBakedTimeline(targetPlayhead: _playheadTime);
    notifyListeners();
  }

  /// Toggles whether a clip is muted (disabled) on the timeline.
  void toggleClipMuted(String clipId) {
    final index = _clips.indexWhere((c) => c.id == clipId);
    if (index < 0) return;
    final nextMuted = !_clips[index].muted;
    _recordSnapshot('${nextMuted ? "禁用" : "启用"}片段 "${_clips[index].name}"');
    _clips[index] = _clips[index].copyWith(muted: nextMuted);
    _rebuildBakedTimeline(targetPlayhead: _playheadTime);
    notifyListeners();
  }

  /// Renames a clip.
  void renameClip(String clipId, String newName) {
    final index = _clips.indexWhere((c) => c.id == clipId);
    if (index < 0 || newName.trim().isEmpty) return;
    _recordSnapshot('重命名片段为 "${newName.trim()}"');
    _clips[index] = _clips[index].copyWith(name: newName.trim());
    notifyListeners();
  }

  /// Reorders clips on the timeline.
  void moveClip(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _clips.length ||
        newIndex < 0 ||
        newIndex >= _clips.length ||
        oldIndex == newIndex) {
      return;
    }
    _recordSnapshot('调整片段顺序');
    final item = _clips.removeAt(oldIndex);
    _clips.insert(newIndex, item);
    _rebuildBakedTimeline(targetPlayhead: _playheadTime);
    notifyListeners();
  }

  // ==================== Marker Management ====================

  AsciicastMarker addMarkerAtPlayhead([String label = '关键命令标记']) {
    return addMarker(_playheadTime, label);
  }

  AsciicastMarker addMarker(double time, String label) {
    final cleanLabel = label.trim().isEmpty ? '关键命令标记' : label.trim();
    final clampedTime = time.clamp(0.0, _totalDuration);
    _recordSnapshot('添加标记 "$cleanLabel"');
    final marker = AsciicastMarker(
      id: _nextId('marker'),
      time: clampedTime,
      label: cleanLabel,
    );
    _markers.add(marker);
    _markers.sort((a, b) => a.time.compareTo(b.time));
    _selectedMarkerId = marker.id;
    notifyListeners();
    return marker;
  }

  void updateMarker(
    String id, {
    double? time,
    String? label,
    bool recordHistory = true,
  }) {
    final idx = _markers.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    if (recordHistory) {
      _recordSnapshot('更新标记 "${_markers[idx].label}"');
    }
    _markers[idx] = _markers[idx].copyWith(
      time: time?.clamp(0.0, _totalDuration).toDouble(),
      label: label?.trim(),
    );
    _markers.sort((a, b) => a.time.compareTo(b.time));
    notifyListeners();
  }

  void deleteMarker(String id) {
    final idx = _markers.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    _recordSnapshot('删除标记 "${_markers[idx].label}"');
    _markers.removeAt(idx);
    if (_selectedMarkerId == id) {
      _selectedMarkerId = null;
    }
    notifyListeners();
  }

  void jumpToNextMarker() {
    for (final marker in _markers) {
      if (marker.time > _playheadTime + 0.05) {
        _selectedMarkerId = marker.id;
        seek(marker.time);
        return;
      }
    }
  }

  void jumpToPrevMarker() {
    for (var i = _markers.length - 1; i >= 0; i--) {
      if (_markers[i].time < _playheadTime - 0.05) {
        _selectedMarkerId = _markers[i].id;
        seek(_markers[i].time);
        return;
      }
    }
  }

  // ==================== Batch Processing & Redaction ====================

  /// Permanently compresses pauses longer than [maxIdleSeconds] inside the source events.
  void compressIdleTime({double maxIdleSeconds = 2.0, String? clipId}) {
    final limit = math.max(0.1, maxIdleSeconds);
    _recordSnapshot('压缩空闲等待 (上限 ${limit.toStringAsFixed(1)}s)');

    for (var i = 0; i < _clips.length; i++) {
      final clip = _clips[i];
      if (clipId != null && clip.id != clipId) continue;
      if (clip.events.isEmpty) continue;

      final updatedEvents = <AsciicastEvent>[];
      var prevOriginal = clip.sourceStart;
      var currentNewTime = clip.sourceStart;

      for (final ev in clip.events) {
        if (ev.time < clip.sourceStart) {
          updatedEvents.add(ev);
          continue;
        }
        final delta = math.max(0.0, ev.time - prevOriginal);
        final compressedDelta = math.min(delta, limit);
        currentNewTime += compressedDelta;
        prevOriginal = ev.time;
        updatedEvents.add(ev.copyWith(time: currentNewTime));
      }

      final tail = math.min(
        math.max(0.0, clip.sourceEnd - prevOriginal),
        limit,
      );
      _clips[i] = clip.copyWith(
        events: updatedEvents,
        sourceEnd: math.max(clip.sourceStart + 0.05, currentNewTime + tail),
      );
    }

    _header = _header.copyWith(idleTimeLimit: limit);
    _rebuildBakedTimeline(targetPlayhead: 0.0);
    notifyListeners();
  }

  /// Redacts or replaces text across terminal output events (e.g. hiding passwords, tokens, IPs).
  int redactText({
    required String pattern,
    required String replacement,
    bool useRegex = false,
    String? clipId,
  }) {
    if (pattern.isEmpty) return 0;
    final Pattern matcher = useRegex ? RegExp(pattern) : pattern;
    var matchCount = 0;

    final nextClips = <AsciicastClip>[];
    for (final clip in _clips) {
      if (clipId != null && clip.id != clipId) {
        nextClips.add(clip);
        continue;
      }
      final nextEvents = <AsciicastEvent>[];
      for (final ev in clip.events) {
        if (ev.type == 'o' || ev.type == 'i') {
          final matches = matcher.allMatches(ev.data).length;
          if (matches > 0) {
            matchCount += matches;
            nextEvents.add(
              ev.copyWith(data: ev.data.replaceAll(matcher, replacement)),
            );
            continue;
          }
        }
        nextEvents.add(ev);
      }
      nextClips.add(clip.copyWith(events: nextEvents));
    }

    if (matchCount > 0) {
      _recordSnapshot('敏感内容替换/打码 ($matchCount 处)');
      _clips = nextClips;
      _rebuildBakedTimeline(targetPlayhead: _playheadTime);
      notifyListeners();
    }
    return matchCount;
  }

  /// Updates a single raw event's data or timestamp.
  void updateRawEvent({
    required String clipId,
    required String eventId,
    String? newData,
    double? newTime,
  }) {
    final clipIdx = _clips.indexWhere((c) => c.id == clipId);
    if (clipIdx < 0) return;
    final clip = _clips[clipIdx];
    final evIdx = clip.events.indexWhere((e) => e.id == eventId);
    if (evIdx < 0) return;

    _recordSnapshot('编辑事件帧 #$eventId');
    final updatedEvents = List<AsciicastEvent>.from(clip.events);
    updatedEvents[evIdx] = updatedEvents[evIdx].copyWith(
      data: newData,
      time: newTime,
    );
    updatedEvents.sort((a, b) => a.time.compareTo(b.time));
    _clips[clipIdx] = clip.copyWith(events: updatedEvents);
    _rebuildBakedTimeline(targetPlayhead: _playheadTime);
    notifyListeners();
  }

  /// Deletes a single raw event (`o` or `i`) from a clip.
  void deleteRawEvent({required String clipId, required String eventId}) {
    final clipIdx = _clips.indexWhere((c) => c.id == clipId);
    if (clipIdx < 0) return;
    final clip = _clips[clipIdx];
    final evIdx = clip.events.indexWhere((e) => e.id == eventId);
    if (evIdx < 0) return;

    _recordSnapshot('删除事件帧 #$eventId');
    final updatedEvents = List<AsciicastEvent>.from(clip.events)
      ..removeAt(evIdx);
    _clips[clipIdx] = clip.copyWith(events: updatedEvents);
    _rebuildBakedTimeline(targetPlayhead: _playheadTime);
    notifyListeners();
  }

  /// Updates header metadata (`width`, `height`, `idleTimeLimit`, `title`, `version`).
  void updateHeader({
    int? width,
    int? height,
    double? idleTimeLimit,
    String? title,
    int? version,
  }) {
    _recordSnapshot('更新录屏头部配置');
    _header = _header.copyWith(
      width: width,
      height: height,
      idleTimeLimit: idleTimeLimit,
      title: title,
      version: version,
    );
    virtualTerminal.resize(_header.width, _header.height);
    flutterTerminal.updateSize(math.Point<int>(_header.width, _header.height));
    _rebuildBakedTimeline(targetPlayhead: _playheadTime);
    notifyListeners();
  }

  // ==================== Export to .cast ====================

  /// Serializes the edited non-linear timeline and markers into a standard `.cast` (v2 or v3) JSONL string.
  String exportCast({int? versionOverride}) {
    final targetVersion = versionOverride ?? _header.version;
    final lines = <String>[
      jsonEncode(_header.toJsonMap(forceVersion: targetVersion)),
    ];

    final combined = <({double time, String type, String data})>[
      for (final ev in _bakedEvents)
        (time: ev.timelineTime, type: ev.type, data: ev.data),
      for (final marker in _markers)
        (time: marker.time, type: 'm', data: marker.label),
    ]..sort((a, b) => a.time.compareTo(b.time));

    var prevTime = 0.0;
    for (final item in combined) {
      final rawTime = targetVersion == 3
          ? math.max(0.0, item.time - prevTime)
          : math.max(0.0, item.time);
      prevTime = item.time;
      final roundedTime = double.parse(rawTime.toStringAsFixed(6));
      lines.add(jsonEncode(<Object>[roundedTime, item.type, item.data]));
    }

    return '${lines.join('\n')}\n';
  }

  @override
  void dispose() {
    _isDisposed = true;
    _playbackTimer?.cancel();
    flutterTerminal.dispose();
    virtualTerminal.dispose();
    super.dispose();
  }
}
