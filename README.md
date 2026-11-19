# asciicast_editor

A pure Dart and Flutter library for parsing, trimming, and editing asciinema (`.cast`) recordings.

Provides a decoupled non-linear editor (NLE) workspace inspired by Adobe Premiere Pro, DaVinci Resolve, and Kdenlive, using `termui_flutter` for GPU-accelerated terminal preview across all platforms (Android, iOS, Linux, macOS, Windows, and Web/WASM).

Repository: <https://github.com/GeekCoreLab/asciicast_editor.git>

## Features

- **Asciicast v2 & v3 Support**: Parse, inspect, non-linearly edit, and export `.cast` recordings.
- **Multi-Track NLE Timeline**:
  - **M1 Marker Track**: Add, rename, re-time, and jump to markers (`m` events) for `pauseOnMarkers` support.
  - **T1 Terminal Output Track**: Split clips with the Razor/Blade tool (`C` / `K`), trim clip In/Out points, adjust per-clip playback speed (`0.25x` – `8.0x`), mute/enable clips, and ripple-delete unwanted segments.
  - **I1 Input/Keystroke Track**: Inspect keystrokes and commands along the timeline.
- **Idle Time Compression & Sensitive Text Redaction**: Compress long pauses globally or per clip, and search/replace or redact sensitive output (tokens, IPs, passwords) across terminal frames.
- **GPU-Accelerated Program Monitor**: Powered by `termui_flutter` (`Terminal`) and a built-in pure-Dart `VirtualTerminal` with real-time scrubbing, frame stepping, theme switching, and final result preview.
- **Undo / Redo History**: Full snapshot-based undo/redo history stack.

## License

BSD-3-Clause
