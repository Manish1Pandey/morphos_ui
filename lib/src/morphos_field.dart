// The public widget that mounts a MorphOSRenderBridge.
//
// It reads environment settings (text scale, direction, reduced motion,
// brightness, locale, device pixel ratio) once per build and passes them
// down as plain properties, builds the image atlas off the frame loop, loads
// the optional shader, and turns keyboard input into node focus moves.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'morphos_atlas.dart';
import 'morphos_controller.dart';
import 'morphos_recorder.dart';
import 'morphos_render_core.dart';
import 'morphos_shader.dart';
import 'morphos_solver.dart';
import 'morphos_spec.dart';

/// A flat, matrix-laid-out, spring-animated field of nodes.
///
/// Replaces a subtree of layout widgets with one render object. Nodes are
/// described by [spec]; supply a new spec (same ids) to move, resize, add or
/// remove nodes and they animate there on their own springs.
class MorphOSField extends StatefulWidget {
  /// Creates a field.
  const MorphOSField({
    super.key,
    required this.spec,
    this.fit = MorphFit.contain,
    this.stagger = MorphStagger.none,
    this.animateEntryExit = true,
    this.images = const <String, ImageProvider>{},
    this.onNodeTap,
    this.onNodeHover,
    this.onNodeDragUpdate,
    this.onNodeDragEnd,
    this.onAtlasError,
    this.enableScroll = false,
    this.inheritFlingVelocity = true,
    this.effect = MorphEffect.none,
    this.effectIntensity = 1,
    this.semanticsEnabled = true,
    this.showPerfOverlay = false,
    this.debugPaintNodeBounds = false,
    this.focusNode,
    this.autofocus = false,
    this.focusColor = const Color(0xFF00B0FF),
    this.nodeCursor = SystemMouseCursors.click,
    this.recorder,
    this.controller,
    this.onSettled,
    this.scrollDirection = Axis.vertical,
    this.mirrorInRtl = true,
    this.paintMode = MorphPaintMode.shapes,
  });

  /// Nodes and design space.
  final MorphFieldSpec spec;

  /// How the design space maps into the box.
  final MorphFit fit;

  /// Start delays applied on each spec change.
  final MorphStagger stagger;

  /// Whether added nodes grow in and removed nodes shrink out.
  final bool animateEntryExit;

  /// Images for nodes with `imageKey`, packed into one atlas texture.
  final Map<String, ImageProvider> images;

  /// Node tap (and keyboard Enter/Space) handler.
  final MorphNodeTapCallback? onNodeTap;

  /// Hover handler (mouse).
  final MorphNodeHoverCallback? onNodeHover;

  /// Drag progress handler for draggable nodes.
  final MorphNodeDragCallback? onNodeDragUpdate;

  /// Drag release handler. Supply a new spec here to move the node for good;
  /// otherwise it springs back.
  final MorphNodeDragCallback? onNodeDragEnd;

  /// Image load/pack failures. Failed images fall back to the node colour.
  final MorphAtlasErrorCallback? onAtlasError;

  /// Whether empty-space drags, flings and the mouse wheel scroll the field
  /// vertically. Pair with [MorphFit.fitWidth].
  final bool enableScroll;

  /// Whether released drags keep their momentum.
  final bool inheritFlingVelocity;

  /// Optional GPU effect.
  final MorphEffect effect;

  /// Strength of [effect], 0 to 1.
  final double effectIntensity;

  /// Whether nodes with labels or text appear to assistive technology.
  final bool semanticsEnabled;

  /// Shows paint time, fps, node and draw-call counts.
  final bool showPerfOverlay;

  /// Outlines every node's bounds.
  final bool debugPaintNodeBounds;

  /// Focus node for keyboard navigation between nodes.
  final FocusNode? focusNode;

  /// Whether to take focus on first build.
  final bool autofocus;

  /// Colour of the keyboard focus ring.
  final Color focusColor;

  /// Mouse cursor over interactive nodes.
  final MouseCursor nodeCursor;

  /// Records solver commands for deterministic replay.
  final MorphRecorder? recorder;

  /// Programmatic scrolling and queries (`scrollToNode`, `nodeRect`,
  /// `whenSettled`, ...).
  final MorphController? controller;

  /// Called each time nodes and scrolling come to rest.
  final VoidCallback? onSettled;

  /// Axis [enableScroll] scrolls along. Pair horizontal scrolling with
  /// [MorphFit.fitHeight].
  final Axis scrollDirection;

  /// Whether layouts mirror horizontally when the ambient text direction is
  /// right-to-left (node positions and rotations flip; text and images stay
  /// readable).
  final bool mirrorInRtl;

  /// How nodes become draw calls: [MorphPaintMode.shapes] (the default,
  /// fastest on Impeller) or [MorphPaintMode.vertices] (batched meshes with no
  /// per-node allocation).
  final MorphPaintMode paintMode;

  @override
  State<MorphOSField> createState() => _MorphOSFieldState();
}

class _MorphOSFieldState extends State<MorphOSField> {
  final GlobalKey _bridgeKey = GlobalKey();
  FocusNode? _ownFocus;
  MorphImageAtlas? _atlas;
  int _atlasGeneration = 0;
  bool _atlasRequested = false;
  double _atlasDpr = 0;
  ui.FragmentProgram? _program;
  int _effectGeneration = 0;

  FocusNode get _focus =>
      widget.focusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'MorphOSField'));

  MorphOSRenderBridge? get _bridge =>
      _bridgeKey.currentContext?.findRenderObject() as MorphOSRenderBridge?;

  @override
  void initState() {
    super.initState();
    _loadEffect();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    if (!_atlasRequested || dpr != _atlasDpr) {
      _atlasRequested = true;
      _atlasDpr = dpr;
      _rebuildAtlas();
    }
  }

  @override
  void didUpdateWidget(MorphOSField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!mapEquals(oldWidget.images, widget.images)) _rebuildAtlas();
    if (oldWidget.effect != widget.effect) _loadEffect();
    if (oldWidget.focusNode != widget.focusNode && widget.focusNode != null) {
      _ownFocus?.dispose();
      _ownFocus = null;
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    _rebuildAtlas();
  }

  void _loadEffect() {
    final int gen = ++_effectGeneration;
    if (widget.effect == MorphEffect.none) {
      _program = null;
      return;
    }
    MorphShaderLibrary.sheen().then((ui.FragmentProgram? program) {
      if (!mounted || gen != _effectGeneration) return;
      setState(() => _program = program);
    });
  }

  Future<void> _rebuildAtlas() async {
    final int gen = ++_atlasGeneration;
    final Map<String, ImageProvider> images = widget.images;
    if (images.isEmpty) {
      await Future<void>.value();
      if (mounted && gen == _atlasGeneration) _swapAtlas(null);
      return;
    }
    final ImageConfiguration config = createLocalImageConfiguration(context);
    final MorphAtlasErrorCallback onError =
        widget.onAtlasError ?? _reportImageError;
    MorphImageAtlas atlas;
    try {
      atlas = await MorphImageAtlas.build(
        images,
        configuration: config,
        onError: onError,
      );
    } catch (error, stack) {
      onError('*', error, stack);
      if (mounted && gen == _atlasGeneration) _swapAtlas(null);
      return;
    }
    if (!mounted || gen != _atlasGeneration) {
      atlas.dispose();
      return;
    }
    _swapAtlas(atlas);
  }

  static void _reportImageError(String key, Object error, StackTrace? stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'morphos_ui',
        context: ErrorDescription('building the image atlas (image "$key")'),
      ),
    );
  }

  void _swapAtlas(MorphImageAtlas? next) {
    final MorphImageAtlas? old = _atlas;
    if (identical(old, next)) return;
    setState(() => _atlas = next);
    if (old != null) {
      // Free the old texture only after a frame has painted with the new one.
      SchedulerBinding.instance.addPostFrameCallback(
        (Duration _) => old.dispose(),
      );
      SchedulerBinding.instance.ensureVisualUpdate();
    }
  }

  @override
  void dispose() {
    _atlasGeneration++;
    _effectGeneration++;
    _atlas?.dispose();
    _atlas = null;
    _ownFocus?.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final MorphOSRenderBridge? bridge = _bridge;
    if (bridge == null) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;
    bool handled = false;
    if (key == LogicalKeyboardKey.tab) {
      handled = bridge.focusNext(
        forward: !HardwareKeyboard.instance.isShiftPressed,
      );
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      handled = bridge.moveFocus(TraversalDirection.left);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      handled = bridge.moveFocus(TraversalDirection.right);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      handled = bridge.moveFocus(TraversalDirection.up);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      handled = bridge.moveFocus(TraversalDirection.down);
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      handled = bridge.activateFocused();
    }
    if (handled) bridge.hasKeyboardFocus = true;
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _onFocusChange(bool focused) {
    final MorphOSRenderBridge? bridge = _bridge;
    if (bridge == null) return;
    final bool keyboard =
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    bridge.hasKeyboardFocus = focused && keyboard;
    if (focused && keyboard && bridge.focusedId == null) {
      bridge.focusNext(forward: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool hasInteractive =
        widget.onNodeTap != null &&
        widget.spec.nodes.any((MorphNodeSpec n) => n.interactive);
    return Focus(
      focusNode: _focus,
      autofocus: widget.autofocus,
      canRequestFocus: hasInteractive,
      onKeyEvent: _onKey,
      onFocusChange: _onFocusChange,
      child: _MorphOSBridgeWidget(
        key: _bridgeKey,
        field: widget,
        atlas: _atlas,
        program: _program,
        textScaler:
            MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling,
        textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
        reduceMotion: MediaQuery.maybeDisableAnimationsOf(context) ?? false,
        dark:
            (MediaQuery.maybePlatformBrightnessOf(context) ??
                Brightness.light) ==
            Brightness.dark,
        devicePixelRatio:
            MediaQuery.maybeDevicePixelRatioOf(context) ??
            View.maybeOf(context)?.devicePixelRatio ??
            1,
        locale: Localizations.maybeLocaleOf(context),
      ),
    );
  }
}

class _MorphOSBridgeWidget extends LeafRenderObjectWidget {
  const _MorphOSBridgeWidget({
    super.key,
    required this.field,
    required this.atlas,
    required this.program,
    required this.textScaler,
    required this.textDirection,
    required this.reduceMotion,
    required this.dark,
    required this.devicePixelRatio,
    required this.locale,
  });

  final MorphOSField field;
  final MorphImageAtlas? atlas;
  final ui.FragmentProgram? program;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final bool reduceMotion;
  final bool dark;
  final double devicePixelRatio;
  final Locale? locale;

  @override
  MorphOSRenderBridge createRenderObject(BuildContext context) {
    final MorphOSRenderBridge bridge = MorphOSRenderBridge(
      spec: field.spec,
      fit: field.fit,
      stagger: field.stagger,
      animateEntryExit: field.animateEntryExit,
      recorder: field.recorder,
      reduceMotion: reduceMotion,
      dark: dark,
      textDirection: textDirection,
      mirrorInRtl: field.mirrorInRtl,
      scrollDirection: field.scrollDirection,
    );
    _configure(bridge);
    return bridge;
  }

  @override
  void updateRenderObject(
    BuildContext context,
    MorphOSRenderBridge renderObject,
  ) {
    // Order matters: settings that affect how a spec is applied go first.
    renderObject
      ..recorder = field.recorder
      ..reduceMotion = reduceMotion
      ..dark = dark
      ..textDirection = textDirection
      ..mirrorInRtl = field.mirrorInRtl
      ..scrollDirection = field.scrollDirection
      ..stagger = field.stagger
      ..animateEntryExit = field.animateEntryExit
      ..spec = field.spec
      ..fit = field.fit;
    _configure(renderObject);
  }

  void _configure(MorphOSRenderBridge r) {
    r
      ..atlas = atlas
      ..sheenProgram = program
      ..effectIntensity = field.effectIntensity
      ..textScaler = textScaler
      ..textDirection = textDirection
      ..locale = locale
      ..devicePixelRatio = devicePixelRatio
      ..onNodeTap = field.onNodeTap
      ..onNodeHover = field.onNodeHover
      ..onNodeDragUpdate = field.onNodeDragUpdate
      ..onNodeDragEnd = field.onNodeDragEnd
      ..enableScroll = field.enableScroll
      ..inheritFlingVelocity = field.inheritFlingVelocity
      ..semanticsEnabled = field.semanticsEnabled
      ..showPerfOverlay = field.showPerfOverlay
      ..debugPaintNodeBounds = field.debugPaintNodeBounds
      ..paintMode = field.paintMode
      ..controller = field.controller
      ..onSettled = field.onSettled
      ..focusColor = field.focusColor
      ..nodeCursor = field.nodeCursor;
  }
}
