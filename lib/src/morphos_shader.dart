// Loading of the optional GPU effect shader.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'morphos_atlas.dart';

/// Optional per-pixel effect drawn over the nodes.
enum MorphEffect {
  /// No effect; the mesh is drawn once.
  none,

  /// A soft light that follows the pointer plus a slow diagonal band,
  /// drawn as a second `drawVertices` pass with a fragment shader.
  ///
  /// Experimental: whether a fragment shader may shade `drawVertices` output
  /// can vary by renderer; if the shader fails to load the field draws
  /// without it.
  sheen,
}

/// Loads and caches the package's fragment programs.
abstract final class MorphShaderLibrary {
  static Future<ui.FragmentProgram?>? _sheen;

  /// Asset key of the sheen shader when used from an app.
  static const String sheenAsset =
      'packages/morphos_ui/shaders/morph_sheen.frag';

  /// Asset key when this package is itself the root project (its own tests
  /// and example builds that path the asset without the package prefix).
  static const String sheenAssetLocal = 'shaders/morph_sheen.frag';

  /// Loads the sheen program once. Resolves to null (logging why in debug
  /// builds) if the platform cannot load or compile it, so fields fall back
  /// to the plain mesh.
  static Future<ui.FragmentProgram?> sheen() => _sheen ??= _loadSheen();

  /// How long each load attempt may take before the effect is given up.
  /// Some environments never answer an asset request for a missing shader;
  /// the field must not wait forever.
  static Duration loadTimeout = const Duration(seconds: 5);

  static Future<ui.FragmentProgram?> _loadSheen() async {
    try {
      return await ui.FragmentProgram.fromAsset(
        sheenAsset,
      ).timeout(loadTimeout);
    } catch (_) {
      try {
        return await ui.FragmentProgram.fromAsset(
          sheenAssetLocal,
        ).timeout(loadTimeout);
      } catch (error) {
        // An unavailable optional effect is not an app error: log it in debug
        // builds and draw without it.
        assert(() {
          debugPrint(
            'morphos_ui: sheen shader unavailable ($error); '
            'drawing without the effect.',
          );
          return true;
        }());
        return null;
      }
    }
  }

  /// Clears the cache (tests only).
  @visibleForTesting
  static void reset() => _sheen = null;
}

/// A sheen shader instance with its uniforms.
final class MorphSheenShader {
  /// Creates a shader from [program].
  MorphSheenShader(ui.FragmentProgram program)
    : shader = program.fragmentShader() {
    MorphDebugStats.liveShaders++;
  }

  /// The GPU shader.
  final ui.FragmentShader shader;
  bool _disposed = false;

  /// Updates the uniforms.
  void setUniforms({
    required double width,
    required double height,
    required double lightX,
    required double lightY,
    required double time,
    required double intensity,
  }) {
    shader
      ..setFloat(0, width)
      ..setFloat(1, height)
      ..setFloat(2, lightX)
      ..setFloat(3, lightY)
      ..setFloat(4, time)
      ..setFloat(5, intensity);
  }

  /// Releases the shader.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    shader.dispose();
    MorphDebugStats.liveShaders--;
  }
}
