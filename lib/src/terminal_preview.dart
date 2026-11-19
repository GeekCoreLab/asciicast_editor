import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:termui/ui/terminal_palette.dart';
import 'package:termui_flutter/termui_flutter.dart';

import 'controller.dart';

/// Program Monitor preview widget powered by `termui_flutter`'s GPU-accelerated [Terminal].
class AsciicastTerminalPreview extends StatefulWidget {
  const AsciicastTerminalPreview({
    super.key,
    required this.controller,
    this.fontFamily = 'monospace',
    this.fontFamilyFallback = const <String>[
      'JetBrains Mono',
      'Cascadia Mono',
      'DejaVu Sans Mono',
      'Consolas',
      'Noto Color Emoji',
    ],
  });

  final AsciicastEditorController controller;
  final String fontFamily;
  final List<String> fontFamilyFallback;

  @override
  State<AsciicastTerminalPreview> createState() =>
      _AsciicastTerminalPreviewState();
}

class _AsciicastTerminalPreviewState extends State<AsciicastTerminalPreview> {
  Completer<void>? _loopCompleter;

  @override
  void dispose() {
    if (widget.controller.onFrameRedrawn != null) {
      widget.controller.onFrameRedrawn = null;
    }
    if (_loopCompleter != null && !_loopCompleter!.isCompleted) {
      _loopCompleter!.complete();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final theme = widget.controller.previewTheme;
        final bgColor = Color(theme.backgroundHex);
        final fgColor = Color(theme.foregroundHex);
        final palette = theme.isLight
            ? TerminalColorTheme.termuiLight
            : TerminalColorTheme.termuiDark;

        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              color: bgColor,
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Terminal(
              terminal: widget.controller.flutterTerminal,
              fontSize: widget.controller.fontSize,
              fontFamily: widget.fontFamily,
              fontFamilyFallback: widget.fontFamilyFallback,
              backgroundColor: bgColor,
              foregroundColor: fgColor,
              palette: palette,
              enableBuiltinSelection: true,
              enableBuiltinLinkOpen: true,
              onRun: (terminal, drawFrame) async {
                _loopCompleter = Completer<void>();
                widget.controller.onFrameRedrawn = drawFrame;
                widget.controller.refreshPreviewFrame();
                await _loopCompleter!.future;
              },
            ),
          ),
        );
      },
    );
  }
}
