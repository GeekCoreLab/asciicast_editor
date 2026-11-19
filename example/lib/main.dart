import 'package:asciicast_editor/asciicast_editor.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  runApp(const AsciicastEditorExampleApp());
}

/// Minimal example app hosting [AsciicastEditor].
class AsciicastEditorExampleApp extends StatelessWidget {
  const AsciicastEditorExampleApp({super.key});

  static const String _sampleCast = '''
{"version": 2, "width": 80, "height": 24, "title": "Demo Recording"}
[0.3, "o", "\\u001b[32m\$ echo hello world\\u001b[0m\\r\\n"]
[0.9, "m", "Command Output"]
[1.2, "o", "hello world\\r\\n"]
''';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Asciicast Editor Example',
      theme: ThemeData.dark(),
      home: Scaffold(
        body: AsciicastEditor(
          initialCastContent: _sampleCast,
          initialFileName: 'demo.cast',
          onExport: (result) {
            debugPrint(
              'Exported ${result.fileName} (${result.castContent.length} bytes)',
            );
          },
        ),
      ),
    );
  }
}
