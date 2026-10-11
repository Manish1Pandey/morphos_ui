// Module 5: text and image atlas painting.
//
// Text goes through one ParagraphBuilder pipeline into a per-node paragraph
// cache (rebuilt only when text or style inputs change, re-laid-out only when
// the width changes). Images are packed once into a single atlas texture and
// addressed per vertex with UV coordinates, so textured and flat nodes share a
// draw call.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'morphos_spec.dart';

/// Live-object counters for native resources the package owns. Tests use
/// them to prove every paragraph, vertex batch and atlas is released.
abstract final class MorphDebugStats {
  /// Paragraphs currently cached.
  static int liveParagraphs = 0;

  /// `ui.Vertices` created and not yet disposed.
  static int liveVertices = 0;

  /// Atlases built and not yet disposed.
  static int liveAtlases = 0;

  /// Fragment shaders created and not yet disposed.
  static int liveShaders = 0;

  /// Resets all counters (tests only).
  @visibleForTesting
  static void reset() {
    liveParagraphs = liveVertices = liveAtlases = liveShaders = 0;
  }
}

class _TextEntry {
  _TextEntry(this.paragraph, this.spec, this.width);

  final ui.Paragraph paragraph;
  final MorphNodeSpec spec;
  double width;
}

/// Compiles node text into cached `ui.Paragraph`s.
final class MorphTextCompiler {
  /// Creates an empty compiler.
  MorphTextCompiler();

  /// Style used when a node has no text style.
  static const TextStyle defaultStyle = TextStyle(
    fontSize: 14,
    color: Color(0xFFFFFFFF),
  );

  final Map<Object, _TextEntry> _cache = <Object, _TextEntry>{};

  TextScaler _textScaler = TextScaler.noScaling;
  TextDirection _textDirection = TextDirection.ltr;
  ui.Locale? _locale;

  /// Number of cached paragraphs.
  int get length => _cache.length;

  /// Scales font sizes (from `MediaQuery.textScalerOf`). Changing it clears
  /// the cache.
  TextScaler get textScaler => _textScaler;
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    clear();
  }

  /// Text direction for paragraphs. Changing it clears the cache.
  TextDirection get textDirection => _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    clear();
  }

  /// Locale for shaping and line breaking. Changing it clears the cache.
  ui.Locale? get locale => _locale;
  set locale(ui.Locale? value) {
    if (value == _locale) return;
    _locale = value;
    clear();
  }

  /// Returns the paragraph for node [id], laid out to [width] design units.
  ///
  /// A new paragraph is built only when the node's text inputs changed; a
  /// width change more than half a unit only re-runs layout.
  ui.Paragraph? paragraphFor(Object id, MorphNodeSpec spec, double width) {
    final String? text = spec.text;
    if (text == null || text.isEmpty) return null;
    final double w = math.max(0, width);
    final _TextEntry? cached = _cache[id];
    if (cached != null && _sameText(cached.spec, spec)) {
      if ((cached.width - w).abs() > 0.5) {
        cached.paragraph.layout(ui.ParagraphConstraints(width: w));
        cached.width = w;
      }
      return cached.paragraph;
    }
    if (cached != null) _evict(id, cached);
    final TextStyle style = spec.textStyle ?? defaultStyle;
    final ui.ParagraphBuilder builder =
        ui.ParagraphBuilder(
            style.getParagraphStyle(
              textAlign: spec.textAlign,
              textDirection: _textDirection,
              textScaler: _textScaler,
              maxLines: spec.maxLines,
              ellipsis: spec.maxLines != null ? spec.ellipsis : null,
              locale: _locale,
            ),
          )
          ..pushStyle(style.getTextStyle(textScaler: _textScaler))
          ..addText(text);
    final ui.Paragraph paragraph = builder.build()
      ..layout(ui.ParagraphConstraints(width: w));
    _cache[id] = _TextEntry(paragraph, spec, w);
    MorphDebugStats.liveParagraphs++;
    return paragraph;
  }

  static bool _sameText(MorphNodeSpec a, MorphNodeSpec b) =>
      a.text == b.text &&
      a.textStyle == b.textStyle &&
      a.textAlign == b.textAlign &&
      a.maxLines == b.maxLines &&
      a.ellipsis == b.ellipsis;

  void _evict(Object id, _TextEntry entry) {
    entry.paragraph.dispose();
    _cache.remove(id);
    MorphDebugStats.liveParagraphs--;
  }

  /// Drops paragraphs for ids not in [live].
  void retain(bool Function(Object id) live) {
    final List<Object> gone = <Object>[
      for (final Object id in _cache.keys)
        if (!live(id)) id,
    ];
    for (final Object id in gone) {
      _evict(id, _cache[id]!);
    }
  }

  /// Drops every cached paragraph (fonts, locale or scale changed).
  void clear() {
    for (final _TextEntry e in _cache.values) {
      e.paragraph.dispose();
      MorphDebugStats.liveParagraphs--;
    }
    _cache.clear();
  }

  /// Releases all paragraphs.
  void dispose() => clear();
}

/// Error raised when an atlas cannot be built.
class MorphAtlasException implements Exception {
  /// Creates an exception with [message].
  const MorphAtlasException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'MorphAtlasException: $message';
}

/// Called for each image that failed to load while building an atlas. The
/// atlas is still built from the images that did load.
typedef MorphAtlasErrorCallback =
    void Function(String key, Object error, StackTrace? stack);

/// Several images packed into one texture with a reserved white block, so
/// untextured nodes can sample pure white and share the same draw call.
final class MorphImageAtlas {
  MorphImageAtlas._(this.image, this._slots, this.rects) {
    MorphDebugStats.liveAtlases++;
  }

  /// Atlas texture.
  final ui.Image image;

  final Map<String, int> _slots;

  /// Per-slot texel rectangles `[l, t, r, b]`, inset half a texel.
  final Float32List rects;

  /// Texel coordinate x of the white block's centre.
  static const double whiteU = 2;

  /// Texel coordinate y of the white block's centre.
  static const double whiteV = 2;

  static const int _whiteBlock = 4;

  ImageShader? _shader;
  ui.Image? _shaderImage;
  bool _disposed = false;

  /// Keys packed in this atlas.
  Iterable<String> get keys => _slots.keys;

  /// Slot of [key], or -1 when it is not in the atlas.
  int slotOf(String key) => _slots[key] ?? -1;

  /// Shader sampling the atlas in texel coordinates.
  ImageShader get shader {
    if (_disposed) throw StateError('MorphImageAtlas used after dispose');
    // The shader gets its own handle: on the web (CanvasKit) disposing an
    // ImageShader also disposes the image it was given, on other engines it
    // does not. A dedicated clone keeps [image] valid everywhere.
    return _shader ??= ImageShader(
      _shaderImage = image.clone(),
      TileMode.clamp,
      TileMode.clamp,
      Matrix4Storage.identity,
      filterQuality: FilterQuality.low,
    );
  }

  /// Whether [dispose] has run.
  bool get isDisposed => _disposed;

  /// Resolves [images] through the image cache and packs them.
  ///
  /// Images that fail to load are reported to [onError] and left out.
  /// Throws [MorphAtlasException] if the packed atlas would exceed
  /// [maxDimension] on either side.
  static Future<MorphImageAtlas> build(
    Map<String, ImageProvider> images, {
    ImageConfiguration configuration = ImageConfiguration.empty,
    int maxDimension = 4096,
    int padding = 2,
    MorphAtlasErrorCallback? onError,
  }) async {
    final Map<String, ui.Image> loaded = <String, ui.Image>{};
    await Future.wait(<Future<void>>[
      for (final MapEntry<String, ImageProvider> e in images.entries)
        _resolve(e.value, configuration).then(
          (ui.Image img) => loaded[e.key] = img,
          onError: (Object error, StackTrace stack) =>
              onError?.call(e.key, error, stack),
        ),
    ]);
    try {
      return await fromImages(
        loaded,
        maxDimension: maxDimension,
        padding: padding,
      );
    } finally {
      for (final ui.Image img in loaded.values) {
        img.dispose();
      }
    }
  }

  static Future<ui.Image> _resolve(
    ImageProvider provider,
    ImageConfiguration configuration,
  ) {
    final Completer<ui.Image> completer = Completer<ui.Image>();
    final ImageStream stream = provider.resolve(configuration);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool sync) {
        if (!completer.isCompleted) completer.complete(info.image.clone());
        info.dispose();
        stream.removeListener(listener);
      },
      onError: (Object error, StackTrace? stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  /// Packs already-decoded [images] (not taken over; the caller keeps
  /// ownership) into a new atlas using shelf packing, tallest first.
  static Future<MorphImageAtlas> fromImages(
    Map<String, ui.Image> images, {
    int maxDimension = 4096,
    int padding = 2,
  }) async {
    if (padding < 0) {
      throw ArgumentError.value(padding, 'padding', 'must be >= 0');
    }
    final List<String> keys = images.keys.toList()
      ..sort(
        (String a, String b) => images[b]!.height.compareTo(images[a]!.height),
      );
    int area = _whiteBlock * _whiteBlock;
    int widest = _whiteBlock;
    for (final String k in keys) {
      final ui.Image img = images[k]!;
      area += (img.width + padding * 2) * (img.height + padding * 2);
      widest = math.max(widest, img.width + padding * 2);
    }
    int width = 64;
    final int wanted = math.max(widest, (math.sqrt(area) * 1.15).ceil());
    while (width < wanted) {
      width *= 2;
    }
    if (width > maxDimension) {
      throw MorphAtlasException(
        'an image of width $widest does not fit in $maxDimension',
      );
    }
    final Map<String, int> slots = <String, int>{};
    final Float32List rects = Float32List(keys.length * 4);
    final List<Offset> origins = <Offset>[];
    int x = _whiteBlock + padding, y = 0, shelf = _whiteBlock;
    for (int i = 0; i < keys.length; i++) {
      final ui.Image img = images[keys[i]]!;
      final int w = img.width + padding * 2, h = img.height + padding * 2;
      if (x + w > width) {
        x = 0;
        y += shelf;
        shelf = 0;
      }
      origins.add(Offset((x + padding).toDouble(), (y + padding).toDouble()));
      slots[keys[i]] = i;
      rects[i * 4] = x + padding + 0.5;
      rects[i * 4 + 1] = y + padding + 0.5;
      rects[i * 4 + 2] = x + padding + img.width - 0.5;
      rects[i * 4 + 3] = y + padding + img.height - 0.5;
      x += w;
      shelf = math.max(shelf, h);
    }
    final int height = math.max(_whiteBlock, y + shelf);
    if (height > maxDimension) {
      throw MorphAtlasException('packed height $height exceeds $maxDimension');
    }
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, _whiteBlock.toDouble(), _whiteBlock.toDouble()),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final Paint paint = Paint()..filterQuality = FilterQuality.none;
    for (int i = 0; i < keys.length; i++) {
      canvas.drawImage(images[keys[i]]!, origins[i], paint);
    }
    final ui.Picture picture = recorder.endRecording();
    try {
      final ui.Image image = await picture.toImage(width, height);
      return MorphImageAtlas._(image, slots, rects);
    } finally {
      picture.dispose();
    }
  }

  /// Releases the texture and shader.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    MorphDebugStats.liveAtlases--;
    _shader?.dispose();
    final ui.Image? shaderImage = _shaderImage;
    if (shaderImage != null) {
      // Release the clone unless the engine already did (web, see [shader]).
      bool alreadyDisposed = false;
      assert(() {
        alreadyDisposed = shaderImage.debugDisposed;
        return true;
      }());
      if (!alreadyDisposed) shaderImage.dispose();
    }
    image.dispose();
  }
}

/// Column-major identity matrix storage for shaders.
abstract final class Matrix4Storage {
  /// Identity.
  static final Float64List identity = Float64List.fromList(<double>[
    1, 0, 0, 0, //
    0, 1, 0, 0, //
    0, 0, 1, 0, //
    0, 0, 0, 1, //
  ]);
}
