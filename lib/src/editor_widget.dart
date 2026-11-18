import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'models.dart';
import 'terminal_preview.dart';
import 'timeline_panel.dart';

/// Result returned when the user exports/applies edits from [AsciicastEditor].
class AsciicastEditorResult {
  const AsciicastEditorResult({
    required this.castContent,
    required this.header,
    required this.markers,
    required this.totalDuration,
    required this.fileName,
  });

  /// Serialized `.cast` (JSONL) content with all NLE edits and markers baked in.
  final String castContent;
  final AsciicastHeader header;
  final List<AsciicastMarker> markers;
  final double totalDuration;
  final String fileName;
}

/// Decoupled Non-Linear Editor (NLE) widget for `.cast` terminal recordings,
/// inspired by Premiere Pro, DaVinci Resolve, and Kdenlive, using `termui_flutter`
/// as its GPU-accelerated Program Monitor.
class AsciicastEditor extends StatefulWidget {
  const AsciicastEditor({
    super.key,
    this.controller,
    this.initialCastContent,
    this.initialFileName = 'recording.cast',
    this.onExport,
    this.exportButtonLabel = '完成剪辑并应用',
  });

  final AsciicastEditorController? controller;
  final String? initialCastContent;
  final String initialFileName;
  final ValueChanged<AsciicastEditorResult>? onExport;
  final String exportButtonLabel;

  @override
  State<AsciicastEditor> createState() => _AsciicastEditorState();
}

class _AsciicastEditorState extends State<AsciicastEditor> {
  late AsciicastEditorController _controller;
  bool _ownsController = false;
  int _inspectorTabIndex = 0; // 0: Clips, 1: Markers, 2: Events/History
  String _eventFilterType = 'all'; // 'all', 'o', 'i'
  final FocusNode _shortcutFocusNode = FocusNode();
  late String _fileName;

  @override
  void initState() {
    super.initState();
    _fileName = widget.initialFileName.trim().isEmpty
        ? 'recording.cast'
        : widget.initialFileName.trim();
    if (widget.controller != null) {
      _controller = widget.controller!;
      _ownsController = false;
    } else {
      _controller = AsciicastEditorController(
        initialCastContent: widget.initialCastContent,
        initialClipName: _fileName,
      );
      _ownsController = true;
    }
    HardwareKeyboard.instance.addHandler(_handleHardwareKeyEvent);
  }

  @override
  void didUpdateWidget(covariant AsciicastEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      if (_ownsController) {
        _controller.dispose();
      }
      if (widget.controller != null) {
        _controller = widget.controller!;
        _ownsController = false;
      } else {
        _controller = AsciicastEditorController(
          initialCastContent: widget.initialCastContent,
          initialClipName: _fileName,
        );
        _ownsController = true;
      }
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKeyEvent);
    _shortcutFocusNode.dispose();
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  bool _isTextInputFocused() {
    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus == null) return false;
    final ctx = primaryFocus.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText) return true;
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool _handleHardwareKeyEvent(KeyEvent event) {
    if (!mounted) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    if (!TickerMode.valuesOf(context).enabled) return false;
    if (_isTextInputFocused()) return false;

    final kb = HardwareKeyboard.instance;
    final isCtrlOrMeta = kb.isControlPressed || kb.isMetaPressed;
    final isShift = kb.isShiftPressed;
    final isAlt = kb.isAltPressed;
    final key = event.logicalKey;

    if (event is KeyRepeatEvent) {
      // Swallow Space repeat so a focused button never receives ActivateIntent.
      if (key == LogicalKeyboardKey.space && !isCtrlOrMeta && !isAlt) {
        return true;
      }
      final isStepKey =
          key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.comma ||
          key == LogicalKeyboardKey.period;
      final isZoomKey =
          key == LogicalKeyboardKey.equal ||
          key == LogicalKeyboardKey.add ||
          key == LogicalKeyboardKey.numpadAdd ||
          key == LogicalKeyboardKey.minus ||
          key == LogicalKeyboardKey.numpadSubtract;
      if (!isStepKey && !isZoomKey) {
        return false;
      }
    }

    if (isAlt) return false;

    // Ctrl / Cmd shortcuts (DaVinci Resolve template)
    if (isCtrlOrMeta) {
      if (key == LogicalKeyboardKey.keyZ) {
        if (isShift) {
          _controller.redo();
        } else {
          _controller.undo();
        }
        return true;
      }
      if (key == LogicalKeyboardKey.keyY) {
        _controller.redo();
        return true;
      }
      if (key == LogicalKeyboardKey.keyB ||
          key == LogicalKeyboardKey.backslash ||
          key == LogicalKeyboardKey.keyK) {
        _controller.splitAtPlayhead();
        return true;
      }
      if (key == LogicalKeyboardKey.keyL) {
        _controller.setLooping(!_controller.isLooping);
        return true;
      }
      if (key == LogicalKeyboardKey.keyM) {
        _controller.setPauseOnMarkers(!_controller.pauseOnMarkers);
        return true;
      }
      if (key == LogicalKeyboardKey.keyR) {
        final clipId = _controller.selectedClipId;
        if (clipId != null) {
          _promptSetClipSpeed(clipId);
          return true;
        }
        return false;
      }
      if (key == LogicalKeyboardKey.equal ||
          key == LogicalKeyboardKey.add ||
          key == LogicalKeyboardKey.numpadAdd) {
        _controller.setTimelineZoom(_controller.timelineZoom * 1.25);
        return true;
      }
      if (key == LogicalKeyboardKey.minus ||
          key == LogicalKeyboardKey.numpadSubtract) {
        _controller.setTimelineZoom(_controller.timelineZoom / 1.25);
        return true;
      }
      return false;
    }

    // Play / Pause (Space always toggles playback regardless of focused button)
    if (key == LogicalKeyboardKey.space) {
      _controller.togglePlay();
      return true;
    }

    // DaVinci Resolve J / K / L Shuttle
    if (key == LogicalKeyboardKey.keyJ) {
      _controller.shuttleBackward(stepSeconds: isShift ? 5.0 : 1.0);
      return true;
    }
    if (key == LogicalKeyboardKey.keyK) {
      _controller.pause();
      return true;
    }
    if (key == LogicalKeyboardKey.keyL) {
      _controller.shuttleForward();
      return true;
    }

    // Tools: A (Selection) / V (alias), B (Blade/Razor) / C (alias)
    if (key == LogicalKeyboardKey.keyA || key == LogicalKeyboardKey.keyV) {
      _controller.setActiveTool(NleToolMode.pointer);
      return true;
    }
    if (key == LogicalKeyboardKey.keyB || key == LogicalKeyboardKey.keyC) {
      _controller.setActiveTool(NleToolMode.razor);
      return true;
    }

    // Clip actions: D (Disable/Enable), Delete/Backspace (Ripple Delete)
    if (key == LogicalKeyboardKey.keyD) {
      final clipId = _controller.selectedClipId;
      if (clipId != null) {
        _controller.toggleClipMuted(clipId);
        return true;
      }
      return false;
    }
    if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      final clipId = _controller.selectedClipId;
      if (clipId != null) {
        _controller.deleteClip(clipId, ripple: true);
        return true;
      }
      return false;
    }

    // Zoom to Fit (Shift + Z) & Quick Zoom (= / -)
    if (key == LogicalKeyboardKey.keyZ && isShift) {
      _controller.fitTimelineToViewport();
      return true;
    }
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd) {
      _controller.setTimelineZoom(_controller.timelineZoom * 1.25);
      return true;
    }
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      _controller.setTimelineZoom(_controller.timelineZoom / 1.25);
      return true;
    }

    // Marker
    if (key == LogicalKeyboardKey.keyM) {
      _promptAddMarker();
      return true;
    }

    // Frame / 1s / Edit-point / Marker / Start-End Navigation
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (isShift) {
        _controller.seek(_controller.playheadTime - 1.0);
      } else {
        _controller.stepBackwardFrame();
      }
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (isShift) {
        _controller.seek(_controller.playheadTime + 1.0);
      } else {
        _controller.stepForwardFrame();
      }
      return true;
    }
    if (key == LogicalKeyboardKey.comma) {
      _controller.stepBackwardFrame();
      return true;
    }
    if (key == LogicalKeyboardKey.period) {
      _controller.stepForwardFrame();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (isShift) {
        _controller.jumpToPrevMarker();
      } else {
        _controller.jumpToPrevEditPoint();
      }
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (isShift) {
        _controller.jumpToNextMarker();
      } else {
        _controller.jumpToNextEditPoint();
      }
      return true;
    }
    if (key == LogicalKeyboardKey.bracketLeft) {
      _controller.jumpToPrevMarker();
      return true;
    }
    if (key == LogicalKeyboardKey.bracketRight) {
      _controller.jumpToNextMarker();
      return true;
    }
    if (key == LogicalKeyboardKey.home) {
      _controller.jumpToStart();
      return true;
    }
    if (key == LogicalKeyboardKey.end) {
      _controller.jumpToFinalResult();
      return true;
    }
    if (key == LogicalKeyboardKey.slash && isShift) {
      _showShortcutsDialog();
      return true;
    }
    return false;
  }

  void _triggerExport() {
    _controller.pause();
    final exported = _controller.exportCast();
    final result = AsciicastEditorResult(
      castContent: exported,
      header: _controller.header,
      markers: _controller.markers,
      totalDuration: _controller.totalDuration,
      fileName: _fileName.endsWith('.cast') ? _fileName : '$_fileName.cast',
    );
    widget.onExport?.call(result);
  }

  Future<void> _promptSetClipSpeed(String clipId) async {
    final idx = _controller.clips.indexWhere((c) => c.id == clipId);
    if (idx < 0) return;
    final clip = _controller.clips[idx];
    final speedCtrl = TextEditingController(
      text: clip.speed.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), ''),
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('变速控制 · ${clip.name} (Ctrl+R)'),
        content: TextField(
          controller: speedCtrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: '片段倍速 (0.25 ~ 8.0)',
            hintText: '例如：0.5 / 1.0 / 1.5 / 2.0 / 4.0',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('应用倍速'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final parsed = double.tryParse(speedCtrl.text.trim());
      if (parsed != null && parsed > 0) {
        _controller.setClipSpeed(clipId, parsed);
      }
    }
    speedCtrl.dispose();
  }

  Future<void> _showShortcutsDialog() async {
    const shortcuts = <(String, String)>[
      ('Space', '播放 / 暂停 (全局生效)'),
      ('J / K / L', '后退 1 秒 / 暂停 / 向前播放与倍速穿梭'),
      ('← / → 或 , / .', '上一帧 / 下一帧'),
      ('Shift + ← / →', '后退 / 前进 1 秒'),
      ('Home / End', '回到开头 / 跳转到最终结果'),
      ('↑ / ↓', '上一个 / 下一个片段边界'),
      ('Shift + ↑ / ↓ 或 [ / ]', '上一个 / 下一个标记'),
      ('A (或 V)', '选择工具 (Selection)'),
      ('B (或 C)', '剃刀工具 (Blade / Razor)'),
      ('Ctrl/Cmd + B (或 Ctrl+K)', '在播放头处切分片段'),
      ('D', '启用 / 禁用当前选中片段'),
      ('Delete / Backspace', '波纹删除当前选中片段'),
      ('Ctrl/Cmd + R', '调整当前选中片段倍速'),
      ('M', '在播放头处添加标记'),
      ('Ctrl/Cmd + M', '开启 / 跳过遇到标记自动暂停'),
      ('Ctrl/Cmd + L', '切换循环播放'),
      ('Ctrl/Cmd + Z / Ctrl+Shift+Z', '撤销 / 重做'),
      ('= / - (或 Ctrl+= / Ctrl+-)', '放大 / 缩小时间轴'),
      ('Shift + Z', '时间轴自适应铺满窗口'),
      ('?', '打开此快捷键说明'),
    ];
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('快捷键说明 · DaVinci Resolve 模板'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in shortcuts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: const Color(0xFF334155)),
                          ),
                          child: Text(
                            item.$1,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF38BDF8),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            item.$2,
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _promptAddMarker() async {
    _controller.pause();
    final labelCtrl = TextEditingController(text: '关键命令');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('在 ${_formatTimecode(_controller.playheadTime)} 处插入标记'),
        content: TextField(
          controller: labelCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '标记说明 (播放到此标记处将自动暂停方便复制)',
            hintText: '例如：安装依赖 / 修改配置 / 查看输出',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => Navigator.pop(ctx, true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('添加标记'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      _controller.addMarkerAtPlayhead(labelCtrl.text);
      setState(() => _inspectorTabIndex = 1);
    }
  }

  Future<void> _showCompressIdleDialog() async {
    _controller.pause();
    final limitCtrl = TextEditingController(
      text: (_controller.header.idleTimeLimit ?? 2.0).toStringAsFixed(1),
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('压缩空闲等待时间 (Idle Time Limit)'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '将录屏中超过指定秒数的停顿自动压缩，消除输命令时的长时间发呆等待。',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: limitCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: '最大允许停顿时长 (秒)',
                  suffixText: 's',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('应用压缩'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final val = double.tryParse(limitCtrl.text.trim()) ?? 2.0;
      _controller.compressIdleTime(maxIdleSeconds: val);
    }
  }

  Future<void> _showRedactDialog() async {
    _controller.pause();
    final patternCtrl = TextEditingController();
    final replaceCtrl = TextEditingController(text: '********');
    var useRegex = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('终端敏感内容打码 / 批量替换'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: patternCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '查找内容 (如密码、Token、IP、主机名)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: replaceCtrl,
                  decoration: const InputDecoration(
                    labelText: '替换为',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('使用正则表达式匹配 (RegExp)'),
                  value: useRegex,
                  onChanged: (v) => setDialogState(() => useRegex = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('批量替换'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true && patternCtrl.text.isNotEmpty) {
      final count = _controller.redactText(
        pattern: patternCtrl.text,
        replacement: replaceCtrl.text,
        useRegex: useRegex,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已完成替换，共处理 $count 处匹配内容')));
      }
    }
  }

  Future<void> _showHeaderSettingsDialog() async {
    _controller.pause();
    final colsCtrl = TextEditingController(text: '${_controller.header.width}');
    final rowsCtrl = TextEditingController(
      text: '${_controller.header.height}',
    );
    final idleCtrl = TextEditingController(
      text: '${_controller.header.idleTimeLimit ?? 2.0}',
    );
    final titleCtrl = TextEditingController(
      text: _controller.header.title ?? _fileName,
    );
    var version = _controller.header.version;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('画布尺寸与 Asciicast 头部设置'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(
                    labelText: '录屏标题 (Title)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: colsCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '终端列数 (Cols)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: rowsCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '终端行数 (Rows)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: idleCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'idleTimeLimit (秒)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: version == 3 ? 3 : 2,
                        decoration: const InputDecoration(
                          labelText: '导出格式版本',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 2, child: Text('v2 (.cast)')),
                          DropdownMenuItem(value: 3, child: Text('v3 (.cast)')),
                        ],
                        onChanged: (v) {
                          if (v != null) setDialogState(() => version = v);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存设置'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      _controller.updateHeader(
        width: int.tryParse(colsCtrl.text.trim()),
        height: int.tryParse(rowsCtrl.text.trim()),
        idleTimeLimit: double.tryParse(idleCtrl.text.trim()),
        title: titleCtrl.text.trim(),
        version: version,
      );
    }
  }

  Future<void> _showAutoSliceDialog() async {
    _controller.pause();
    var mode = AutoSliceMode.byLine;
    var onlySelectedClip = false;
    final minGapCtrl = TextEditingController(text: '0.25');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('自动切片时间轴素材'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '选择切分方式：',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                SegmentedButton<AutoSliceMode>(
                  segments: const [
                    ButtonSegment<AutoSliceMode>(
                      value: AutoSliceMode.byLine,
                      icon: Icon(Icons.wrap_text, size: 16),
                      label: Text('按行切分'),
                    ),
                    ButtonSegment<AutoSliceMode>(
                      value: AutoSliceMode.byInput,
                      icon: Icon(Icons.keyboard_alt_outlined, size: 16),
                      label: Text('按输入切分'),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (next) {
                    setDialogState(() => mode = next.first);
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  mode == AutoSliceMode.byLine
                      ? '按终端输出中的换行符（\\n）自动切分，适合逐行整理演示步骤。'
                      : '按键盘输入事件（i 事件）自动切分，适合按交互命令拆分操作片段。',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF94A3B8),
                  ),
                ),
                if (_controller.clips.length > 1 &&
                    _controller.selectedClipId != null) ...[
                  const SizedBox(height: 12),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      '仅切分当前选中片段',
                      style: TextStyle(fontSize: 12.5),
                    ),
                    value: onlySelectedClip,
                    onChanged: (v) =>
                        setDialogState(() => onlySelectedClip = v),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: minGapCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '最小片段间隔（秒）',
                    hintText: '例如：0.25（避免连续快速输出产生过碎片段）',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('开始切片'),
            ),
          ],
        ),
      ),
    );

    final minGap = double.tryParse(minGapCtrl.text.trim()) ?? 0.25;
    minGapCtrl.dispose();

    if (confirmed == true) {
      final added = _controller.autoSliceClips(
        mode: mode,
        clipId: onlySelectedClip ? _controller.selectedClipId : null,
        minClipDuration: minGap,
      );
      if (mounted) {
        final modeName = mode == AutoSliceMode.byLine ? '按行' : '按输入';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              added > 0
                  ? '自动切片完成（$modeName）：新增 $added 个片段'
                  : '未找到符合条件的$modeName切分点（可尝试调小最小片段间隔）',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _shortcutFocusNode,
      autofocus: true,
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          return Container(
            color: const Color(0xFF0D0F17),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. Studio Top Action & Tool Bar
                _buildTopToolbar(),
                const Divider(height: 1, color: Color(0xFF262B38)),
                // 2. Upper Split Area: Left Bin/Inspector + Right Program Monitor
                Expanded(
                  flex: 6,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final isCompact = constraints.maxWidth < 760;
                      if (isCompact) {
                        return Column(
                          children: [
                            Expanded(
                              flex: 3,
                              child: _buildProgramMonitorSection(),
                            ),
                            const Divider(height: 1, color: Color(0xFF262B38)),
                            Expanded(flex: 2, child: _buildLeftInspectorDock()),
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: 340,
                            child: _buildLeftInspectorDock(),
                          ),
                          const VerticalDivider(
                            width: 1,
                            color: Color(0xFF262B38),
                          ),
                          Expanded(child: _buildProgramMonitorSection()),
                        ],
                      );
                    },
                  ),
                ),
                const Divider(height: 1, color: Color(0xFF262B38)),
                // 3. Lower Multi-Track Timeline Panel
                SizedBox(
                  height: 185,
                  child: AsciicastTimelinePanel(
                    controller: _controller,
                    onEditMarker: _editMarkerDialog,
                    onEditEvent: _editRawEventDialog,
                    onEditClipEvents: _showClipEventsEditorDialog,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTopToolbar() {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: const Color(0xFF151922),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const Icon(Icons.movie_filter, color: Color(0xFF38BDF8), size: 20),
            const SizedBox(width: 8),
            Text(
              'Asciicast Studio NLE',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '${_controller.header.width}x${_controller.header.height} · v${_controller.header.version}',
                style: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(width: 16),
            // Tool Mode Selector (DaVinci Resolve: Pointer A / Blade B)
            _buildToolChip(
              icon: Icons.near_me_outlined,
              label: '选择 (A)',
              selected: _controller.activeTool == NleToolMode.pointer,
              onTap: () => _controller.setActiveTool(NleToolMode.pointer),
            ),
            const SizedBox(width: 6),
            _buildToolChip(
              icon: Icons.content_cut,
              label: '剃刀分割 (B)',
              selected: _controller.activeTool == NleToolMode.razor,
              activeColor: const Color(0xFFF43F5E),
              onTap: () => _controller.setActiveTool(NleToolMode.razor),
            ),
            const SizedBox(width: 6),
            _buildActionBtn(
              icon: Icons.vertical_split,
              label: '播放头切分 (Ctrl+B)',
              onTap: () => _controller.splitAtPlayhead(),
            ),
            const SizedBox(width: 6),
            _buildActionBtn(
              icon: Icons.auto_awesome_mosaic_outlined,
              label: '自动切片',
              onTap: _showAutoSliceDialog,
            ),
            const SizedBox(width: 6),
            _buildActionBtn(
              icon: Icons.flag_outlined,
              label: '打标记 (M)',
              color: const Color(0xFFF59E0B),
              onTap: _promptAddMarker,
            ),
            const SizedBox(width: 12),
            const VerticalDivider(
              width: 1,
              indent: 10,
              endIndent: 10,
              color: Color(0xFF262B38),
            ),
            const SizedBox(width: 12),
            _buildActionBtn(
              icon: Icons.compress,
              label: '压缩空闲 (${_controller.header.idleTimeLimit ?? 2}s)',
              onTap: _showCompressIdleDialog,
            ),
            const SizedBox(width: 6),
            _buildActionBtn(
              icon: Icons.security_outlined,
              label: '敏感打码',
              onTap: _showRedactDialog,
            ),
            const SizedBox(width: 6),
            _buildActionBtn(
              icon: Icons.tune,
              label: '画布设置',
              onTap: _showHeaderSettingsDialog,
            ),
            const SizedBox(width: 12),
            const VerticalDivider(
              width: 1,
              indent: 10,
              endIndent: 10,
              color: Color(0xFF262B38),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.undo, size: 18),
              color: _controller.canUndo
                  ? Colors.white
                  : const Color(0xFF475569),
              tooltip: '撤销 (Ctrl+Z)',
              onPressed: _controller.canUndo ? _controller.undo : null,
            ),
            IconButton(
              icon: const Icon(Icons.redo, size: 18),
              color: _controller.canRedo
                  ? Colors.white
                  : const Color(0xFF475569),
              tooltip: '重做 (Ctrl+Shift+Z)',
              onPressed: _controller.canRedo ? _controller.redo : null,
            ),
            const SizedBox(width: 8),
            const Icon(Icons.zoom_out, size: 15, color: Color(0xFF94A3B8)),
            SizedBox(
              width: 100,
              child: Slider(
                value: _controller.timelineZoom,
                min: 16.0,
                max: 300.0,
                onChanged: _controller.setTimelineZoom,
              ),
            ),
            const Icon(Icons.zoom_in, size: 15, color: Color(0xFF94A3B8)),
            IconButton(
              icon: const Icon(Icons.fit_screen_outlined, size: 17),
              color: const Color(0xFF94A3B8),
              tooltip: '时间轴自适应窗口 (Shift+Z)',
              onPressed: _controller.fitTimelineToViewport,
            ),
            IconButton(
              icon: const Icon(Icons.keyboard_outlined, size: 18),
              color: const Color(0xFF94A3B8),
              tooltip: '快捷键列表 - 达芬奇模板 (?)',
              onPressed: _showShortcutsDialog,
            ),
            const SizedBox(width: 8),
            if (widget.onExport != null)
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0EA5E9),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                ),
                onPressed: _triggerExport,
                icon: const Icon(Icons.check_circle_outline, size: 16),
                label: Text(
                  widget.exportButtonLabel,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolChip({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    Color activeColor = const Color(0xFF0EA5E9),
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? activeColor : const Color(0xFF1E2433),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? activeColor : const Color(0xFF334155),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color color = const Color(0xFFE2E8F0),
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1E2433),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF334155)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLeftInspectorDock() {
    return Container(
      color: const Color(0xFF131722),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 38,
            color: const Color(0xFF181C26),
            child: Row(
              children: [
                _buildDockTab(0, Icons.tune, '片段属性'),
                _buildDockTab(
                  1,
                  Icons.flag_outlined,
                  '标记 (${_controller.markers.length})',
                ),
                _buildDockTab(2, Icons.list_alt, '事件帧/历史'),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF262B38)),
          Expanded(
            child: IndexedStack(
              index: _inspectorTabIndex,
              children: [
                _buildClipInspectorTab(),
                _buildMarkersInspectorTab(),
                _buildEventsAndHistoryTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDockTab(int index, IconData icon, String label) {
    final active = _inspectorTabIndex == index;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _inspectorTabIndex = index),
        child: Container(
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? const Color(0xFF38BDF8) : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 13,
                color: active
                    ? const Color(0xFF38BDF8)
                    : const Color(0xFF94A3B8),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    color: active ? Colors.white : const Color(0xFF94A3B8),
                    fontSize: 11,
                    fontWeight: active ? FontWeight.bold : FontWeight.normal,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClipInspectorTab() {
    final clip = _controller.selectedClip;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (clip != null) ...[
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: Color(clip.colorValue),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '当前选中: ${clip.name}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(
                  clip.muted ? Icons.visibility_off : Icons.visibility,
                  size: 16,
                  color: clip.muted ? Colors.orange : const Color(0xFF94A3B8),
                ),
                tooltip: clip.muted ? '启用该片段' : '禁用/静音该片段',
                onPressed: () => _controller.toggleClipMuted(clip.id),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1F2E),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF262B38)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '入点 (In): ${clip.sourceStart.toStringAsFixed(2)}s',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFCBD5E1),
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '出点 (Out): ${clip.sourceEnd.toStringAsFixed(2)}s',
                        textAlign: TextAlign.end,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFCBD5E1),
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '有效时长: ${clip.timelineDuration.toStringAsFixed(2)}s (含 ${clip.trimmedEvents.length} 帧事件)',
                  style: const TextStyle(
                    color: Color(0xFF38BDF8),
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
                const Divider(height: 18, color: Color(0xFF262B38)),
                Row(
                  children: [
                    const Text(
                      '片段变速:',
                      style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [0.5, 1.0, 1.5, 2.0, 4.0].map((spd) {
                          final active = (clip.speed - spd).abs() < 0.02;
                          return InkWell(
                            onTap: () => _controller.setClipSpeed(clip.id, spd),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: active
                                    ? const Color(0xFF0EA5E9)
                                    : const Color(0xFF0F131C),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: active
                                      ? const Color(0xFF38BDF8)
                                      : const Color(0xFF334155),
                                ),
                              ),
                              child: Text(
                                '${spd}x',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: active
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _controller.splitAtPlayhead,
                        icon: const Icon(Icons.content_cut, size: 14),
                        label: const Text(
                          '在播放头切分',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _controller.clips.length > 1
                            ? () => _controller.deleteClip(clip.id)
                            : null,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFF87171),
                        ),
                        icon: const Icon(Icons.delete_sweep_outlined, size: 14),
                        label: const Text(
                          '波纹删除',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _showClipEventsEditorDialog(clip.id),
                    icon: const Icon(Icons.edit_note, size: 15),
                    label: const Text(
                      '编辑片段输出 / 按键输入内容',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        const Text(
          '轨道片段序列 (Track T1 Clips)',
          style: TextStyle(
            color: Color(0xFF94A3B8),
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < _controller.clips.length; i++)
          _buildClipListTile(_controller.clips[i], i),
      ],
    );
  }

  Widget _buildClipListTile(AsciicastClip clip, int index) {
    final selected = _controller.selectedClipId == clip.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? const Color(0xFF1E293B) : const Color(0xFF161A24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(
            color: selected ? const Color(0xFF38BDF8) : const Color(0xFF262B38),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          onTap: () => _controller.selectClip(clip.id),
          leading: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: Color(clip.colorValue),
              shape: BoxShape.circle,
            ),
          ),
          title: Text(
            clip.name,
            style: TextStyle(
              color: clip.muted ? Colors.grey : Colors.white,
              fontSize: 12,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              decoration: clip.muted ? TextDecoration.lineThrough : null,
            ),
          ),
          subtitle: Text(
            '${clip.sourceStart.toStringAsFixed(1)}s - ${clip.sourceEnd.toStringAsFixed(1)}s · ${clip.speed}x',
            style: const TextStyle(
              color: Color(0xFF64748B),
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (index > 0)
                IconButton(
                  icon: const Icon(
                    Icons.arrow_upward,
                    size: 14,
                    color: Color(0xFF94A3B8),
                  ),
                  onPressed: () => _controller.moveClip(index, index - 1),
                ),
              if (index < _controller.clips.length - 1)
                IconButton(
                  icon: const Icon(
                    Icons.arrow_downward,
                    size: 14,
                    color: Color(0xFF94A3B8),
                  ),
                  onPressed: () => _controller.moveClip(index, index + 1),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMarkersInspectorTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFF59E0B),
                        foregroundColor: Colors.black,
                      ),
                      onPressed: _promptAddMarker,
                      icon: const Icon(Icons.add_location_alt, size: 15),
                      label: Text(
                        '在 ${_formatTimecode(_controller.playheadTime)} 打标记',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Material(
                type: MaterialType.transparency,
                child: SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    '遇到标记自动暂停 (pauseOnMarkers)',
                    style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 11),
                  ),
                  value: _controller.pauseOnMarkers,
                  onChanged: _controller.setPauseOnMarkers,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFF262B38)),
        Expanded(
          child: _controller.markers.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      '暂无标记。\n在关键命令处添加标记后，前端播放器启用 pauseOnMarkers: true 时会自动暂停，方便读者复制终端命令。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _controller.markers.length,
                  itemBuilder: (context, index) {
                    final marker = _controller.markers[index];
                    final selected = _controller.selectedMarkerId == marker.id;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Material(
                        color: selected
                            ? const Color(0xFF78350F).withValues(alpha: 0.4)
                            : const Color(0xFF161A24),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                          side: BorderSide(
                            color: selected
                                ? const Color(0xFFF59E0B)
                                : const Color(0xFF262B38),
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          onTap: () {
                            _controller.selectMarker(marker.id);
                            _controller.seek(marker.time);
                          },
                          leading: const Icon(
                            Icons.flag,
                            size: 16,
                            color: Color(0xFFF59E0B),
                          ),
                          title: Text(
                            marker.label,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            '${marker.time.toStringAsFixed(2)}s (${_formatTimecode(marker.time)})',
                            style: const TextStyle(
                              color: Color(0xFFFBBF24),
                              fontSize: 10,
                              fontFamily: 'monospace',
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(
                                  Icons.edit_outlined,
                                  size: 15,
                                  color: Color(0xFF94A3B8),
                                ),
                                tooltip: '编辑标记',
                                onPressed: () => _editMarkerDialog(marker),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 15,
                                  color: Color(0xFFF87171),
                                ),
                                tooltip: '删除标记',
                                onPressed: () =>
                                    _controller.deleteMarker(marker.id),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _editMarkerDialog(AsciicastMarker marker) async {
    final labelCtrl = TextEditingController(text: marker.label);
    final timeCtrl = TextEditingController(
      text: marker.time.toStringAsFixed(2),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑关键标记'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: labelCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '标记名称',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: timeCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: '时间点 (秒)',
                suffixText: 's',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == true) {
      _controller.updateMarker(
        marker.id,
        label: labelCtrl.text,
        time: double.tryParse(timeCtrl.text.trim()),
      );
    }
  }

  Widget _buildEventsAndHistoryTab() {
    final events = _controller.bakedEvents;
    final history = _controller.undoHistoryDescriptions;
    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        if (history.isNotEmpty) ...[
          const Text(
            '最近编辑历史 (Undo Stack)',
            style: TextStyle(
              color: Color(0xFF94A3B8),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          for (final desc in history.reversed.take(5))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  const Icon(Icons.history, size: 13, color: Color(0xFF38BDF8)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      desc,
                      style: const TextStyle(
                        color: Color(0xFFCBD5E1),
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 18, color: Color(0xFF262B38)),
        ],
        Row(
          children: [
            Expanded(
              child: Text(
                '事件帧列表 (共 ${events.length} 帧)',
                style: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: [
            for (final opt in const [
              ('all', '全部'),
              ('o', '终端输出 (o)'),
              ('i', '按键输入 (i)'),
            ])
              ChoiceChip(
                label: Text(opt.$2, style: const TextStyle(fontSize: 10)),
                selected: _eventFilterType == opt.$1,
                onSelected: (_) => setState(() => _eventFilterType = opt.$1),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
              ),
          ],
        ),
        const SizedBox(height: 6),
        for (final ev in events.where(
          (e) => _eventFilterType == 'all' || e.type == _eventFilterType,
        ))
          Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: (_controller.playheadTime - ev.timelineTime).abs() < 0.08
                  ? const Color(0xFF1E293B)
                  : const Color(0xFF161A24),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _controller.seek(ev.timelineTime),
                    onDoubleTap: () => _editRawEventDialog(ev),
                    child: Row(
                      children: [
                        Text(
                          '${ev.timelineTime.toStringAsFixed(2)}s',
                          style: const TextStyle(
                            color: Color(0xFF38BDF8),
                            fontSize: 10,
                            fontFamily: 'monospace',
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: ev.type == 'i'
                                ? const Color(0xFF065F46)
                                : const Color(0xFF1E3A8A),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            ev.type,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            ev.data
                                .replaceAll('\r', r'\r')
                                .replaceAll('\n', r'\n')
                                .replaceAll('\x1b', 'ESC'),
                            style: const TextStyle(
                              color: Color(0xFFCBD5E1),
                              fontSize: 10,
                              fontFamily: 'monospace',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.edit_note,
                    size: 14,
                    color: Color(0xFF64748B),
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 20,
                    minHeight: 20,
                  ),
                  onPressed: () => _editRawEventDialog(ev),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _escapeEventData(String raw) {
    return raw
        .replaceAll(r'\', r'\\')
        .replaceAll('\r', r'\r')
        .replaceAll('\n', r'\n')
        .replaceAll('\t', r'\t')
        .replaceAll('\x1b', r'\x1b');
  }

  String _unescapeEventData(String escaped) {
    final buf = StringBuffer();
    for (var i = 0; i < escaped.length; i++) {
      final ch = escaped[i];
      if (ch == r'\' && i + 1 < escaped.length) {
        final next = escaped[i + 1];
        if (next == r'\') {
          buf.write(r'\');
          i++;
          continue;
        }
        if (next == 'r') {
          buf.write('\r');
          i++;
          continue;
        }
        if (next == 'n') {
          buf.write('\n');
          i++;
          continue;
        }
        if (next == 't') {
          buf.write('\t');
          i++;
          continue;
        }
        if (next == 'x' && i + 3 < escaped.length) {
          final hex = escaped.substring(i + 2, i + 4);
          final code = int.tryParse(hex, radix: 16);
          if (code != null) {
            buf.writeCharCode(code);
            i += 3;
            continue;
          }
        }
      }
      buf.write(ch);
    }
    return buf.toString();
  }

  Future<void> _showClipEventsEditorDialog(String clipId) async {
    _controller.pause();
    var filterType = 'all';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final clipIdx = _controller.clips.indexWhere((c) => c.id == clipId);
          if (clipIdx < 0) {
            return const SizedBox.shrink();
          }
          final clip = _controller.clips[clipIdx];
          final items = clip.trimmedEvents
              .where((e) => filterType == 'all' || e.type == filterType)
              .toList(growable: false);

          return AlertDialog(
            title: Text('编辑片段内容 · ${clip.name}'),
            content: SizedBox(
              width: 560,
              height: 420,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final opt in const [
                        ('all', '全部事件'),
                        ('o', '终端输出 (o)'),
                        ('i', '按键输入 (i)'),
                      ])
                        ChoiceChip(
                          label: Text(
                            opt.$2,
                            style: const TextStyle(fontSize: 11),
                          ),
                          selected: filterType == opt.$1,
                          onSelected: (_) =>
                              setDialogState(() => filterType = opt.$1),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: items.isEmpty
                        ? const Center(
                            child: Text(
                              '当前筛选下暂无事件帧',
                              style: TextStyle(color: Color(0xFF94A3B8)),
                            ),
                          )
                        : ListView.separated(
                            itemCount: items.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (_, index) {
                              final ev = items[index];
                              return ListTile(
                                dense: true,
                                leading: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: ev.type == 'i'
                                        ? const Color(0xFF065F46)
                                        : const Color(0xFF1E3A8A),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    ev.type,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                                title: Text(
                                  _escapeEventData(ev.data),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                  ),
                                ),
                                subtitle: Text(
                                  '源时间: ${ev.time.toStringAsFixed(3)}s',
                                  style: const TextStyle(fontSize: 10),
                                ),
                                trailing: const Icon(Icons.edit_note, size: 18),
                                onTap: () async {
                                  await _editRawEventDialog((
                                    timelineTime: ev.time,
                                    type: ev.type,
                                    data: ev.data,
                                    clipId: clip.id,
                                    eventId: ev.id,
                                  ));
                                  setDialogState(() {});
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('完成'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _editRawEventDialog(BakedTimelineEvent ev) async {
    _controller.pause();
    final typeLabel = ev.type == 'i'
        ? '按键输入 (i)'
        : ev.type == 'o'
        ? '终端输出 (o)'
        : '事件帧 (${ev.type})';
    final result = await showDialog<({String action, String text})>(
      context: context,
      builder: (ctx) => _RawEventEditDialog(
        title: '编辑$typeLabel (@ ${ev.timelineTime.toStringAsFixed(2)}s)',
        initialText: _escapeEventData(ev.data),
      ),
    );
    if (result == null) return;
    if (result.action == 'save') {
      _controller.updateRawEvent(
        clipId: ev.clipId,
        eventId: ev.eventId,
        newData: _unescapeEventData(result.text),
      );
    } else if (result.action == 'delete') {
      _controller.deleteRawEvent(clipId: ev.clipId, eventId: ev.eventId);
    }
  }

  Widget _buildProgramMonitorSection() {
    return Container(
      color: const Color(0xFF0B0D14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Program Monitor Header
          Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            color: const Color(0xFF161A24),
            child: Row(
              children: [
                const Icon(
                  Icons.tv_outlined,
                  size: 15,
                  color: Color(0xFF38BDF8),
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '节目监视器 (termui_flutter 预览)',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Color(0xFFE2E8F0),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Theme selector
                DropdownButtonHideUnderline(
                  child: DropdownButton<TerminalPreviewTheme>(
                    value: _controller.previewTheme,
                    isDense: true,
                    dropdownColor: const Color(0xFF1E2433),
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                    items: TerminalPreviewTheme.values
                        .map(
                          (t) => DropdownMenuItem(
                            value: t,
                            child: Text('主题: ${t.label}'),
                          ),
                        )
                        .toList(),
                    onChanged: (val) {
                      if (val != null) _controller.setPreviewTheme(val);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(
                    Icons.text_decrease,
                    size: 15,
                    color: Color(0xFF94A3B8),
                  ),
                  tooltip: '缩小终端字号',
                  onPressed: () =>
                      _controller.setFontSize(_controller.fontSize - 1),
                ),
                Text(
                  '${_controller.fontSize.round()}pt',
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.text_increase,
                    size: 15,
                    color: Color(0xFF94A3B8),
                  ),
                  tooltip: '放大终端字号',
                  onPressed: () =>
                      _controller.setFontSize(_controller.fontSize + 1),
                ),
                const SizedBox(width: 6),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF065F46),
                    foregroundColor: const Color(0xFF6EE7B7),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _controller.jumpToFinalResult,
                  icon: const Icon(Icons.fast_forward, size: 14),
                  label: const Text(
                    '查看最终结果',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          // Pause on Marker Banner
          if (_controller.pausedAtMarkerLabel != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: const Color(0xFF78350F),
              child: Row(
                children: [
                  const Icon(Icons.flag, size: 15, color: Color(0xFFFDE047)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '已在标记处自动暂停：「${_controller.pausedAtMarkerLabel}」— 可直接框选终端文本复制',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      _controller.setPauseOnMarkers(false);
                      _controller.play();
                    },
                    icon: const Icon(
                      Icons.fast_forward,
                      size: 15,
                      color: Color(0xFFFDE68A),
                    ),
                    label: const Text(
                      '跳过标记暂停',
                      style: TextStyle(color: Color(0xFFFDE68A), fontSize: 12),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _controller.play,
                    icon: const Icon(
                      Icons.play_arrow,
                      size: 15,
                      color: Color(0xFFFDE047),
                    ),
                    label: const Text(
                      '继续播放',
                      style: TextStyle(color: Color(0xFFFDE047), fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          // Center Terminal Viewport
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: AsciicastTerminalPreview(controller: _controller),
            ),
          ),
          // Transport Controls Deck
          _buildTransportDeck(),
        ],
      ),
    );
  }

  Widget _buildTransportDeck() {
    final maxDur = _controller.totalDuration > 0
        ? _controller.totalDuration
        : 1.0;
    final cur = _controller.playheadTime.clamp(0.0, maxDur);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        color: Color(0xFF151922),
        border: Border(top: BorderSide(color: Color(0xFF262B38))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                _formatTimecode(cur),
                style: const TextStyle(
                  color: Color(0xFF38BDF8),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                  ),
                  child: Slider(
                    value: cur,
                    min: 0.0,
                    max: maxDur,
                    activeColor: const Color(0xFF0EA5E9),
                    inactiveColor: const Color(0xFF334155),
                    onChanged: (v) {
                      _controller.pause();
                      _controller.seek(v);
                    },
                  ),
                ),
              ),
              Text(
                _formatTimecode(_controller.totalDuration),
                style: const TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.skip_previous,
                              size: 18,
                              color: Colors.white70,
                            ),
                            tooltip: '回到开头 (Home)',
                            onPressed: _controller.jumpToStart,
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.bookmark_remove_outlined,
                              size: 17,
                              color: Color(0xFFF59E0B),
                            ),
                            tooltip: '上一个标记 (Shift+↑ / [)',
                            onPressed: _controller.markers.isEmpty
                                ? null
                                : _controller.jumpToPrevMarker,
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.navigate_before,
                              size: 20,
                              color: Colors.white70,
                            ),
                            tooltip: '上一帧 (← / ,)',
                            onPressed: _controller.stepBackwardFrame,
                          ),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF0EA5E9),
                              foregroundColor: Colors.white,
                            ),
                            onPressed: _controller.togglePlay,
                            icon: Icon(
                              _controller.isPlaying
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              size: 18,
                            ),
                            label: Text(
                              _controller.isPlaying ? '暂停' : '播放',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.navigate_next,
                              size: 20,
                              color: Colors.white70,
                            ),
                            tooltip: '下一帧 (→ / .)',
                            onPressed: _controller.stepForwardFrame,
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.bookmark_add_outlined,
                              size: 17,
                              color: Color(0xFFF59E0B),
                            ),
                            tooltip: '下一个标记 (Shift+↓ / ])',
                            onPressed: _controller.markers.isEmpty
                                ? null
                                : _controller.jumpToNextMarker,
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.skip_next,
                              size: 18,
                              color: Colors.white70,
                            ),
                            tooltip: '跳转到最终结果 (End)',
                            onPressed: _controller.jumpToFinalResult,
                          ),
                        ],
                      ),
                      // Speed controller & Loop toggle
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final spd in const [0.5, 1.0, 1.5, 2.0, 4.0])
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: InkWell(
                                onTap: () => _controller.setPlaybackSpeed(spd),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color:
                                        (_controller.playbackSpeed - spd)
                                                .abs() <
                                            0.02
                                        ? const Color(0xFF0EA5E9)
                                        : const Color(0xFF1E2433),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '${spd}x',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          IconButton(
                            icon: Icon(
                              _controller.pauseOnMarkers
                                  ? Icons.flag
                                  : Icons.outlined_flag,
                              size: 17,
                              color: _controller.pauseOnMarkers
                                  ? const Color(0xFFF59E0B)
                                  : const Color(0xFF64748B),
                            ),
                            tooltip: _controller.pauseOnMarkers
                                ? '遇到标记自动暂停：已开启 (点击跳过标记暂停，Ctrl+M)'
                                : '遇到标记自动暂停：已跳过 (点击恢复标记暂停，Ctrl+M)',
                            onPressed: () => _controller.setPauseOnMarkers(
                              !_controller.pauseOnMarkers,
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.repeat,
                              size: 17,
                              color: _controller.isLooping
                                  ? const Color(0xFF38BDF8)
                                  : const Color(0xFF64748B),
                            ),
                            tooltip: '循环播放 (Ctrl+L)',
                            onPressed: () =>
                                _controller.setLooping(!_controller.isLooping),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  String _formatTimecode(double seconds) {
    final safe = seconds.isFinite && seconds >= 0 ? seconds : 0.0;
    final mins = (safe ~/ 60).toString().padLeft(2, '0');
    final secs = (safe.floor() % 60).toString().padLeft(2, '0');
    final centis = ((safe - safe.floor()) * 100).round().clamp(0, 99);
    return '$mins:$secs.${centis.toString().padLeft(2, '0')}';
  }
}

/// Convenience fullscreen/modal dialog wrapper for launching [AsciicastEditor].
class AsciicastEditorDialog extends StatelessWidget {
  const AsciicastEditorDialog({
    super.key,
    this.initialCastContent,
    this.initialFileName = 'recording.cast',
    this.exportButtonLabel = '保存并导出 .cast',
  });

  final String? initialCastContent;
  final String initialFileName;
  final String exportButtonLabel;

  static Future<AsciicastEditorResult?> show(
    BuildContext context, {
    String? initialCastContent,
    String initialFileName = 'recording.cast',
    String exportButtonLabel = '保存并导出 .cast',
  }) {
    return showDialog<AsciicastEditorResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AsciicastEditorDialog(
        initialCastContent: initialCastContent,
        initialFileName: initialFileName,
        exportButtonLabel: exportButtonLabel,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: const Color(0xFF0D0F17),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: (screen.width - 32).clamp(320.0, 1480.0),
        height: (screen.height - 32).clamp(420.0, 920.0),
        child: Column(
          children: [
            Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              color: const Color(0xFF10131C),
              child: Row(
                children: [
                  const Icon(
                    Icons.terminal,
                    color: Color(0xFF38BDF8),
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Asciicast 非线性编辑器 (NLE) — $initialFileName',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(
                      Icons.close,
                      size: 16,
                      color: Color(0xFF94A3B8),
                    ),
                    label: const Text(
                      '关闭',
                      style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFF262B38)),
            Expanded(
              child: AsciicastEditor(
                initialCastContent: initialCastContent,
                initialFileName: initialFileName,
                exportButtonLabel: exportButtonLabel,
                onExport: (result) => Navigator.of(context).pop(result),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RawEventEditDialog extends StatefulWidget {
  const _RawEventEditDialog({required this.title, required this.initialText});

  final String title;
  final String initialText;

  @override
  State<_RawEventEditDialog> createState() => _RawEventEditDialogState();
}

class _RawEventEditDialogState extends State<_RawEventEditDialog> {
  late final TextEditingController _dataCtrl;

  @override
  void initState() {
    super.initState();
    _dataCtrl = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _dataCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: _dataCtrl,
          autofocus: true,
          maxLines: 5,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(
            labelText: '内容 (支持 \\r、\\n、\\t、\\x1b 转义序列)',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, (action: 'delete', text: '')),
          style: TextButton.styleFrom(foregroundColor: const Color(0xFFF87171)),
          child: const Text('删除此帧'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, (action: 'save', text: _dataCtrl.text)),
          child: const Text('保存修改'),
        ),
      ],
    );
  }
}
