## 0.1.2

- Fixed `No MaterialLocalizations found` when hosting `AsciicastEditor` or `AsciicastEditorDialog` inside a `package:flutter/material.dart` app with non-English locales (e.g. `zh_CN`).
- Replaced `DropdownButton` / `showDialog` calls inside `AsciicastEditor` with locale-safe `Localizations.override` routes so dropdown menus and dialogs work regardless of host locale.
- Added horizontal scrolling fallback to the Program Monitor header bar to prevent `RenderFlex` overflow on narrow viewports.

## 0.1.1

- Removed `termui_pty` dependency and replaced it with a built-in pure-Dart `VirtualTerminal` for full 6-platform and Web/WASM compatibility.
- Migrated from deprecated `package:flutter/material.dart` to `package:material_ui/material_ui.dart` while preserving compatibility with legacy `flutter/material.dart` host apps.
- Added an `example/` Flutter application demonstrating `AsciicastEditor`.

## 0.1.0

- Initial release of `asciicast_editor`.
- Supports parsing, non-linear editing, and exporting asciicast v2 and v3 (`.cast`) recordings.
- Multi-track NLE timeline (`M1` markers, `T1` terminal output clips, `I1` keystroke input) with 1:1 pointer drag/trim, razor splitting, speed scaling, ripple delete, auto-slicing (by line or by input), idle-time compression, sensitive text redaction, and inline editing of markers, input events, and output events.
- GPU-accelerated terminal preview via `termui_flutter`, DaVinci Resolve keyboard shortcut template, and configurable `pauseOnMarkers` (skip/enable marker auto-pause).
