## 0.1.0

- Initial release of `asciicast_editor`.
- Supports parsing, non-linear editing, and exporting asciicast v2 and v3 (`.cast`) recordings.
- Multi-track NLE timeline (`M1` markers, `T1` terminal output clips, `I1` keystroke input) with 1:1 pointer drag/trim, razor splitting, speed scaling, ripple delete, auto-slicing (by line or by input), idle-time compression, sensitive text redaction, and inline editing of markers, input events, and output events.
- GPU-accelerated terminal preview via `termui_flutter`, DaVinci Resolve keyboard shortcut template, and configurable `pauseOnMarkers` (skip/enable marker auto-pause).
