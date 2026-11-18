import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'controller.dart';
import 'models.dart';

/// Multi-track NLE timeline widget inspired by Premiere Pro, DaVinci Resolve, and Kdenlive.
class AsciicastTimelinePanel extends StatefulWidget {
  const AsciicastTimelinePanel({super.key, required this.controller});

  final AsciicastEditorController controller;

  @override
  State<AsciicastTimelinePanel> createState() => _AsciicastTimelinePanelState();
}

class _AsciicastTimelinePanelState extends State<AsciicastTimelinePanel> {
  final ScrollController _horizontalScroll = ScrollController();
  double? _hoverRazorTime;

  static const double _trackHeaderWidth = 148.0;
  static const double _rulerHeight = 28.0;
  static const double _markerTrackHeight = 34.0;
  static const double _clipTrackHeight = 68.0;
  static const double _inputTrackHeight = 32.0;

  @override
  void dispose() {
    _horizontalScroll.dispose();
    super.dispose();
  }

  double _xToTime(double dx) {
    final zoom = widget.controller.timelineZoom;
    return math.max(0.0, dx / zoom);
  }

  double _timeToX(double time) {
    return time * widget.controller.timelineZoom;
  }

  void _scrubAtLocalDx(double dx) {
    final targetTime = _xToTime(dx);
    widget.controller.seek(targetTime);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final ctrl = widget.controller;
        final totalSeconds = math.max(ctrl.totalDuration + 3.0, 10.0);
        final canvasWidth = math.max(600.0, totalSeconds * ctrl.timelineZoom);
        final clipSpans = ctrl.computeClipSpans();
        final inputEvents = ctrl.bakedEvents
            .where((e) => e.type == 'i')
            .toList(growable: false);

        return Container(
          color: const Color(0xFF12151E),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left Track Headers Column
              SizedBox(
                width: _trackHeaderWidth,
                child: Column(
                  children: [
                    _buildRulerCornerHeader(ctrl),
                    _buildTrackHeader(
                      code: 'M1',
                      title: '标记轨 (Markers)',
                      height: _markerTrackHeight,
                      accentColor: const Color(0xFFF59E0B),
                      trailing: IconButton(
                        icon: const Icon(
                          Icons.add_location_alt_outlined,
                          size: 15,
                          color: Color(0xFFF59E0B),
                        ),
                        tooltip: '在播放头处打标记 (M)',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                        ),
                        onPressed: () => ctrl.addMarkerAtPlayhead(),
                      ),
                    ),
                    _buildTrackHeader(
                      code: 'T1',
                      title: '终端输出轨',
                      height: _clipTrackHeight,
                      accentColor: const Color(0xFF0EA5E9),
                      trailing: Text(
                        '${ctrl.clips.length} 片段',
                        style: const TextStyle(
                          color: Color(0xFF64748B),
                          fontSize: 10,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    _buildTrackHeader(
                      code: 'I1',
                      title: '按键输入轨',
                      height: _inputTrackHeight,
                      accentColor: const Color(0xFF10B981),
                      trailing: Text(
                        '${inputEvents.length}',
                        style: const TextStyle(
                          color: Color(0xFF64748B),
                          fontSize: 10,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1, color: Color(0xFF262B38)),
              // Right Scrollable Multi-Track Timeline Area
              Expanded(
                child: Scrollbar(
                  controller: _horizontalScroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _horizontalScroll,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: canvasWidth,
                      child: Stack(
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // 1. Time Ruler
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapDown: (d) =>
                                    _scrubAtLocalDx(d.localPosition.dx),
                                onHorizontalDragUpdate: (d) =>
                                    _scrubAtLocalDx(d.localPosition.dx),
                                child: SizedBox(
                                  height: _rulerHeight,
                                  width: canvasWidth,
                                  child: CustomPaint(
                                    painter: _TimeRulerPainter(
                                      zoom: ctrl.timelineZoom,
                                      totalDuration: ctrl.totalDuration,
                                      playheadTime: ctrl.playheadTime,
                                    ),
                                  ),
                                ),
                              ),
                              // 2. M1 Marker Track
                              _buildMarkerTrack(ctrl, canvasWidth),
                              // 3. T1 Clip Track
                              _buildClipTrack(ctrl, clipSpans, canvasWidth),
                              // 4. I1 Input Track
                              _buildInputTrack(ctrl, inputEvents, canvasWidth),
                            ],
                          ),
                          // Razor hover guide line
                          if (ctrl.activeTool == NleToolMode.razor &&
                              _hoverRazorTime != null)
                            Positioned(
                              left: _timeToX(_hoverRazorTime!),
                              top: _rulerHeight,
                              bottom: 0,
                              child: IgnorePointer(
                                child: Container(
                                  width: 1.5,
                                  color: const Color(0xFFF43F5E),
                                ),
                              ),
                            ),
                          // Red Playhead (CTI) Line spanning all tracks
                          Positioned(
                            left: (_timeToX(ctrl.playheadTime) - 6).clamp(
                              0.0,
                              canvasWidth - 12,
                            ),
                            top: 0,
                            bottom: 0,
                            child: IgnorePointer(
                              child: SizedBox(
                                width: 12,
                                child: CustomPaint(painter: _PlayheadPainter()),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRulerCornerHeader(AsciicastEditorController ctrl) {
    return Container(
      height: _rulerHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF181C26),
        border: Border(bottom: BorderSide(color: Color(0xFF262B38))),
      ),
      child: Row(
        children: [
          const Icon(Icons.schedule, size: 13, color: Color(0xFF94A3B8)),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              _formatSmpte(ctrl.playheadTime),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF38BDF8),
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '${ctrl.timelineZoom.round()}px/s',
            style: const TextStyle(
              color: Color(0xFF64748B),
              fontSize: 9,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackHeader({
    required String code,
    required String title,
    required double height,
    required Color accentColor,
    Widget? trailing,
  }) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF161A24),
        border: Border(bottom: BorderSide(color: Color(0xFF262B38))),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: accentColor.withValues(alpha: 0.45)),
            ),
            child: Text(
              code,
              style: TextStyle(
                color: accentColor,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: Color(0xFFCBD5E1),
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  Widget _buildMarkerTrack(AsciicastEditorController ctrl, double canvasWidth) {
    return Container(
      height: _markerTrackHeight,
      width: canvasWidth,
      decoration: const BoxDecoration(
        color: Color(0xFF141821),
        border: Border(bottom: BorderSide(color: Color(0xFF262B38))),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final marker in ctrl.markers)
            Positioned(
              left: _timeToX(marker.time),
              top: 4,
              child: GestureDetector(
                onTap: () {
                  ctrl.selectMarker(marker.id);
                  ctrl.seek(marker.time);
                },
                onHorizontalDragEnd: (_) {
                  ctrl.updateMarker(
                    marker.id,
                    time: marker.time,
                    recordHistory: true,
                  );
                },
                onHorizontalDragUpdate: (d) {
                  final nextTime = marker.time + d.delta.dx / ctrl.timelineZoom;
                  ctrl.updateMarker(
                    marker.id,
                    time: nextTime,
                    recordHistory: false,
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: ctrl.selectedMarkerId == marker.id
                        ? const Color(0xFFF59E0B)
                        : const Color(0xFF78350F).withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: const Color(0xFFFBBF24),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.flag,
                        size: 11,
                        color: ctrl.selectedMarkerId == marker.id
                            ? Colors.black
                            : const Color(0xFFFDE68A),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        marker.label,
                        style: TextStyle(
                          color: ctrl.selectedMarkerId == marker.id
                              ? Colors.black
                              : const Color(0xFFFEF3C7),
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildClipTrack(
    AsciicastEditorController ctrl,
    List<({AsciicastClip clip, double start, double end})> spans,
    double canvasWidth,
  ) {
    final isRazor = ctrl.activeTool == NleToolMode.razor;
    return MouseRegion(
      cursor: isRazor ? SystemMouseCursors.precise : SystemMouseCursors.basic,
      onHover: (event) {
        if (!isRazor) {
          if (_hoverRazorTime != null) {
            setState(() => _hoverRazorTime = null);
          }
          return;
        }
        setState(() => _hoverRazorTime = _xToTime(event.localPosition.dx));
      },
      onExit: (_) {
        if (_hoverRazorTime != null) {
          setState(() => _hoverRazorTime = null);
        }
      },
      child: Container(
        height: _clipTrackHeight,
        width: canvasWidth,
        decoration: const BoxDecoration(
          color: Color(0xFF10131B),
          border: Border(bottom: BorderSide(color: Color(0xFF262B38))),
        ),
        child: Stack(
          children: [for (final span in spans) _buildClipItem(ctrl, span)],
        ),
      ),
    );
  }

  Widget _buildClipItem(
    AsciicastEditorController ctrl,
    ({AsciicastClip clip, double start, double end}) span,
  ) {
    final clip = span.clip;
    final left = _timeToX(span.start);
    final width = math.max(24.0, _timeToX(span.end - span.start));
    final isSelected = ctrl.selectedClipId == clip.id;
    final baseColor = Color(clip.colorValue);
    final bucketCount = (width / 6).round().clamp(6, 160);
    final waveform = clip.computeActivityWaveform(bucketCount);

    return Positioned(
      left: left,
      top: 4,
      bottom: 4,
      width: width,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          if (ctrl.activeTool == NleToolMode.razor) {
            final clickTime =
                span.start + details.localPosition.dx / ctrl.timelineZoom;
            ctrl.splitClipAt(clickTime, clipId: clip.id);
          } else {
            ctrl.selectClip(clip.id);
          }
        },
        child: Container(
          decoration: BoxDecoration(
            color: clip.muted
                ? const Color(0xFF1E293B).withValues(alpha: 0.45)
                : baseColor.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isSelected
                  ? Colors.white
                  : baseColor.withValues(alpha: clip.muted ? 0.3 : 0.8),
              width: isSelected ? 1.8 : 1.0,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              // Waveform background
              Positioned.fill(
                top: 18,
                child: CustomPaint(
                  painter: _ClipWaveformPainter(
                    buckets: waveform,
                    color: clip.muted
                        ? Colors.grey.withValues(alpha: 0.25)
                        : baseColor.withValues(alpha: 0.55),
                  ),
                ),
              ),
              // Top header strip of clip
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 18,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  color: clip.muted
                      ? const Color(0xFF334155)
                      : baseColor.withValues(alpha: 0.75),
                  child: Row(
                    children: [
                      if (clip.muted)
                        const Padding(
                          padding: EdgeInsets.only(right: 4),
                          child: Icon(
                            Icons.visibility_off,
                            size: 11,
                            color: Colors.white70,
                          ),
                        ),
                      Expanded(
                        child: Text(
                          clip.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if ((clip.speed - 1.0).abs() > 0.01)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 0.5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            '${clip.speed.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), '')}x',
                            style: const TextStyle(
                              color: Color(0xFFFDE047),
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // Left Trim Handle (In-point)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 8,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (d) {
                      final deltaSource =
                          (d.delta.dx / ctrl.timelineZoom) * clip.speed;
                      ctrl.trimClip(
                        clip.id,
                        newSourceStart: clip.sourceStart + deltaSource,
                        recordHistory: false,
                      );
                    },
                    onHorizontalDragEnd: (_) {
                      ctrl.trimClip(
                        clip.id,
                        newSourceStart: clip.sourceStart,
                        recordHistory: true,
                      );
                    },
                    child: Container(
                      color: isSelected
                          ? Colors.white.withValues(alpha: 0.35)
                          : Colors.transparent,
                    ),
                  ),
                ),
              ),
              // Right Trim Handle (Out-point)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: 8,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeLeftRight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (d) {
                      final deltaSource =
                          (d.delta.dx / ctrl.timelineZoom) * clip.speed;
                      ctrl.trimClip(
                        clip.id,
                        newSourceEnd: clip.sourceEnd + deltaSource,
                        recordHistory: false,
                      );
                    },
                    onHorizontalDragEnd: (_) {
                      ctrl.trimClip(
                        clip.id,
                        newSourceEnd: clip.sourceEnd,
                        recordHistory: true,
                      );
                    },
                    child: Container(
                      color: isSelected
                          ? Colors.white.withValues(alpha: 0.35)
                          : Colors.transparent,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInputTrack(
    AsciicastEditorController ctrl,
    List<BakedTimelineEvent> inputEvents,
    double canvasWidth,
  ) {
    return Container(
      height: _inputTrackHeight,
      width: canvasWidth,
      decoration: const BoxDecoration(
        color: Color(0xFF131720),
        border: Border(bottom: BorderSide(color: Color(0xFF262B38))),
      ),
      child: CustomPaint(
        painter: _InputEventsPainter(
          inputEvents: inputEvents,
          zoom: ctrl.timelineZoom,
        ),
      ),
    );
  }

  String _formatSmpte(double seconds) {
    final safe = math.max(0.0, seconds);
    final mins = (safe ~/ 60).toString().padLeft(2, '0');
    final secs = (safe.floor() % 60).toString().padLeft(2, '0');
    final centis = ((safe - safe.floor()) * 100).round().clamp(0, 99);
    return '$mins:$secs.${centis.toString().padLeft(2, '0')}';
  }
}

class _TimeRulerPainter extends CustomPainter {
  _TimeRulerPainter({
    required this.zoom,
    required this.totalDuration,
    required this.playheadTime,
  });

  final double zoom;
  final double totalDuration;
  final double playheadTime;

  @override
  void paint(Canvas canvas, Size size) {
    final bgPaint = Paint()..color = const Color(0xFF181C26);
    canvas.drawRect(Offset.zero & size, bgPaint);

    // Highlight active duration region
    final activeWidth = (totalDuration * zoom).clamp(0.0, size.width);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, activeWidth, size.height),
      Paint()..color = const Color(0xFF1E2433),
    );

    final majorStepSec = zoom >= 140
        ? 1.0
        : zoom >= 60
        ? 2.0
        : zoom >= 30
        ? 5.0
        : 10.0;
    final minorSubdivisions = 5;
    final minorStepSec = majorStepSec / minorSubdivisions;

    final tickPaint = Paint()
      ..color = const Color(0xFF475569)
      ..strokeWidth = 1.0;
    final majorTickPaint = Paint()
      ..color = const Color(0xFF94A3B8)
      ..strokeWidth = 1.2;

    final maxSec = size.width / zoom;
    for (double t = 0; t <= maxSec; t += minorStepSec) {
      final x = t * zoom;
      final isMajor =
          (t / majorStepSec - (t / majorStepSec).round()).abs() < 1e-3;
      if (isMajor) {
        canvas.drawLine(
          Offset(x, size.height - 10),
          Offset(x, size.height),
          majorTickPaint,
        );
        final mins = (t ~/ 60).toString().padLeft(2, '0');
        final secs = (t.round() % 60).toString().padLeft(2, '0');
        final tp = TextPainter(
          text: TextSpan(
            text: '$mins:$secs',
            style: const TextStyle(
              color: Color(0xFF94A3B8),
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x + 3, 4));
      } else {
        canvas.drawLine(
          Offset(x, size.height - 5),
          Offset(x, size.height),
          tickPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TimeRulerPainter oldDelegate) =>
      oldDelegate.zoom != zoom ||
      oldDelegate.totalDuration != totalDuration ||
      oldDelegate.playheadTime != playheadTime;
}

class _PlayheadPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final paint = Paint()
      ..color = const Color(0xFFEF4444)
      ..style = PaintingStyle.fill;

    // Draw Premiere/DaVinci style playhead cap
    final capPath = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, 8)
      ..lineTo(centerX, 15)
      ..lineTo(0, 8)
      ..close();
    canvas.drawPath(capPath, paint);

    // Draw vertical line
    canvas.drawLine(
      Offset(centerX, 14),
      Offset(centerX, size.height),
      Paint()
        ..color = const Color(0xFFEF4444)
        ..strokeWidth = 1.6,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ClipWaveformPainter extends CustomPainter {
  _ClipWaveformPainter({required this.buckets, required this.color});

  final List<double> buckets;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (buckets.isEmpty || size.width <= 0 || size.height <= 0) return;
    final barWidth = size.width / buckets.length;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    for (var i = 0; i < buckets.length; i++) {
      final value = buckets[i];
      if (value <= 0.01) continue;
      final barHeight = (value * (size.height - 4)).clamp(2.0, size.height - 2);
      final rect = Rect.fromLTWH(
        i * barWidth + 0.5,
        size.height - barHeight,
        math.max(1.0, barWidth - 1.2),
        barHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1.5)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ClipWaveformPainter oldDelegate) =>
      oldDelegate.buckets != buckets || oldDelegate.color != color;
}

class _InputEventsPainter extends CustomPainter {
  _InputEventsPainter({required this.inputEvents, required this.zoom});

  final List<BakedTimelineEvent> inputEvents;
  final double zoom;

  @override
  void paint(Canvas canvas, Size size) {
    if (inputEvents.isEmpty) return;
    final paint = Paint()
      ..color = const Color(0xFF10B981)
      ..style = PaintingStyle.fill;
    final cy = size.height / 2;

    for (final ev in inputEvents) {
      final cx = ev.timelineTime * zoom;
      if (cx < 0 || cx > size.width) continue;
      final path = Path()
        ..moveTo(cx, cy - 5)
        ..lineTo(cx + 4, cy)
        ..lineTo(cx, cy + 5)
        ..lineTo(cx - 4, cy)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _InputEventsPainter oldDelegate) =>
      oldDelegate.inputEvents != inputEvents || oldDelegate.zoom != zoom;
}
