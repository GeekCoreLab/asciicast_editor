import 'dart:math' as math;

import 'package:termui/ui/buffer.dart' as termui;
import 'package:termui/ui/color.dart' as termui_color;
import 'package:termui/ui/style.dart' as termui_style;

enum _ParserState {
  ground,
  escape,
  escapeIntermediate,
  csiEntry,
  csiParam,
  oscString,
  oscEscape,
  dcsOrApcString,
  dcsOrApcEscape,
}

class _SavedCursorState {
  const _SavedCursorState({
    required this.x,
    required this.y,
    required this.fg,
    required this.bg,
    required this.modifiers,
    required this.underlineColor,
    required this.pendingWrap,
    required this.originMode,
    required this.g0DecGraphics,
    required this.g1DecGraphics,
    required this.useG1,
  });

  final int x;
  final int y;
  final int fg;
  final int bg;
  final int modifiers;
  final int underlineColor;
  final bool pendingWrap;
  final bool originMode;
  final bool g0DecGraphics;
  final bool g1DecGraphics;
  final bool useG1;
}

/// Pure-Dart ANSI/VT100 virtual terminal emulator for rendering asciicast
/// output streams into a `termui` [termui.Buffer] across all platforms
/// including Web and WASM.
class VirtualTerminal {
  /// Creates a virtual terminal with [width] columns and [height] rows.
  VirtualTerminal({int width = 80, int height = 24})
    : _width = math.max(1, width),
      _height = math.max(1, height),
      _primaryBuffer = termui.Buffer.blank(
        math.max(1, width),
        math.max(1, height),
        defaultBlend: false,
      ),
      _alternateBuffer = termui.Buffer.blank(
        math.max(1, width),
        math.max(1, height),
        defaultBlend: false,
      ) {
    _resetState(clearBuffers: true);
  }

  static const Map<int, String> _decSpecialGraphics = <int, String>{
    0x60: '◆',
    0x61: '▒',
    0x62: '␉',
    0x63: '␌',
    0x64: '␍',
    0x65: '␊',
    0x66: '°',
    0x67: '±',
    0x68: '␤',
    0x69: '␋',
    0x6A: '┘',
    0x6B: '┐',
    0x6C: '┌',
    0x6D: '└',
    0x6E: '┼',
    0x6F: '⎺',
    0x70: '⎻',
    0x71: '─',
    0x72: '⎼',
    0x73: '⎽',
    0x74: '├',
    0x75: '┤',
    0x76: '┴',
    0x77: '┬',
    0x78: '│',
    0x79: '≤',
    0x7A: '≥',
    0x7B: 'π',
    0x7C: '≠',
    0x7D: '£',
    0x7E: '·',
  };

  int _width;
  int _height;
  termui.Buffer _primaryBuffer;
  termui.Buffer _alternateBuffer;
  bool _usingAltScreen = false;

  /// Current horizontal cursor position (0-based).
  int cursorX = 0;

  /// Current vertical cursor position (0-based).
  int cursorY = 0;

  bool _pendingWrap = false;
  bool _autoWrap = true;
  bool _originMode = false;
  bool _insertMode = false;
  bool _cursorVisible = true;

  int _scrollTop = 0;
  int _scrollBottom = 0;

  int _fg = 0;
  int _bg = 0;
  int _modifiers = termui_style.Modifier.none;
  int _underlineColor = 0;
  String? _activeUri;

  bool _g0DecGraphics = false;
  bool _g1DecGraphics = false;
  bool _useG1 = false;

  _SavedCursorState? _savedPrimaryCursor;
  _SavedCursorState? _savedAltCursor;

  _ParserState _parserState = _ParserState.ground;
  final StringBuffer _escIntermediates = StringBuffer();
  final StringBuffer _csiParams = StringBuffer();
  final StringBuffer _oscBuffer = StringBuffer();

  /// Terminal width in columns.
  int get width => _width;

  /// Terminal height in rows.
  int get height => _height;

  /// Whether the alternate screen buffer is currently active.
  bool get isUsingAlternateScreen => _usingAltScreen;

  /// Whether the cursor is currently visible.
  bool get cursorVisible => _cursorVisible;

  /// Active screen buffer (primary or alternate).
  termui.Buffer get buffer =>
      _usingAltScreen ? _alternateBuffer : _primaryBuffer;

  /// Resets terminal state and clears both screen buffers.
  void reset() {
    _resetState(clearBuffers: true);
  }

  /// Releases resources held by this virtual terminal.
  void dispose() {
    _escIntermediates.clear();
    _csiParams.clear();
    _oscBuffer.clear();
  }

  void _resetState({required bool clearBuffers}) {
    _usingAltScreen = false;
    cursorX = 0;
    cursorY = 0;
    _pendingWrap = false;
    _autoWrap = true;
    _originMode = false;
    _insertMode = false;
    _cursorVisible = true;
    _scrollTop = 0;
    _scrollBottom = _height - 1;
    _fg = 0;
    _bg = 0;
    _modifiers = termui_style.Modifier.none;
    _underlineColor = 0;
    _activeUri = null;
    _g0DecGraphics = false;
    _g1DecGraphics = false;
    _useG1 = false;
    _savedPrimaryCursor = null;
    _savedAltCursor = null;
    _parserState = _ParserState.ground;
    _escIntermediates.clear();
    _csiParams.clear();
    _oscBuffer.clear();

    if (clearBuffers) {
      _clearBuffer(_primaryBuffer);
      _clearBuffer(_alternateBuffer);
    }
  }

  void _clearBuffer(termui.Buffer target) {
    target.fillAttributes(
      char: ' ',
      fg: 0,
      bg: 0,
      modifiers: termui_style.Modifier.none,
    );
    target.clearMetadata();
  }

  /// Resizes both primary and alternate buffers to [newWidth] x [newHeight].
  void resize(int newWidth, int newHeight) {
    final w = math.max(1, newWidth);
    final h = math.max(1, newHeight);
    if (w == _width && h == _height) return;

    _primaryBuffer = _resizeBuffer(_primaryBuffer, w, h);
    _alternateBuffer = _resizeBuffer(_alternateBuffer, w, h);
    _width = w;
    _height = h;
    _scrollTop = 0;
    _scrollBottom = _height - 1;
    cursorX = cursorX.clamp(0, _width - 1);
    cursorY = cursorY.clamp(0, _height - 1);
    _pendingWrap = false;
  }

  termui.Buffer _resizeBuffer(termui.Buffer oldBuf, int newW, int newH) {
    final next = termui.Buffer.blank(newW, newH, defaultBlend: false);
    _clearBuffer(next);
    final copyW = math.min(oldBuf.width, newW);
    final copyH = math.min(oldBuf.height, newH);
    for (var y = 0; y < copyH; y++) {
      for (var x = 0; x < copyW; x++) {
        next.setCell(
          x,
          y,
          oldBuf.getCharacter(x, y),
          oldBuf.getForeground(x, y),
          oldBuf.getBackground(x, y),
          oldBuf.getModifiers(x, y),
          blend: false,
          underlineColor: oldBuf.getUnderlineColor(x, y),
          uri: oldBuf.getUri(x, y),
        );
      }
    }
    return next;
  }

  /// Returns a snapshot [termui.Buffer] of the active screen for rendering.
  termui.Buffer renderBuffer([termui.Buffer? target]) {
    final src = buffer;
    final out =
        (target != null && target.width == _width && target.height == _height)
        ? target
        : termui.Buffer.blank(_width, _height, defaultBlend: false);
    out.characters.setRange(0, src.characters.length, src.characters);
    out.attributes.setRange(0, src.attributes.length, src.attributes);
    out.copyCellAuxRangeFrom(src, 0, 0, _width * _height);
    return out;
  }

  /// Processes an ANSI/VT100 output string and updates the active screen buffer.
  void writeString(String data) {
    if (data.isEmpty) return;

    for (final rune in data.runes) {
      _processRune(rune);
    }
  }

  void _processRune(int rune) {
    // Handle C0 control characters inside OSC / DCS / APC strings too.
    switch (_parserState) {
      case _ParserState.oscString:
        if (rune == 0x07) {
          _handleOsc(_oscBuffer.toString());
          _oscBuffer.clear();
          _parserState = _ParserState.ground;
        } else if (rune == 0x1B) {
          _parserState = _ParserState.oscEscape;
        } else if (rune == 0x9C) {
          _handleOsc(_oscBuffer.toString());
          _oscBuffer.clear();
          _parserState = _ParserState.ground;
        } else if (rune >= 0x20 || rune == 0x09) {
          _oscBuffer.writeCharCode(rune);
        }
        return;

      case _ParserState.oscEscape:
        if (rune == 0x5C) {
          // ST = ESC \
          _handleOsc(_oscBuffer.toString());
          _oscBuffer.clear();
          _parserState = _ParserState.ground;
        } else {
          _oscBuffer.clear();
          _parserState = _ParserState.escape;
          _processEscapeRune(rune);
        }
        return;

      case _ParserState.dcsOrApcString:
        if (rune == 0x1B) {
          _parserState = _ParserState.dcsOrApcEscape;
        } else if (rune == 0x9C || rune == 0x07) {
          _parserState = _ParserState.ground;
        }
        return;

      case _ParserState.dcsOrApcEscape:
        if (rune == 0x5C) {
          _parserState = _ParserState.ground;
        } else {
          _parserState = _ParserState.escape;
          _processEscapeRune(rune);
        }
        return;

      case _ParserState.escape:
        _processEscapeRune(rune);
        return;

      case _ParserState.escapeIntermediate:
        _processEscapeIntermediateRune(rune);
        return;

      case _ParserState.csiEntry:
      case _ParserState.csiParam:
        if (rune == 0x1B) {
          _csiParams.clear();
          _parserState = _ParserState.escape;
          return;
        }
        if (rune < 0x20) {
          _executeC0(rune);
          return;
        }
        if (rune >= 0x40 && rune <= 0x7E) {
          _dispatchCsi(_csiParams.toString(), rune);
          _csiParams.clear();
          _parserState = _ParserState.ground;
        } else {
          _csiParams.writeCharCode(rune);
          _parserState = _ParserState.csiParam;
        }
        return;

      case _ParserState.ground:
        if (rune == 0x1B) {
          _parserState = _ParserState.escape;
        } else if (rune < 0x20 || rune == 0x7F) {
          _executeC0(rune);
        } else if (rune >= 0x80 && rune <= 0x9F) {
          // C1 control codes
          if (rune == 0x9B) {
            _csiParams.clear();
            _parserState = _ParserState.csiEntry;
          } else if (rune == 0x9D) {
            _oscBuffer.clear();
            _parserState = _ParserState.oscString;
          } else if (rune == 0x90 ||
              rune == 0x98 ||
              rune == 0x9E ||
              rune == 0x9F) {
            _parserState = _ParserState.dcsOrApcString;
          }
        } else {
          _putChar(rune);
        }
        return;
    }
  }

  void _processEscapeRune(int rune) {
    if (rune == 0x5B) {
      // '[' -> CSI
      _csiParams.clear();
      _parserState = _ParserState.csiEntry;
    } else if (rune == 0x5D) {
      // ']' -> OSC
      _oscBuffer.clear();
      _parserState = _ParserState.oscString;
    } else if (rune == 0x50 || rune == 0x5F || rune == 0x58 || rune == 0x5E) {
      // 'P' (DCS), '_' (APC), 'X' (SOS), '^' (PM)
      _parserState = _ParserState.dcsOrApcString;
    } else if (rune >= 0x20 && rune <= 0x2F) {
      _escIntermediates.clear();
      _escIntermediates.writeCharCode(rune);
      _parserState = _ParserState.escapeIntermediate;
    } else {
      _dispatchEscape(rune);
      _parserState = _ParserState.ground;
    }
  }

  void _processEscapeIntermediateRune(int rune) {
    if (rune >= 0x20 && rune <= 0x2F) {
      _escIntermediates.writeCharCode(rune);
    } else if (rune >= 0x30 && rune <= 0x7E) {
      final inter = _escIntermediates.toString();
      _escIntermediates.clear();
      _parserState = _ParserState.ground;
      if (inter == '(') {
        _g0DecGraphics = rune == 0x30; // '0' = DEC Special Graphics
      } else if (inter == ')') {
        _g1DecGraphics = rune == 0x30;
      }
    } else {
      _escIntermediates.clear();
      _parserState = _ParserState.ground;
    }
  }

  void _dispatchEscape(int rune) {
    switch (rune) {
      case 0x37: // '7' DECSC
        _saveCursor();
      case 0x38: // '8' DECRC
        _restoreCursor();
      case 0x44: // 'D' IND
        _lineFeed();
      case 0x45: // 'E' NEL
        cursorX = 0;
        _pendingWrap = false;
        _lineFeed();
      case 0x4D: // 'M' RI
        _reverseIndex();
      case 0x63: // 'c' RIS
        reset();
    }
  }

  void _executeC0(int rune) {
    switch (rune) {
      case 0x08: // BS
        if (_pendingWrap) {
          _pendingWrap = false;
        } else if (cursorX > 0) {
          cursorX--;
        }
      case 0x09: // TAB
        _pendingWrap = false;
        final nextTab = ((cursorX ~/ 8) + 1) * 8;
        cursorX = math.min(_width - 1, nextTab);
      case 0x0A: // LF
      case 0x0B: // VT
      case 0x0C: // FF
        _pendingWrap = false;
        _lineFeed();
      case 0x0D: // CR
        cursorX = 0;
        _pendingWrap = false;
      case 0x0E: // SO
        _useG1 = true;
      case 0x0F: // SI
        _useG1 = false;
    }
  }

  void _putChar(int rune) {
    final useDec = _useG1 ? _g1DecGraphics : _g0DecGraphics;
    final ch = (useDec && _decSpecialGraphics.containsKey(rune))
        ? _decSpecialGraphics[rune]!
        : String.fromCharCode(rune);
    final charWidth = _runeDisplayWidth(rune);

    if (charWidth == 0) {
      // Combining mark: attach to previous cell if available.
      final targetX = _pendingWrap
          ? _width - 1
          : (cursorX > 0 ? cursorX - 1 : 0);
      final existing = buffer.getCharacter(targetX, cursorY);
      if (existing.isNotEmpty) {
        buffer.setCell(
          targetX,
          cursorY,
          '$existing$ch',
          buffer.getForeground(targetX, cursorY),
          buffer.getBackground(targetX, cursorY),
          buffer.getModifiers(targetX, cursorY),
          blend: false,
          underlineColor: buffer.getUnderlineColor(targetX, cursorY),
          uri: buffer.getUri(targetX, cursorY),
        );
      }
      return;
    }

    if (_pendingWrap) {
      if (_autoWrap) {
        cursorX = 0;
        _lineFeed();
      }
      _pendingWrap = false;
    }

    if (charWidth == 2 && cursorX == _width - 1) {
      if (_autoWrap) {
        _setEmptyCell(cursorX, cursorY);
        cursorX = 0;
        _lineFeed();
      } else {
        return;
      }
    }

    if (_insertMode) {
      _insertBlankChars(charWidth);
    }

    buffer.setCell(
      cursorX,
      cursorY,
      ch,
      _fg,
      _bg,
      _modifiers,
      blend: false,
      underlineColor: _underlineColor,
      uri: _activeUri,
    );

    if (charWidth == 2 && cursorX + 1 < _width) {
      // Mark trailing cell of wide glyph with empty string so termui renders 2-cell glyph cleanly.
      buffer.setCell(
        cursorX + 1,
        cursorY,
        '',
        _fg,
        _bg,
        _modifiers,
        blend: false,
        underlineColor: _underlineColor,
        uri: _activeUri,
      );
    }

    final nextX = cursorX + charWidth;
    if (nextX >= _width) {
      cursorX = _width - 1;
      _pendingWrap = _autoWrap;
    } else {
      cursorX = nextX;
    }
  }

  void _setEmptyCell(int x, int y) {
    buffer.setCell(x, y, ' ', 0, _bg, termui_style.Modifier.none, blend: false);
  }

  void _lineFeed() {
    if (cursorY == _scrollBottom) {
      _scrollUp(_scrollTop, _scrollBottom, 1);
    } else if (cursorY < _height - 1) {
      cursorY++;
    }
  }

  void _reverseIndex() {
    if (cursorY == _scrollTop) {
      _scrollDown(_scrollTop, _scrollBottom, 1);
    } else if (cursorY > 0) {
      cursorY--;
    }
  }

  void _scrollUp(int top, int bottom, int lines) {
    final count = math.min(lines, bottom - top + 1);
    if (count <= 0) return;
    final buf = buffer;
    for (var y = top; y <= bottom - count; y++) {
      _copyRow(buf, y, y + count);
    }
    for (var y = bottom - count + 1; y <= bottom; y++) {
      _clearRow(buf, y);
    }
  }

  void _scrollDown(int top, int bottom, int lines) {
    final count = math.min(lines, bottom - top + 1);
    if (count <= 0) return;
    final buf = buffer;
    for (var y = bottom; y >= top + count; y--) {
      _copyRow(buf, y, y - count);
    }
    for (var y = top; y < top + count; y++) {
      _clearRow(buf, y);
    }
  }

  void _copyRow(termui.Buffer buf, int dstY, int srcY) {
    for (var x = 0; x < _width; x++) {
      buf.setCell(
        x,
        dstY,
        buf.getCharacter(x, srcY),
        buf.getForeground(x, srcY),
        buf.getBackground(x, srcY),
        buf.getModifiers(x, srcY),
        blend: false,
        underlineColor: buf.getUnderlineColor(x, srcY),
        uri: buf.getUri(x, srcY),
      );
    }
  }

  void _clearRow(termui.Buffer buf, int y) {
    for (var x = 0; x < _width; x++) {
      buf.setCell(x, y, ' ', 0, _bg, termui_style.Modifier.none, blend: false);
    }
  }

  void _insertBlankChars(int count) {
    final n = math.min(count, _width - cursorX);
    if (n <= 0) return;
    final buf = buffer;
    for (var x = _width - 1; x >= cursorX + n; x--) {
      final srcX = x - n;
      buf.setCell(
        x,
        cursorY,
        buf.getCharacter(srcX, cursorY),
        buf.getForeground(srcX, cursorY),
        buf.getBackground(srcX, cursorY),
        buf.getModifiers(srcX, cursorY),
        blend: false,
        underlineColor: buf.getUnderlineColor(srcX, cursorY),
        uri: buf.getUri(srcX, cursorY),
      );
    }
    for (var x = cursorX; x < cursorX + n; x++) {
      _setEmptyCell(x, cursorY);
    }
  }

  void _deleteChars(int count) {
    final n = math.min(count, _width - cursorX);
    if (n <= 0) return;
    final buf = buffer;
    for (var x = cursorX; x < _width - n; x++) {
      final srcX = x + n;
      buf.setCell(
        x,
        cursorY,
        buf.getCharacter(srcX, cursorY),
        buf.getForeground(srcX, cursorY),
        buf.getBackground(srcX, cursorY),
        buf.getModifiers(srcX, cursorY),
        blend: false,
        underlineColor: buf.getUnderlineColor(srcX, cursorY),
        uri: buf.getUri(srcX, cursorY),
      );
    }
    for (var x = _width - n; x < _width; x++) {
      _setEmptyCell(x, cursorY);
    }
  }

  void _dispatchCsi(String rawParams, int finalByte) {
    var privatePrefix = '';
    var paramStr = rawParams;
    if (paramStr.startsWith('?') ||
        paramStr.startsWith('>') ||
        paramStr.startsWith('!') ||
        paramStr.startsWith('=')) {
      privatePrefix = paramStr[0];
      paramStr = paramStr.substring(1);
    }

    // Strip any trailing intermediate bytes (e.g. space before 'q' in DECSCUSR).
    final cleaned = StringBuffer();
    for (var i = 0; i < paramStr.length; i++) {
      final c = paramStr.codeUnitAt(i);
      if ((c >= 0x30 && c <= 0x39) || c == 0x3B || c == 0x3A) {
        cleaned.writeCharCode(c);
      }
    }
    final cleanParams = cleaned.toString();
    final parts = cleanParams.isEmpty
        ? const <String>[]
        : cleanParams.split(';');
    int param(int idx, int defaultVal) {
      if (idx >= parts.length || parts[idx].isEmpty) return defaultVal;
      return int.tryParse(parts[idx].split(':').first) ?? defaultVal;
    }

    if (privatePrefix == '?') {
      final modeValues = parts
          .map((e) => int.tryParse(e))
          .whereType<int>()
          .toList();
      if (finalByte == 0x68) {
        // 'h' DECSET
        for (final m in modeValues) {
          _setPrivateMode(m, true);
        }
      } else if (finalByte == 0x6C) {
        // 'l' DECRST
        for (final m in modeValues) {
          _setPrivateMode(m, false);
        }
      }
      return;
    }

    if (privatePrefix.isNotEmpty) return;

    switch (finalByte) {
      case 0x41: // 'A' CUU
        final n = math.max(1, param(0, 1));
        final minRow = _originMode ? _scrollTop : 0;
        cursorY = math.max(minRow, cursorY - n);
        _pendingWrap = false;
      case 0x42: // 'B' CUD
        final n = math.max(1, param(0, 1));
        final maxRow = _originMode ? _scrollBottom : _height - 1;
        cursorY = math.min(maxRow, cursorY + n);
        _pendingWrap = false;
      case 0x43: // 'C' CUF
        final n = math.max(1, param(0, 1));
        cursorX = math.min(_width - 1, cursorX + n);
        _pendingWrap = false;
      case 0x44: // 'D' CUB
        final n = math.max(1, param(0, 1));
        cursorX = math.max(0, cursorX - n);
        _pendingWrap = false;
      case 0x45: // 'E' CNL
        final n = math.max(1, param(0, 1));
        cursorX = 0;
        cursorY = math.min(_height - 1, cursorY + n);
        _pendingWrap = false;
      case 0x46: // 'F' CPL
        final n = math.max(1, param(0, 1));
        cursorX = 0;
        cursorY = math.max(0, cursorY - n);
        _pendingWrap = false;
      case 0x47: // 'G' CHA
        final col = math.max(1, param(0, 1)) - 1;
        cursorX = col.clamp(0, _width - 1);
        _pendingWrap = false;
      case 0x48: // 'H' CUP
      case 0x66: // 'f' HVP
        final row = math.max(1, param(0, 1)) - 1;
        final col = math.max(1, param(1, 1)) - 1;
        final baseRow = _originMode ? _scrollTop : 0;
        final maxRow = _originMode ? _scrollBottom : _height - 1;
        cursorY = (baseRow + row).clamp(baseRow, maxRow);
        cursorX = col.clamp(0, _width - 1);
        _pendingWrap = false;
      case 0x4A: // 'J' ED
        _eraseInDisplay(param(0, 0));
      case 0x4B: // 'K' EL
        _eraseInLine(param(0, 0));
      case 0x4C: // 'L' IL
        if (cursorY >= _scrollTop && cursorY <= _scrollBottom) {
          _scrollDown(cursorY, _scrollBottom, math.max(1, param(0, 1)));
        }
      case 0x4D: // 'M' DL
        if (cursorY >= _scrollTop && cursorY <= _scrollBottom) {
          _scrollUp(cursorY, _scrollBottom, math.max(1, param(0, 1)));
        }
      case 0x50: // 'P' DCH
        _deleteChars(math.max(1, param(0, 1)));
      case 0x53: // 'S' SU
        _scrollUp(_scrollTop, _scrollBottom, math.max(1, param(0, 1)));
      case 0x54: // 'T' SD
        _scrollDown(_scrollTop, _scrollBottom, math.max(1, param(0, 1)));
      case 0x58: // 'X' ECH
        final n = math.min(math.max(1, param(0, 1)), _width - cursorX);
        for (var x = cursorX; x < cursorX + n; x++) {
          _setEmptyCell(x, cursorY);
        }
      case 0x40: // '@' ICH
        _insertBlankChars(math.max(1, param(0, 1)));
      case 0x64: // 'd' VPA
        final row = math.max(1, param(0, 1)) - 1;
        cursorY = row.clamp(0, _height - 1);
        _pendingWrap = false;
      case 0x68: // 'h' SM
        if (param(0, 0) == 4) _insertMode = true;
      case 0x6C: // 'l' RM
        if (param(0, 0) == 4) _insertMode = false;
      case 0x6D: // 'm' SGR
        _applySgr(parts);
      case 0x72: // 'r' DECSTBM
        final top = (math.max(1, param(0, 1)) - 1).clamp(0, _height - 1);
        final bottom = (math.max(1, param(1, _height)) - 1).clamp(
          0,
          _height - 1,
        );
        if (top < bottom) {
          _scrollTop = top;
          _scrollBottom = bottom;
        } else {
          _scrollTop = 0;
          _scrollBottom = _height - 1;
        }
        cursorX = 0;
        cursorY = _originMode ? _scrollTop : 0;
        _pendingWrap = false;
      case 0x73: // 's' SCP
        _saveCursor();
      case 0x75: // 'u' RCP
        _restoreCursor();
    }
  }

  void _setPrivateMode(int mode, bool enabled) {
    switch (mode) {
      case 6: // DECOM
        _originMode = enabled;
        cursorX = 0;
        cursorY = _originMode ? _scrollTop : 0;
        _pendingWrap = false;
      case 7: // DECAWM
        _autoWrap = enabled;
      case 25: // DECTCEM
        _cursorVisible = enabled;
      case 47:
      case 1047:
        _switchAltScreen(enabled, saveCursor: false, clearAlt: true);
      case 1049:
        _switchAltScreen(enabled, saveCursor: true, clearAlt: true);
    }
  }

  void _switchAltScreen(
    bool enable, {
    required bool saveCursor,
    required bool clearAlt,
  }) {
    if (enable == _usingAltScreen) return;
    if (enable) {
      if (saveCursor) _saveCursor();
      _usingAltScreen = true;
      if (clearAlt) {
        _clearBuffer(_alternateBuffer);
      }
    } else {
      _usingAltScreen = false;
      if (saveCursor) _restoreCursor();
    }
    _scrollTop = 0;
    _scrollBottom = _height - 1;
    _pendingWrap = false;
  }

  void _saveCursor() {
    final snapshot = _SavedCursorState(
      x: cursorX,
      y: cursorY,
      fg: _fg,
      bg: _bg,
      modifiers: _modifiers,
      underlineColor: _underlineColor,
      pendingWrap: _pendingWrap,
      originMode: _originMode,
      g0DecGraphics: _g0DecGraphics,
      g1DecGraphics: _g1DecGraphics,
      useG1: _useG1,
    );
    if (_usingAltScreen) {
      _savedAltCursor = snapshot;
    } else {
      _savedPrimaryCursor = snapshot;
    }
  }

  void _restoreCursor() {
    final snapshot = _usingAltScreen ? _savedAltCursor : _savedPrimaryCursor;
    if (snapshot == null) return;
    cursorX = snapshot.x.clamp(0, _width - 1);
    cursorY = snapshot.y.clamp(0, _height - 1);
    _fg = snapshot.fg;
    _bg = snapshot.bg;
    _modifiers = snapshot.modifiers;
    _underlineColor = snapshot.underlineColor;
    _pendingWrap = snapshot.pendingWrap;
    _originMode = snapshot.originMode;
    _g0DecGraphics = snapshot.g0DecGraphics;
    _g1DecGraphics = snapshot.g1DecGraphics;
    _useG1 = snapshot.useG1;
  }

  void _eraseInDisplay(int mode) {
    final buf = buffer;
    switch (mode) {
      case 0: // cursor to end
        _eraseInLine(0);
        for (var y = cursorY + 1; y < _height; y++) {
          _clearRow(buf, y);
        }
      case 1: // start to cursor
        for (var y = 0; y < cursorY; y++) {
          _clearRow(buf, y);
        }
        _eraseInLine(1);
      case 2:
      case 3:
        for (var y = 0; y < _height; y++) {
          _clearRow(buf, y);
        }
    }
  }

  void _eraseInLine(int mode) {
    switch (mode) {
      case 0: // cursor to end
        for (var x = cursorX; x < _width; x++) {
          _setEmptyCell(x, cursorY);
        }
      case 1: // start to cursor
        for (var x = 0; x <= cursorX && x < _width; x++) {
          _setEmptyCell(x, cursorY);
        }
      case 2: // entire line
        _clearRow(buffer, cursorY);
    }
  }

  void _applySgr(List<String> rawParts) {
    if (rawParts.isEmpty) {
      _resetAttributes();
      return;
    }

    var i = 0;
    while (i < rawParts.length) {
      final token = rawParts[i];
      if (token.isEmpty) {
        _resetAttributes();
        i++;
        continue;
      }

      if (token.contains(':')) {
        final sub = token.split(':').map((e) => int.tryParse(e) ?? 0).toList();
        final code = sub.first;
        if (code == 4) {
          final style = sub.length > 1 ? sub[1] : 1;
          if (style == 0) {
            _modifiers &= ~termui_style.Modifier.underline;
          } else {
            _modifiers |= termui_style.Modifier.underline;
          }
        } else if (code == 38 || code == 48 || code == 58) {
          _applyExtendedColor(code, sub.sublist(1));
        }
        i++;
        continue;
      }

      final code = int.tryParse(token);
      if (code == null) {
        i++;
        continue;
      }

      switch (code) {
        case 0:
          _resetAttributes();
        case 1:
          _modifiers |= termui_style.Modifier.bold;
        case 2:
          _modifiers |= termui_style.Modifier.dim;
        case 3:
          _modifiers |= termui_style.Modifier.italic;
        case 4:
          _modifiers |= termui_style.Modifier.underline;
        case 5:
        case 6:
          _modifiers |= termui_style.Modifier.blink;
        case 7:
          _modifiers |= termui_style.Modifier.reverse;
        case 8:
          _modifiers |= termui_style.Modifier.hidden;
        case 9:
          _modifiers |= termui_style.Modifier.crossedOut;
        case 21:
          _modifiers |= termui_style.Modifier.underline;
        case 22:
          _modifiers &=
              ~(termui_style.Modifier.bold | termui_style.Modifier.dim);
        case 23:
          _modifiers &= ~termui_style.Modifier.italic;
        case 24:
          _modifiers &= ~termui_style.Modifier.underline;
        case 25:
          _modifiers &= ~termui_style.Modifier.blink;
        case 27:
          _modifiers &= ~termui_style.Modifier.reverse;
        case 28:
          _modifiers &= ~termui_style.Modifier.hidden;
        case 29:
          _modifiers &= ~termui_style.Modifier.crossedOut;
        case >= 30 && <= 37:
          _fg = termui_color.Color.ansi(code - 30);
        case 39:
          _fg = 0;
        case >= 40 && <= 47:
          _bg = termui_color.Color.ansi(code - 40);
        case 49:
          _bg = 0;
        case 59:
          _underlineColor = 0;
        case >= 90 && <= 97:
          _fg = termui_color.Color.ansi(code - 90 + 8);
        case >= 100 && <= 107:
          _bg = termui_color.Color.ansi(code - 100 + 8);
        case 38:
        case 48:
        case 58:
          final mode = i + 1 < rawParts.length
              ? int.tryParse(rawParts[i + 1])
              : null;
          if (mode == 5 && i + 2 < rawParts.length) {
            final idx = (int.tryParse(rawParts[i + 2]) ?? 0).clamp(0, 255);
            _setColorTarget(code, termui_color.Color.ansi(idx));
            i += 2;
          } else if (mode == 2 && i + 4 < rawParts.length) {
            final r = (int.tryParse(rawParts[i + 2]) ?? 0).clamp(0, 255);
            final g = (int.tryParse(rawParts[i + 3]) ?? 0).clamp(0, 255);
            final b = (int.tryParse(rawParts[i + 4]) ?? 0).clamp(0, 255);
            _setColorTarget(code, termui_color.Color(r, g, b));
            i += 4;
          }
      }
      i++;
    }
  }

  void _applyExtendedColor(int target, List<int> args) {
    if (args.isEmpty) return;
    if (args[0] == 5 && args.length >= 2) {
      _setColorTarget(target, termui_color.Color.ansi(args[1].clamp(0, 255)));
    } else if (args[0] == 2) {
      final offset = args.length >= 5 ? 2 : 1;
      if (args.length >= offset + 3) {
        final r = args[offset].clamp(0, 255);
        final g = args[offset + 1].clamp(0, 255);
        final b = args[offset + 2].clamp(0, 255);
        _setColorTarget(target, termui_color.Color(r, g, b));
      }
    }
  }

  void _setColorTarget(int target, int colorValue) {
    if (target == 38) {
      _fg = colorValue;
    } else if (target == 48) {
      _bg = colorValue;
    } else if (target == 58) {
      _underlineColor = colorValue;
    }
  }

  void _resetAttributes() {
    _fg = 0;
    _bg = 0;
    _modifiers = termui_style.Modifier.none;
    _underlineColor = 0;
  }

  void _handleOsc(String payload) {
    // Support OSC 8 hyperlinks: 8;<params>;<uri>
    if (!payload.startsWith('8;')) return;
    final secondSep = payload.indexOf(';', 2);
    if (secondSep < 0) return;
    final uri = payload.substring(secondSep + 1);
    _activeUri = uri.isEmpty ? null : uri;
  }

  static int _runeDisplayWidth(int rune) {
    // Combining marks and zero-width characters
    if (rune == 0 ||
        (rune >= 0x0300 && rune <= 0x036F) ||
        (rune >= 0x1AB0 && rune <= 0x1AFF) ||
        (rune >= 0x1DC0 && rune <= 0x1DFF) ||
        (rune >= 0x20D0 && rune <= 0x20FF) ||
        (rune >= 0xFE00 && rune <= 0xFE0F) ||
        (rune >= 0xFE20 && rune <= 0xFE2F) ||
        rune == 0x200B ||
        rune == 0x200C ||
        rune == 0x200D) {
      return 0;
    }

    // East Asian Wide / Fullwidth and common Emoji blocks
    if ((rune >= 0x1100 && rune <= 0x115F) ||
        rune == 0x2329 ||
        rune == 0x232A ||
        (rune >= 0x2E80 && rune <= 0xA4CF && rune != 0x303F) ||
        (rune >= 0xAC00 && rune <= 0xD7A3) ||
        (rune >= 0xF900 && rune <= 0xFAFF) ||
        (rune >= 0xFE10 && rune <= 0xFE19) ||
        (rune >= 0xFE30 && rune <= 0xFE6F) ||
        (rune >= 0xFF00 && rune <= 0xFF60) ||
        (rune >= 0xFFE0 && rune <= 0xFFE6) ||
        (rune >= 0x1F300 && rune <= 0x1FAFF) ||
        (rune >= 0x20000 && rune <= 0x3FFFF)) {
      return 2;
    }

    return 1;
  }
}
