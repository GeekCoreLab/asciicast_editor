import 'dart:convert';
import 'dart:math' as math;

/// Non-linear editor tool modes inspired by Premiere Pro / DaVinci Resolve / Kdenlive.
enum NleToolMode {
  /// Standard selection and trim tool (`V`).
  pointer,

  /// Razor / blade tool for splitting clips at any timestamp (`C` / `B`).
  razor,

  /// Hand tool for panning the timeline (`H`).
  hand,
}

/// Auto-slice strategy for automatically splitting timeline clips.
enum AutoSliceMode {
  /// Split clips at output newline boundaries (`\n` in `'o'` events).
  byLine,

  /// Split clips at input event boundaries (`'i'` events).
  byInput,
}

/// Color themes available for the `termui_flutter` Program Monitor preview.
enum TerminalPreviewTheme {
  termuiDark(
    label: 'TermUI Dark',
    backgroundHex: 0xFF0B0E14,
    foregroundHex: 0xFFE2E8F0,
    isLight: false,
  ),
  dracula(
    label: 'Dracula',
    backgroundHex: 0xFF282A36,
    foregroundHex: 0xFFF8F8F2,
    isLight: false,
  ),
  monokai(
    label: 'Monokai',
    backgroundHex: 0xFF272822,
    foregroundHex: 0xFFF8F8F2,
    isLight: false,
  ),
  solarizedDark(
    label: 'Solarized Dark',
    backgroundHex: 0xFF002B36,
    foregroundHex: 0xFF839496,
    isLight: false,
  ),
  solarizedLight(
    label: 'Solarized Light',
    backgroundHex: 0xFFFDF6E3,
    foregroundHex: 0xFF657B83,
    isLight: true,
  ),
  windblogLight(
    label: 'Light',
    backgroundHex: 0xFFF8FAFC,
    foregroundHex: 0xFF1E293B,
    isLight: true,
  );

  const TerminalPreviewTheme({
    required this.label,
    required this.backgroundHex,
    required this.foregroundHex,
    required this.isLight,
  });

  final String label;
  final int backgroundHex;
  final int foregroundHex;
  final bool isLight;
}

/// Header metadata of an asciicast v2/v3 recording.
class AsciicastHeader {
  const AsciicastHeader({
    this.version = 2,
    this.width = 80,
    this.height = 24,
    this.idleTimeLimit = 2.0,
    this.title,
    this.timestamp,
    this.env = const <String, String>{},
  });

  final int version;
  final int width;
  final int height;
  final double? idleTimeLimit;
  final String? title;
  final int? timestamp;
  final Map<String, String> env;

  AsciicastHeader copyWith({
    int? version,
    int? width,
    int? height,
    double? idleTimeLimit,
    bool clearIdleTimeLimit = false,
    String? title,
    int? timestamp,
    Map<String, String>? env,
  }) {
    return AsciicastHeader(
      version: version ?? this.version,
      width: (width ?? this.width).clamp(10, 500),
      height: (height ?? this.height).clamp(4, 200),
      idleTimeLimit: clearIdleTimeLimit
          ? null
          : (idleTimeLimit ?? this.idleTimeLimit),
      title: title ?? this.title,
      timestamp: timestamp ?? this.timestamp,
      env: env ?? Map<String, String>.from(this.env),
    );
  }

  Map<String, Object?> toJsonMap({int? forceVersion}) {
    final v = forceVersion ?? version;
    if (v == 3) {
      return <String, Object?>{
        'version': 3,
        'term': <String, Object?>{'cols': width, 'rows': height},
        if (idleTimeLimit != null && idleTimeLimit! > 0)
          'idle_time_limit': idleTimeLimit,
        if (title != null && title!.trim().isNotEmpty) 'title': title!.trim(),
        if (timestamp != null) 'timestamp': timestamp,
        if (env.isNotEmpty) 'env': env,
      };
    }
    return <String, Object?>{
      'version': 2,
      'width': width,
      'height': height,
      if (idleTimeLimit != null && idleTimeLimit! > 0)
        'idle_time_limit': idleTimeLimit,
      if (title != null && title!.trim().isNotEmpty) 'title': title!.trim(),
      if (timestamp != null) 'timestamp': timestamp,
      if (env.isNotEmpty) 'env': env,
    };
  }
}

/// A single recorded terminal event (`o`, `i`, `m`, `r`, `x`).
class AsciicastEvent {
  const AsciicastEvent({
    required this.id,
    required this.time,
    required this.type,
    required this.data,
  });

  final String id;

  /// Timestamp in seconds relative to the start of the clip's source stream.
  final double time;

  /// Event code: `'o'` (output), `'i'` (input), `'m'` (marker), `'r'` (resize), `'x'` (exit).
  final String type;

  /// Event payload string.
  final String data;

  AsciicastEvent copyWith({
    String? id,
    double? time,
    String? type,
    String? data,
  }) {
    return AsciicastEvent(
      id: id ?? this.id,
      time: time ?? this.time,
      type: type ?? this.type,
      data: data ?? this.data,
    );
  }
}

/// A timeline marker (`[time, "m", "label"]`) used for chapter navigation and `pauseOnMarkers`.
class AsciicastMarker {
  const AsciicastMarker({
    required this.id,
    required this.time,
    required this.label,
  });

  final String id;

  /// Position on the edited timeline in seconds.
  final double time;

  /// Human-readable label shown in the player and timeline.
  final String label;

  AsciicastMarker copyWith({String? id, double? time, String? label}) {
    return AsciicastMarker(
      id: id ?? this.id,
      time: time != null ? math.max(0.0, time) : this.time,
      label: label ?? this.label,
    );
  }
}

/// A non-linear clip on the primary terminal track (`T1`).
///
/// Each clip references a list of source [events] and defines an active trim window
/// `[sourceStart, sourceEnd]`, a [speed] multiplier, and a [muted] flag.
class AsciicastClip {
  const AsciicastClip({
    required this.id,
    required this.name,
    required this.sourceStart,
    required this.sourceEnd,
    required this.events,
    this.speed = 1.0,
    this.muted = false,
    this.colorValue = 0xFF0EA5E9,
  });

  final String id;
  final String name;
  final double sourceStart;
  final double sourceEnd;
  final List<AsciicastEvent> events;
  final double speed;
  final bool muted;
  final int colorValue;

  /// Duration of the trimmed source range in seconds before speed scaling.
  double get sourceDuration => math.max(0.0, sourceEnd - sourceStart);

  /// Effective duration on the timeline in seconds after applying [speed].
  double get timelineDuration =>
      speed <= 0 ? sourceDuration : sourceDuration / speed;

  /// Events falling within `[sourceStart, sourceEnd]`.
  Iterable<AsciicastEvent> get trimmedEvents sync* {
    for (final ev in events) {
      if (ev.time >= sourceStart - 1e-6 && ev.time <= sourceEnd + 1e-6) {
        yield ev;
      }
    }
  }

  /// Computes normalized `[0.0 .. 1.0]` output activity density buckets for
  /// drawing a Premiere/Kdenlive-style waveform on the timeline clip.
  List<double> computeActivityWaveform(int bucketCount) {
    final count = bucketCount.clamp(4, 256);
    final buckets = List<double>.filled(count, 0.0);
    final span = sourceDuration;
    if (span <= 1e-6 || events.isEmpty) {
      return buckets;
    }

    var maxWeight = 0.0;
    for (final ev in trimmedEvents) {
      if (ev.type != 'o' && ev.type != 'i') continue;
      final rel = ((ev.time - sourceStart) / span).clamp(0.0, 0.9999);
      final idx = (rel * count).floor();
      final weight = math.log(ev.data.length + 1) + 1.0;
      buckets[idx] += weight;
      if (buckets[idx] > maxWeight) {
        maxWeight = buckets[idx];
      }
    }

    if (maxWeight > 0) {
      for (var i = 0; i < count; i++) {
        buckets[i] = (buckets[i] / maxWeight).clamp(0.0, 1.0);
      }
    }
    return buckets;
  }

  AsciicastClip copyWith({
    String? id,
    String? name,
    double? sourceStart,
    double? sourceEnd,
    List<AsciicastEvent>? events,
    double? speed,
    bool? muted,
    int? colorValue,
  }) {
    return AsciicastClip(
      id: id ?? this.id,
      name: name ?? this.name,
      sourceStart: sourceStart ?? this.sourceStart,
      sourceEnd: sourceEnd ?? this.sourceEnd,
      events: events ?? List<AsciicastEvent>.from(this.events),
      speed: (speed ?? this.speed).clamp(0.1, 16.0),
      muted: muted ?? this.muted,
      colorValue: colorValue ?? this.colorValue,
    );
  }
}

/// Parsed representation of an asciicast `.cast` file.
class AsciicastDocument {
  const AsciicastDocument({
    required this.header,
    required this.clips,
    required this.markers,
  });

  final AsciicastHeader header;
  final List<AsciicastClip> clips;
  final List<AsciicastMarker> markers;

  /// Parses an asciicast v2 or v3 JSONL string into an [AsciicastDocument].
  factory AsciicastDocument.parse(
    String rawCast, {
    String clipName = 'Clip 01',
  }) {
    final trimmed = rawCast.trim();
    if (trimmed.isEmpty) {
      return AsciicastDocument.sampleDemo();
    }

    final lines = trimmed.split(RegExp(r'\r?\n'));
    var header = const AsciicastHeader();
    var startLineIndex = 0;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
        continue;
      }
      if (line.startsWith('{')) {
        try {
          final map = jsonDecode(line) as Map<String, Object?>;
          final version = (map['version'] as num?)?.toInt() ?? 2;
          var width = 80;
          var height = 24;
          if (version == 3 && map['term'] is Map) {
            final term = map['term'] as Map<Object?, Object?>;
            width = (term['cols'] as num?)?.toInt() ?? 80;
            height = (term['rows'] as num?)?.toInt() ?? 24;
          } else {
            width =
                (map['width'] as num?)?.toInt() ??
                (map['cols'] as num?)?.toInt() ??
                80;
            height =
                (map['height'] as num?)?.toInt() ??
                (map['rows'] as num?)?.toInt() ??
                24;
          }
          final idleLimit = (map['idle_time_limit'] as num?)?.toDouble();
          final title = map['title']?.toString();
          final timestamp = (map['timestamp'] as num?)?.toInt();
          final envMap = <String, String>{};
          if (map['env'] is Map) {
            for (final entry in (map['env'] as Map<Object?, Object?>).entries) {
              if (entry.key != null && entry.value != null) {
                envMap[entry.key.toString()] = entry.value.toString();
              }
            }
          }
          header = AsciicastHeader(
            version: version,
            width: width,
            height: height,
            idleTimeLimit: idleLimit ?? 2.0,
            title: title,
            timestamp: timestamp,
            env: envMap,
          );
          startLineIndex = i + 1;
        } catch (_) {
          startLineIndex = i + 1;
        }
      }
      break;
    }

    final events = <AsciicastEvent>[];
    final markers = <AsciicastMarker>[];
    var accumulatedTime = 0.0;
    var eventCounter = 0;
    var markerCounter = 0;

    for (var i = startLineIndex; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty || !line.startsWith('[')) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is List && decoded.length >= 3) {
          final rawTime = (decoded[0] as num).toDouble();
          final type = decoded[1].toString();
          final data = decoded[2]?.toString() ?? '';
          final time = header.version == 3
              ? (accumulatedTime += math.max(0.0, rawTime))
              : math.max(0.0, rawTime);
          if (type == 'm') {
            markerCounter++;
            markers.add(
              AsciicastMarker(
                id: 'marker_$markerCounter',
                time: time,
                label: data.isEmpty ? 'Marker $markerCounter' : data,
              ),
            );
          } else {
            eventCounter++;
            events.add(
              AsciicastEvent(
                id: 'ev_$eventCounter',
                time: time,
                type: type,
                data: data,
              ),
            );
          }
        }
      } catch (_) {
        // Ignore malformed event line
      }
    }

    events.sort((a, b) => a.time.compareTo(b.time));
    markers.sort((a, b) => a.time.compareTo(b.time));

    final maxEventTime = events.isEmpty ? 0.0 : events.last.time;
    final maxMarkerTime = markers.isEmpty ? 0.0 : markers.last.time;
    final totalDuration = math.max(maxEventTime, math.max(maxMarkerTime, 0.5));

    final mainClip = AsciicastClip(
      id: 'clip_1',
      name: clipName,
      sourceStart: 0.0,
      sourceEnd: totalDuration,
      events: events,
    );

    return AsciicastDocument(
      header: header,
      clips: <AsciicastClip>[mainClip],
      markers: markers,
    );
  }

  /// Built-in sample demo recording with ANSI colors, commands, and markers.
  factory AsciicastDocument.sampleDemo() {
    const sampleCast = '''
{"version": 2, "width": 84, "height": 24, "idle_time_limit": 2, "title": "WindBlog Asciinema Demo"}
[0.10, "o", "\\u001b[1;36mhhjmk@windblog\\u001b[0m:\\u001b[1;34m~/windblog_quarkus\\u001b[0m\$ "]
[0.65, "i", "mvn --version\\r"]
[0.80, "o", "mvn --version\\r\\n"]
[1.10, "m", "检查构建环境"]
[1.25, "o", "\\u001b[1mApache Maven 3.9.9\\u001b[0m (Java 21.0.5, Quarkus 3.x)\\r\\n"]
[1.80, "o", "\\u001b[1;36mhhjmk@windblog\\u001b[0m:\\u001b[1;34m~/windblog_quarkus\\u001b[0m\$ "]
[2.40, "i", "./mvnw package -DskipTests\\r"]
[2.60, "o", "./mvnw package -DskipTests\\r\\n"]
[3.00, "m", "执行打包命令"]
[3.30, "o", "[\\u001b[1;34mINFO\\u001b[0m] Scanning for projects...\\r\\n"]
[3.90, "o", "[\\u001b[1;34mINFO\\u001b[0m] Building \\u001b[1mwindblog-quarkus 1.1.0\\u001b[0m\\r\\n"]
[4.60, "o", "[\\u001b[1;32mSUCCESS\\u001b[0m] Quarkus augmentation completed in 1420ms\\r\\n"]
[5.10, "m", "构建完成与验证"]
[5.20, "o", "\\u001b[1;32m✔ Build succeeded!\\u001b[0m Ready for deployment.\\r\\n"]
[5.50, "o", "\\u001b[1;36mhhjmk@windblog\\u001b[0m:\\u001b[1;34m~/windblog_quarkus\\u001b[0m\$ "]
''';
    return AsciicastDocument.parse(sampleCast, clipName: 'Demo Session');
  }
}
