// Built-in performance overlay data.

import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'morphos_atlas.dart';

/// Rolling performance numbers for one field, plus the overlay paragraph.
final class MorphPerfStats {
  /// Creates empty stats.
  MorphPerfStats();

  final Stopwatch _clock = Stopwatch()..start();

  /// Smoothed Dart-side paint cost in milliseconds.
  double paintMs = 0;

  /// Smoothed frame rate while animating.
  double fps = 0;

  /// Draw calls in the last paint.
  int drawCalls = 0;

  /// Nodes in the last paint.
  int nodes = 0;

  /// Nodes skipped in the last paint because they were off screen.
  int culled = 0;

  /// Whether the field was animating at the last paint.
  bool animating = false;

  /// Time the last spec change took to apply (matching, buffers, paint
  /// order, caches), in microseconds.
  int lastApplyMicros = 0;

  ui.Paragraph? _paragraph;
  int _builtAt = -1000000;

  /// Minimum time between overlay text rebuilds.
  static const int rebuildIntervalMicros = 250000;

  /// Records the gap between two animation frames.
  void recordFrameInterval(double seconds) {
    if (seconds <= 0) return;
    final double f = 1 / seconds;
    fps = fps == 0 ? f : fps * 0.9 + f * 0.1;
  }

  /// Records one paint.
  void recordPaint(int micros, int draws, int nodeCount, bool isAnimating) {
    final double ms = micros / 1000;
    paintMs = paintMs == 0 ? ms : paintMs * 0.9 + ms * 0.1;
    drawCalls = draws;
    nodes = nodeCount;
    animating = isAnimating;
  }

  /// The overlay text, rebuilt at most every [rebuildIntervalMicros].
  ui.Paragraph paragraph() {
    final int now = _clock.elapsedMicroseconds;
    final ui.Paragraph? cached = _paragraph;
    if (cached != null && now - _builtAt < rebuildIntervalMicros) return cached;
    cached?.dispose();
    if (cached != null) MorphDebugStats.liveParagraphs--;
    final ui.ParagraphBuilder b =
        ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 11))
          ..pushStyle(
            ui.TextStyle(
              color: const Color(0xFFFFFFFF),
              fontFeatures: const <ui.FontFeature>[
                ui.FontFeature.tabularFigures(),
              ],
            ),
          )
          ..addText(
            'paint ${paintMs.toStringAsFixed(2)} ms · '
            '${animating ? '${fps.toStringAsFixed(0)} fps' : 'idle'} · '
            '$nodes nodes · ${nodes - culled} drawn · $drawCalls draws',
          );
    final ui.Paragraph p = b.build()
      ..layout(const ui.ParagraphConstraints(width: 400));
    MorphDebugStats.liveParagraphs++;
    _paragraph = p;
    _builtAt = now;
    return p;
  }

  /// Releases the overlay paragraph.
  void dispose() {
    if (_paragraph != null) {
      _paragraph!.dispose();
      _paragraph = null;
      MorphDebugStats.liveParagraphs--;
    }
  }
}
