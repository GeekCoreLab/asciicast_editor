/// Decoupled Non-Linear Editor (NLE) Flutter plugin for asciicast (`.cast`)
/// terminal recordings, powered by `termui_flutter`.
library;

export 'src/controller.dart' show AsciicastEditorController, BakedTimelineEvent;
export 'src/editor_widget.dart'
    show AsciicastEditor, AsciicastEditorDialog, AsciicastEditorResult;
export 'src/models.dart'
    show
        AsciicastClip,
        AsciicastDocument,
        AsciicastEvent,
        AsciicastHeader,
        AsciicastMarker,
        NleToolMode,
        TerminalPreviewTheme;
export 'src/terminal_preview.dart' show AsciicastTerminalPreview;
export 'src/timeline_panel.dart' show AsciicastTimelinePanel;
