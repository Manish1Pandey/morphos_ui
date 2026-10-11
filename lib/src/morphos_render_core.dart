// Module 4: the core render bridge.
//
// MorphOSRenderBridge is a single leaf RenderBox. Layout computes one field
// matrix; paint writes every node into pre-allocated vertex buffers and
// submits them with Canvas.drawVertices (one call per 451 nodes, split only
// where text must sit under a later node); text goes through cached
// paragraphs; hit testing inverts the matrix against the node buffers.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' show TraversalDirection;

import 'morphos_atlas.dart';
import 'morphos_controller.dart';
import 'morphos_gestures.dart';
import 'morphos_mesh.dart';
import 'morphos_perf.dart';
import 'morphos_recorder.dart';
import 'morphos_shader.dart';
import 'morphos_solver.dart';
import 'morphos_spec.dart';

/// Called when a node is tapped or activated from the keyboard. [index] is
/// the node's position in `spec.nodes`.
typedef MorphNodeTapCallback = void Function(Object id, int index);

/// Called when the hovered node changes; null when the pointer left all nodes.
typedef MorphNodeHoverCallback = void Function(Object? id);

/// Called while dragging and on release. [designCenter] is the node's current
/// centre and [designVelocity] its velocity, both in design units.
typedef MorphNodeDragCallback =
    void Function(Object id, Offset designCenter, Offset designVelocity);

/// How a field turns nodes into draw calls.
enum MorphPaintMode {
  /// One `drawRRect` (plus text) per node, in paint order. Uses the
  /// renderer's built-in anti-aliased rounded-rectangle path; text layers
  /// naturally. Allocates one small `RRect` per node per frame.
  shapes,

  /// All nodes as triangle meshes in as few `drawVertices` calls as possible
  /// (one per 65,535 vertices), from preallocated buffers: no per-node
  /// allocation. Text is drawn after the meshes, split only where a later
  /// node covers it at rest.
  vertices,
}

/// The leaf render object behind `MorphOSField`.
///
/// Usable directly inside a custom widget: every input is a settable
/// property.
class MorphOSRenderBridge extends RenderBox
    with MorphHitTestMixin
    implements MorphGestureHost, MorphControllerHost {
  /// Creates the render object and applies [spec] without animation.
  MorphOSRenderBridge({
    required MorphFieldSpec spec,
    MorphFit fit = MorphFit.contain,
    this.stagger = MorphStagger.none,
    this.animateEntryExit = true,
    MorphRecorder? recorder,
    bool reduceMotion = false,
    bool dark = false,
    TextDirection textDirection = TextDirection.ltr,
    bool mirrorInRtl = true,
    Axis scrollDirection = Axis.vertical,
  }) : _spec = spec,
       _fit = fit,
       _recorder = recorder,
       _dark = dark,
       _mirrorInRtl = mirrorInRtl {
    solver.observer = recorder;
    solver.reduceMotion = reduceMotion;
    solver.scrollAxis = scrollDirection;
    textCompiler.textDirection = textDirection;
    _router = MorphGestureRouter(this);
    _applySpec();
  }

  @override
  final MorphFieldSolver solver = MorphFieldSolver();

  @override
  late final MorphHitTester hitTester = MorphHitTester(solver);

  late final MorphGestureRouter _router;

  /// Vertex buffers.
  final MorphMesh mesh = MorphMesh();

  /// Paragraph cache.
  final MorphTextCompiler textCompiler = MorphTextCompiler();

  /// Overlay numbers.
  final MorphPerfStats perf = MorphPerfStats();

  final Paint _meshPaint = Paint();
  final Paint _overlayPaint = Paint();
  final Paint _layerPaint = Paint();
  final Paint _debugPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1
    ..color = const Color(0xFF00E5FF);
  final Paint _focusPaint = Paint()..style = PaintingStyle.stroke;
  final Paint _perfBackground = Paint()..color = const Color(0xC0000000);
  final LayerHandle<ClipRectLayer> _clipLayer = LayerHandle<ClipRectLayer>();
  final Stopwatch _paintClock = Stopwatch();
  final MorphUniformGrid _overlapGrid = MorphUniformGrid();
  Uint8List _textDrawn = Uint8List(16);
  Uint8List _splitAfter = Uint8List(16);
  Float32List _restBoxes = Float32List(64);
  late final PaintingContextCallback _paintFieldCallback = _paintField;
  late final void Function(int) _overlapVisitor = _visitOverlap;
  late final VoidCallback _fontsListener = _onSystemFontsChanged;
  final Map<Object, SemanticsNode> _semanticsNodes = <Object, SemanticsNode>{};

  int? _frameCallbackId;
  Duration? _lastFrame;
  double _time = 0;
  double _lightX = -1, _lightY = -1;
  double _scrollVelocity = 0;
  bool _scrollDragging = false;
  int _seenGeneration = -1;
  MorphSheenShader? _sheen;

  int _queryRank = 0;
  bool _overlapFound = false;
  double _ql = 0, _qt = 0, _qr = 0, _qb = 0;

  /// Number of paints since creation (tests use it to prove a resting field
  /// stops repainting).
  int debugPaintCount = 0;

  // ------------------------------------------------------------- properties

  MorphFieldSpec _spec;

  /// Field description. Equal specs are ignored.
  MorphFieldSpec get spec => _spec;
  set spec(MorphFieldSpec value) {
    if (value == _spec) return;
    _spec = value;
    _applySpec();
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  MorphFit _fit;

  /// Design-to-box fit.
  MorphFit get fit => _fit;
  set fit(MorphFit value) {
    if (value == _fit) return;
    _fit = value;
    markNeedsLayout();
  }

  /// Stagger for the next spec change.
  MorphStagger stagger;

  /// Whether nodes animate in and out.
  bool animateEntryExit;

  MorphRecorder? _recorder;

  /// Command recorder.
  MorphRecorder? get recorder => _recorder;
  set recorder(MorphRecorder? value) {
    if (identical(value, _recorder)) return;
    _recorder = value;
    solver.observer = value;
  }

  /// Snap instead of animate.
  bool get reduceMotion => solver.reduceMotion;
  set reduceMotion(bool value) {
    if (value == solver.reduceMotion) return;
    solver.reduceMotion = value;
    _afterSlotChange();
    markNeedsPaint();
  }

  bool _dark;

  /// Use `darkColor` fills.
  bool get dark => _dark;
  set dark(bool value) {
    if (value == _dark) return;
    _dark = value;
    final MorphFieldStore s = solver.store;
    for (int i = 0; i < s.length; i++) {
      final MorphNodeSpec? n = s.specs[i];
      if (n != null) {
        s.fillColors[i] = (value ? (n.darkColor ?? n.color) : n.color)
            .toARGB32();
      }
    }
    markNeedsPaint();
  }

  MorphImageAtlas? _atlas;

  /// Image atlas for textured nodes. Owned by the caller.
  MorphImageAtlas? get atlas => _atlas;
  set atlas(MorphImageAtlas? value) {
    if (identical(value, _atlas)) return;
    _atlas = value;
    _resolveAtlasSlots();
    markNeedsPaint();
  }

  ui.FragmentProgram? _sheenProgram;

  /// Program for the sheen effect, or null for none.
  ui.FragmentProgram? get sheenProgram => _sheenProgram;
  set sheenProgram(ui.FragmentProgram? value) {
    if (identical(value, _sheenProgram)) return;
    _sheenProgram = value;
    _sheen?.dispose();
    _sheen = value == null ? null : MorphSheenShader(value);
    markNeedsPaint();
  }

  double _effectIntensity = 1;

  /// Effect strength, 0 to 1.
  double get effectIntensity => _effectIntensity;
  set effectIntensity(double value) {
    final double v = value.isFinite ? value.clamp(0.0, 1.0) : 0;
    if (v == _effectIntensity) return;
    _effectIntensity = v;
    if (_sheen != null) markNeedsPaint();
  }

  /// Text scale.
  TextScaler get textScaler => textCompiler.textScaler;
  set textScaler(TextScaler value) {
    if (value == textCompiler.textScaler) return;
    textCompiler.textScaler = value;
    markNeedsPaint();
  }

  /// Text direction. With [mirrorInRtl], switching to right-to-left
  /// springs every node to its mirrored position.
  TextDirection get textDirection => textCompiler.textDirection;
  set textDirection(TextDirection value) {
    if (value == textCompiler.textDirection) return;
    final bool wasMirrored = _mirrored;
    textCompiler.textDirection = value;
    if (_mirrored != wasMirrored) {
      _applySpec();
      markNeedsLayout();
    }
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  bool _mirrorInRtl;

  /// Whether layouts mirror horizontally in right-to-left text direction.
  bool get mirrorInRtl => _mirrorInRtl;
  set mirrorInRtl(bool value) {
    if (value == _mirrorInRtl) return;
    final bool wasMirrored = _mirrored;
    _mirrorInRtl = value;
    if (_mirrored != wasMirrored) {
      _applySpec();
      markNeedsLayout();
    }
  }

  bool get _mirrored =>
      _mirrorInRtl && textCompiler.textDirection == TextDirection.rtl;

  /// Axis that scrolling moves along.
  Axis get scrollDirection => solver.scrollAxis;
  set scrollDirection(Axis value) {
    if (value == solver.scrollAxis) return;
    solver.scrollOffset = 0;
    solver.scrollAxis = value;
    _scrollTarget = null;
    _scrollVelocity = 0;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  MorphPaintMode _paintMode = MorphPaintMode.shapes;

  /// How nodes are drawn; see [MorphPaintMode].
  MorphPaintMode get paintMode => _paintMode;
  set paintMode(MorphPaintMode value) {
    if (value == _paintMode) return;
    _paintMode = value;
    markNeedsPaint();
  }

  MorphController? _controller;

  /// Controller for programmatic scrolling and queries.
  MorphController? get controller => _controller;
  set controller(MorphController? value) {
    if (identical(value, _controller)) return;
    _controller?.detach(this);
    _controller = value;
    value?.attach(this);
  }

  /// Called each time nodes and scrolling come to rest.
  VoidCallback? onSettled;

  /// Text locale.
  Locale? get locale => textCompiler.locale;
  set locale(Locale? value) {
    if (value == textCompiler.locale) return;
    textCompiler.locale = value;
    markNeedsPaint();
  }

  double _devicePixelRatio = 1;

  /// Device pixel ratio, used for the anti-aliasing fringe width.
  double get devicePixelRatio => _devicePixelRatio;
  set devicePixelRatio(double value) {
    final double v = value.isFinite && value > 0 ? value : 1;
    if (v == _devicePixelRatio) return;
    _devicePixelRatio = v;
    markNeedsPaint();
  }

  /// Tap handler.
  MorphNodeTapCallback? onNodeTap;

  /// Hover handler.
  MorphNodeHoverCallback? onNodeHover;

  /// Drag progress handler.
  MorphNodeDragCallback? onNodeDragUpdate;

  /// Drag release handler.
  MorphNodeDragCallback? onNodeDragEnd;

  bool _enableScroll = false;

  /// Vertical scrolling.
  bool get enableScroll => _enableScroll;
  set enableScroll(bool value) {
    if (value == _enableScroll) return;
    _enableScroll = value;
    markNeedsLayout();
  }

  /// Fling momentum on release.
  bool get inheritFlingVelocity => _router.inheritFlingVelocity;
  set inheritFlingVelocity(bool value) => _router.inheritFlingVelocity = value;

  bool _semanticsEnabled = true;

  /// Whether nodes are exposed to assistive technology.
  bool get semanticsEnabled => _semanticsEnabled;
  set semanticsEnabled(bool value) {
    if (value == _semanticsEnabled) return;
    _semanticsEnabled = value;
    markNeedsSemanticsUpdate();
  }

  bool _showPerfOverlay = false;

  /// Perf overlay.
  bool get showPerfOverlay => _showPerfOverlay;
  set showPerfOverlay(bool value) {
    if (value == _showPerfOverlay) return;
    _showPerfOverlay = value;
    markNeedsPaint();
  }

  bool _debugPaintNodeBounds = false;

  /// Node bounds overlay.
  bool get debugPaintNodeBounds => _debugPaintNodeBounds;
  set debugPaintNodeBounds(bool value) {
    if (value == _debugPaintNodeBounds) return;
    _debugPaintNodeBounds = value;
    markNeedsPaint();
  }

  Color _focusColor = const Color(0xFF00B0FF);

  /// Focus ring colour.
  Color get focusColor => _focusColor;
  set focusColor(Color value) {
    if (value == _focusColor) return;
    _focusColor = value;
    markNeedsPaint();
  }

  MouseCursor _nodeCursor = SystemMouseCursors.click;

  @override
  MouseCursor get nodeCursor => _nodeCursor;
  set nodeCursor(MouseCursor value) => _nodeCursor = value;

  bool _hasKeyboardFocus = false;

  /// Whether the keyboard focus ring is shown.
  bool get hasKeyboardFocus => _hasKeyboardFocus;
  set hasKeyboardFocus(bool value) {
    if (value == _hasKeyboardFocus) return;
    _hasKeyboardFocus = value;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  Object? _focusedId;

  /// Id of the keyboard-focused node.
  Object? get focusedId => _focusedId;

  // ------------------------------------------------------- mixin/host glue

  @override
  MorphGestureRouter get gestureRouter => _router;

  @override
  MorphHitTester get morphHitTester => hitTester;

  @override
  bool get hitTestWholeBox => _enableScroll;

  @override
  bool get scrollEnabled => _enableScroll;

  @override
  bool get hasTapHandler => onNodeTap != null;

  @override
  void handleNodeTap(int slot) {
    final Object? id = solver.store.ids[slot];
    if (id == null) return;
    onNodeTap?.call(id, slot);
  }

  @override
  void handleHover(int slot) {
    onNodeHover?.call(slot >= 0 ? solver.store.ids[slot] : null);
  }

  @override
  void handleNodeDragUpdate(Object id) {
    final int? slot = solver.slotOf(id);
    if (slot == null) return;
    onNodeDragUpdate?.call(id, solver.store.currentCenter(slot), Offset.zero);
  }

  @override
  void handleNodeDragEnd(Object id, Offset designVelocity) {
    final int? slot = solver.slotOf(id);
    if (slot != null) {
      onNodeDragEnd?.call(id, solver.store.currentCenter(slot), designVelocity);
    }
    _scheduleTick();
  }

  @override
  void notePointer(Offset local) {
    _lightX = local.dx;
    _lightY = local.dy;
    if (_sheen != null) markNeedsPaint();
  }

  @override
  void requestPaint() => markNeedsPaint();

  // ------------------------------------------------------------------ spec

  final Stopwatch _applyClock = Stopwatch();

  void _applySpec() {
    _applyClock
      ..reset()
      ..start();
    solver.applySpec(
      _spec,
      stagger: stagger,
      animateEntryExit: animateEntryExit,
      brightnessDark: _dark,
      mirror: _mirrored,
    );
    _afterSlotChange();
    _applyClock.stop();
    perf.lastApplyMicros = _applyClock.elapsedMicroseconds;
    _scheduleTick();
  }

  void _afterSlotChange() {
    if (solver.generation == _seenGeneration) return;
    _seenGeneration = solver.generation;
    _resolveAtlasSlots();
    textCompiler.retain((Object id) => solver.slotOf(id) != null);
    hitTester.invalidate();
    _rebuildTextSplits();
    final Object? focused = _focusedId;
    if (focused != null && solver.slotOf(focused) == null) _focusedId = null;
  }

  /// Decides, once per spec change, which text nodes must end a mesh run so
  /// a later node can cover their text. Uses resting (target) rectangles, so
  /// nodes passing over each other mid-animation do not split the draw; the
  /// draw-call count stays fixed while things move.
  void _rebuildTextSplits() {
    final MorphFieldStore s = solver.store;
    final int n = s.length;
    if (_splitAfter.length < n) {
      _splitAfter = Uint8List(math.max(n, _splitAfter.length * 2));
    }
    _splitAfter.fillRange(0, n, 0);
    if (_restBoxes.length < n * 4) {
      _restBoxes = Float32List(math.max(n * 4, _restBoxes.length * 2));
    }
    final Int32List order = solver.drawOrder;
    bool anyText = false;
    for (int i = 0; i < n && !anyText; i++) {
      if (s.hasFlag(i, MorphAux.flagHasText)) anyText = true;
    }
    if (!anyText || n < 2) return;
    for (int q = 0; q < n; q++) {
      final int slot = order[q];
      final int b = MorphLayout.base(slot), x = MorphAux.base(slot);
      final double r = s.aux[x + MorphAux.rotation];
      final double w = s.aux[x + MorphAux.targetW],
          h = s.aux[x + MorphAux.targetH];
      final double c = r == 0 ? 1 : math.cos(r).abs();
      final double sn = r == 0 ? 0 : math.sin(r).abs();
      final double ex = (w * c + h * sn) / 2, ey = (w * sn + h * c) / 2;
      final double tx = s.layout[b + MorphLayout.targetX];
      final double ty = s.layout[b + MorphLayout.targetY];
      _restBoxes[q * 4] = tx - ex;
      _restBoxes[q * 4 + 1] = ty - ey;
      _restBoxes[q * 4 + 2] = tx + ex;
      _restBoxes[q * 4 + 3] = ty + ey;
      if (s.hasFlag(slot, MorphAux.flagHasText)) anyText = true;
    }
    if (!anyText || n < 2) return;
    final bool useGrid = n > 256;
    if (useGrid) _overlapGrid.build(_restBoxes, n);
    for (int q = 0; q < n - 1; q++) {
      final int slot = order[q];
      if (!s.hasFlag(slot, MorphAux.flagHasText)) continue;
      if (s.aux[MorphAux.base(slot) + MorphAux.presenceTarget] == 0) continue;
      _ql = _restBoxes[q * 4];
      _qt = _restBoxes[q * 4 + 1];
      _qr = _restBoxes[q * 4 + 2];
      _qb = _restBoxes[q * 4 + 3];
      _queryRank = q;
      _overlapFound = false;
      if (useGrid && _overlapGrid.valid) {
        _overlapGrid.visitRect(_ql, _qt, _qr, _qb, _overlapVisitor);
      } else {
        for (int j = q + 1; j < n && !_overlapFound; j++) {
          _visitOverlap(j);
        }
      }
      if (_overlapFound) _splitAfter[q] = 1;
    }
  }

  void _resolveAtlasSlots() {
    final MorphImageAtlas? atlas = _usableAtlas;
    final MorphFieldStore s = solver.store;
    for (int i = 0; i < s.length; i++) {
      final String? key = s.specs[i]?.imageKey;
      s.aux[MorphAux.base(i) + MorphAux.atlasSlot] =
          (atlas == null || key == null) ? -1 : atlas.slotOf(key).toDouble();
    }
  }

  MorphImageAtlas? get _usableAtlas {
    final MorphImageAtlas? a = _atlas;
    return (a == null || a.isDisposed) ? null : a;
  }

  // --------------------------------------------------------------- ticking

  void _scheduleTick() {
    if (!attached || _frameCallbackId != null) return;
    if (!solver.isActive && !_scrollMoving) return;
    _frameCallbackId = SchedulerBinding.instance.scheduleFrameCallback(
      _onFrame,
    );
  }

  bool get _scrollMoving {
    if (!_enableScroll || _scrollDragging) return false;
    final double off = solver.scrollOffset;
    return _scrollTarget != null ||
        _scrollVelocity != 0 ||
        off < 0 ||
        off > solver.maxScrollOffset;
  }

  bool get _isMoving => solver.isActive || _scrollMoving;

  void _ensureFrame() {
    if (_frameCallbackId == null && attached && _isMoving) {
      _frameCallbackId = SchedulerBinding.instance.scheduleFrameCallback(
        _onFrame,
      );
    }
  }

  final List<Completer<void>> _settleWaiters = <Completer<void>>[];
  final List<Completer<void>> _scrollWaiters = <Completer<void>>[];
  double? _scrollTarget;

  void _completeAll(List<Completer<void>> waiters) {
    if (waiters.isEmpty) return;
    final List<Completer<void>> done = List<Completer<void>>.of(waiters);
    waiters.clear();
    for (final Completer<void> c in done) {
      if (!c.isCompleted) c.complete();
    }
  }

  void _settled() {
    _completeAll(_scrollWaiters);
    _completeAll(_settleWaiters);
    onSettled?.call();
    _controller?.notifyFieldChanged();
  }

  /// Whether a frame callback is pending (tests use it to prove idle fields
  /// schedule nothing).
  bool get debugHasScheduledFrame => _frameCallbackId != null;

  void _onFrame(Duration timestamp) {
    _frameCallbackId = null;
    final Duration? last = _lastFrame;
    _lastFrame = timestamp;
    final double dt = last == null
        ? 0
        : (timestamp - last).inMicroseconds / 1e6;
    if (last != null) perf.recordFrameInterval(dt);
    _time += math.min(dt, MorphFieldSolver.maxFrameDt);
    final double before = solver.scrollOffset;
    final bool nodes = solver.step(dt);
    final bool scroll = _stepScroll(math.min(dt, MorphFieldSolver.maxFrameDt));
    _afterSlotChange();
    hitTester.invalidate();
    markNeedsPaint();
    if (solver.scrollOffset != before) _controller?.notifyFieldChanged();
    if ((nodes || scroll) && attached) {
      _frameCallbackId = SchedulerBinding.instance.scheduleFrameCallback(
        _onFrame,
      );
    } else {
      _lastFrame = null;
      markNeedsSemanticsUpdate();
      if (!_scrollDragging && _router.draggingId == null) _settled();
    }
  }

  // ---------------------------------------------------------------- scroll

  bool _stepScroll(double dt) {
    if (!_enableScroll || _scrollDragging) return false;
    double off = solver.scrollOffset;
    double v = _scrollVelocity;
    final double max = solver.maxScrollOffset;
    final double? target = _scrollTarget;
    if (target != null) {
      // Programmatic scroll: critically damped spring to the target.
      final double t = target.clamp(0.0, max);
      const double k = 170;
      final double c = 2 * math.sqrt(k);
      v += (-k * (off - t) - c * v) * dt;
      off += v * dt;
      if ((off - t).abs() < 0.5 && v.abs() < 5) {
        off = t;
        v = 0;
        _scrollTarget = null;
        _completeAll(_scrollWaiters);
      }
      solver.scrollOffset = off;
      _scrollVelocity = v;
      return _scrollTarget != null;
    }
    if (off < 0 || off > max) {
      final double bound = off < 0 ? 0 : max;
      const double k = 220;
      final double c = 2 * math.sqrt(k);
      v += (-k * (off - bound) - c * v) * dt;
      off += v * dt;
      if ((off - bound).abs() < 0.5 && v.abs() < 5) {
        off = bound;
        v = 0;
      }
    } else if (v.abs() < 5) {
      v = 0;
    } else {
      off += v * dt;
      v *= math.exp(-3 * dt);
    }
    solver.scrollOffset = off;
    _scrollVelocity = v;
    return v != 0 || off < 0 || off > max;
  }

  @override
  void scrollBy(double delta) {
    if (!_enableScroll || !delta.isFinite) return;
    final double max = solver.maxScrollOffset;
    double next = solver.scrollOffset + delta;
    if (_scrollDragging) {
      if (next < 0 || next > max) next = solver.scrollOffset + delta * 0.5;
    } else {
      next = next.clamp(0.0, max);
    }
    solver.scrollOffset = next;
    markNeedsPaint();
    if (!_scrollDragging) markNeedsSemanticsUpdate();
  }

  @override
  void beginScrollDrag() {
    _scrollDragging = true;
    _scrollVelocity = 0;
    if (_scrollTarget != null) {
      // A user drag interrupts a programmatic scroll.
      _scrollTarget = null;
      _completeAll(_scrollWaiters);
    }
  }

  @override
  void endScrollDrag(double velocity) {
    _scrollDragging = false;
    _scrollVelocity = velocity.isFinite ? velocity : 0;
    _ensureFrame();
    if (!_isMoving) _settled();
    markNeedsSemanticsUpdate();
  }

  @override
  Axis get scrollAxis => solver.scrollAxis;

  double get _viewportExtent => !hasSize
      ? 0
      : (solver.scrollAxis == Axis.vertical ? size.height : size.width);

  /// Springs the scroll offset to [offset]. Completes on arrival or when a
  /// user drag interrupts.
  Future<void> animateScrollTo(double offset) {
    if (!_enableScroll || !offset.isFinite || !attached) {
      return Future<void>.value();
    }
    _scrollTarget = offset.clamp(0.0, solver.maxScrollOffset);
    _scrollVelocity = 0;
    final Completer<void> done = Completer<void>();
    _scrollWaiters.add(done);
    _ensureFrame();
    return done.future;
  }

  // ------------------------------------------------------- controller host

  @override
  double get controllerScrollOffset => solver.scrollOffset;

  @override
  double get controllerMaxScrollOffset =>
      _enableScroll ? solver.maxScrollOffset : 0;

  @override
  bool get controllerIsAnimating => _isMoving;

  @override
  void controllerJumpTo(double offset) {
    if (!_enableScroll || !offset.isFinite) return;
    _scrollTarget = null;
    _scrollVelocity = 0;
    _completeAll(_scrollWaiters);
    solver.scrollOffset = offset.clamp(0.0, solver.maxScrollOffset);
    hitTester.invalidate();
    markNeedsPaint();
    markNeedsSemanticsUpdate();
    _controller?.notifyFieldChanged();
  }

  @override
  Future<void> controllerAnimateTo(double offset) => animateScrollTo(offset);

  @override
  double? controllerOffsetForNode(Object id, double alignment) {
    final int? slot = solver.slotOf(id);
    if (slot == null || !hasSize) return null;
    final Rect r = _localTargetRect(slot);
    final bool vertical = solver.scrollAxis == Axis.vertical;
    final double start = vertical ? r.top : r.left;
    final double extent = vertical ? r.height : r.width;
    final double a = alignment.clamp(0.0, 1.0);
    final double offset =
        solver.scrollOffset + start - (_viewportExtent - extent) * a;
    return offset.clamp(0.0, solver.maxScrollOffset);
  }

  @override
  Rect? controllerNodeRect(Object id) => nodeRect(id);

  @override
  Object? controllerNodeAt(Offset local) {
    final int slot = hitTester.hitTestLocal(local);
    return slot < 0 ? null : solver.store.ids[slot];
  }

  @override
  Future<void> controllerWhenSettled() {
    if (!_isMoving) return Future<void>.value();
    final Completer<void> done = Completer<void>();
    _settleWaiters.add(done);
    return done.future;
  }

  // ------------------------------------------------------------- lifecycle

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    PaintingBinding.instance.systemFonts.addListener(_fontsListener);
    _scheduleTick();
  }

  @override
  void detach() {
    final int? id = _frameCallbackId;
    if (id != null) SchedulerBinding.instance.cancelFrameCallbackWithId(id);
    _frameCallbackId = null;
    _lastFrame = null;
    PaintingBinding.instance.systemFonts.removeListener(_fontsListener);
    // Nothing will move while detached; release anyone waiting.
    _scrollTarget = null;
    _completeAll(_scrollWaiters);
    _completeAll(_settleWaiters);
    super.detach();
  }

  void _onSystemFontsChanged() {
    textCompiler.clear();
    markNeedsPaint();
  }

  @override
  void reassemble() {
    super.reassemble();
    textCompiler.clear();
    hitTester.invalidate();
    markNeedsPaint();
  }

  @override
  void dispose() {
    _controller?.detach(this);
    _controller = null;
    _router.dispose();
    textCompiler.dispose();
    perf.dispose();
    _sheen?.dispose();
    _sheen = null;
    _clipLayer.layer = null;
    _semanticsNodes.clear();
    super.dispose();
  }

  // ---------------------------------------------------------------- layout

  Size _computeSize(BoxConstraints c) {
    final double dw = _spec.designSize.width, dh = _spec.designSize.height;
    Size s;
    if (c.hasBoundedWidth && c.hasBoundedHeight) {
      s = c.biggest;
    } else if (c.hasBoundedWidth) {
      s = Size(c.maxWidth, c.maxWidth * dh / dw);
    } else if (c.hasBoundedHeight) {
      s = Size(c.maxHeight * dw / dh, c.maxHeight);
    } else {
      s = _spec.designSize;
    }
    return c.constrain(s);
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      _computeSize(constraints);

  @override
  void performLayout() {
    size = _computeSize(constraints);
    solver.updateMatrix(size, _fit);
    if (_enableScroll) {
      if (!_scrollDragging) {
        solver.scrollOffset = solver.scrollOffset.clamp(
          0.0,
          solver.maxScrollOffset,
        );
      }
    } else {
      solver.scrollOffset = 0;
    }
    hitTester.invalidate();
  }

  double _intrinsicWidth(double height) => height.isFinite
      ? height * _spec.designSize.width / _spec.designSize.height
      : _spec.designSize.width;

  double _intrinsicHeight(double width) => width.isFinite
      ? width * _spec.designSize.height / _spec.designSize.width
      : _spec.designSize.height;

  @override
  double computeMinIntrinsicWidth(double height) => _intrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) => _intrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) => _intrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _intrinsicHeight(width);

  // ----------------------------------------------------------------- paint

  @override
  bool get isRepaintBoundary => true;

  bool get _needsClip {
    if (_enableScroll || _fit == MorphFit.cover || _fit == MorphFit.none) {
      return true;
    }
    final Rect c = solver.contentBounds;
    final Size d = _spec.designSize;
    return c.left < 0 || c.top < 0 || c.right > d.width || c.bottom > d.height;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    debugPaintCount++;
    if (_needsClip) {
      _clipLayer.layer = context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        _paintFieldCallback,
        oldLayer: _clipLayer.layer,
      );
    } else {
      _clipLayer.layer = null;
      _paintField(context, offset);
    }
  }

  void _paintField(PaintingContext context, Offset offset) {
    _paintClock
      ..reset()
      ..start();
    final Canvas canvas = context.canvas;
    final MorphFieldStore s = solver.store;
    final int n = s.length;
    final MorphImageAtlas? atlas = _usableAtlas;
    final MorphSheenShader? sheen = _effectIntensity > 0 ? _sheen : null;
    int draws = 0;

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    if (n > 0 && _paintMode == MorphPaintMode.shapes) {
      if (sheen != null) _setSheenUniforms(sheen);
      draws = _paintShapes(canvas, atlas, sheen);
      if (_debugPaintNodeBounds || debugPaintSizeEnabled) {
        for (int q = 0; q < n; q++) {
          canvas.drawRect(_localCurrentRect(solver.drawOrder[q]), _debugPaint);
        }
      }
      if (_hasKeyboardFocus) _paintFocusRing(canvas);
    } else if (n > 0) {
      final double scale = math.sqrt((solver.scaleX * solver.scaleY).abs());
      if (mesh.ensurePlan(solver, scale * _devicePixelRatio)) {
        mesh.shrinkToFit();
      }
      if (_textDrawn.length < n) _textDrawn = Uint8List(mesh.capacity);
      final double aa = scale > 0 ? 1 / (_devicePixelRatio * scale) : 0;
      final Int32List order = solver.drawOrder;
      bool anyText = false;
      int culled = 0;
      for (int q = 0; q < n; q++) {
        final int slot = order[q];
        _textDrawn[q] = 0;
        if (_offscreen(slot)) {
          // Skip the vertex work; the node's triangles draw invisibly.
          mesh.hideNode(q, overlay: sheen != null);
          _textDrawn[q] = 1;
          culled++;
          continue;
        }
        mesh.writeNode(
          q,
          slot,
          solver,
          aaDesign: aa,
          atlas: atlas,
          overlay: sheen != null,
        );
        if (s.hasFlag(slot, MorphAux.flagHasText)) anyText = true;
      }
      perf.culled = culled;
      if (sheen != null) _setSheenUniforms(sheen);
      // Text normally goes after every mesh. A text node that a later node
      // covers at rest ends the current mesh run instead (see
      // _rebuildTextSplits), so that later node draws over its text.
      int runStart = 0;
      if (anyText) {
        for (int q = 0; q < n - 1; q++) {
          if (_splitAfter[q] == 0 || _textDrawn[q] == 1) continue;
          final int slot = order[q];
          draws += _drawMeshRange(canvas, runStart, q + 1, atlas, sheen);
          runStart = q + 1;
          _drawText(canvas, slot);
          _textDrawn[q] = 1;
        }
      }
      draws += _drawMeshRange(canvas, runStart, n, atlas, sheen);
      if (anyText) {
        for (int q = 0; q < n; q++) {
          if (_textDrawn[q] == 1) continue;
          final int slot = order[q];
          if (s.hasFlag(slot, MorphAux.flagHasText)) _drawText(canvas, slot);
        }
      }
      if (_debugPaintNodeBounds || debugPaintSizeEnabled) {
        _paintDebugBounds(canvas, n);
      }
      if (_hasKeyboardFocus) _paintFocusRing(canvas);
    }
    _paintClock.stop();
    perf.recordPaint(
      _paintClock.elapsedMicroseconds,
      draws,
      n,
      solver.isActive,
    );
    if (_showPerfOverlay) _paintPerf(canvas);
    canvas.restore();
  }

  void _setSheenUniforms(MorphSheenShader sheen) {
    sheen.setUniforms(
      width: size.width,
      height: size.height,
      lightX: _lightX < 0 ? size.width / 2 : _lightX,
      lightY: _lightY < 0 ? size.height / 3 : _lightY,
      time: _time,
      intensity: _effectIntensity,
    );
  }

  final Paint _shapePaint = Paint();
  final Paint _borderPaint = Paint();
  final Paint _imagePaint = Paint()..filterQuality = FilterQuality.low;

  @pragma('vm:prefer-inline')
  static Color _argb(int argb, double alpha) => Color(
    ((((argb >> 24) & 0xff) * alpha).round().clamp(0, 255) << 24) |
        (argb & 0x00ffffff),
  );

  /// Whether slot [slot] lies entirely outside the box (with a small margin
  /// for anti-aliasing and the focus ring). Rotated nodes use their bounding
  /// circle. Cheap enough to run per node per frame.
  bool _offscreen(int slot) {
    final MorphFieldStore s = solver.store;
    final Float32List l = s.layout, a = s.aux;
    final Float64List m = solver.matrix.storage;
    final int b = MorphLayout.base(slot), x = MorphAux.base(slot);
    final double sx = m[0].abs(), sy = m[5].abs();
    final double p = math.max(0, a[x + MorphAux.presence]);
    final double w = l[b + MorphLayout.width].abs();
    final double h = l[b + MorphLayout.height].abs();
    double hx, hy;
    if (a[x + MorphAux.rotation] == 0) {
      hx = w * sx * p / 2;
      hy = h * sy * p / 2;
    } else {
      hx = hy = math.sqrt(w * w + h * h) / 2 * math.max(sx, sy) * p;
    }
    final double cx = m[0] * l[b + MorphLayout.currentX] + m[12];
    final double cy = m[5] * l[b + MorphLayout.currentY] + m[13];
    const double pad = 6;
    return cx + hx < -pad ||
        cx - hx > size.width + pad ||
        cy + hy < -pad ||
        cy - hy > size.height + pad;
  }

  /// [MorphPaintMode.shapes]: each node as a rounded rectangle (plus border,
  /// image and text) in paint order. Returns the number of draw calls.
  int _paintShapes(
    Canvas canvas,
    MorphImageAtlas? atlas,
    MorphSheenShader? sheen,
  ) {
    final MorphFieldStore s = solver.store;
    final Float32List l = s.layout, a = s.aux;
    final Float64List m = solver.matrix.storage;
    final double m0 = m[0], m5 = m[5], m12 = m[12], m13 = m[13];
    final Int32List order = solver.drawOrder;
    final int n = s.length;
    int draws = 0, culled = 0;
    for (int q = 0; q < n; q++) {
      final int slot = order[q];
      final int b = MorphLayout.base(slot), x = MorphAux.base(slot);
      final double p = a[x + MorphAux.presence];
      final double alpha = (a[x + MorphAux.opacity] * p).clamp(0.0, 1.0);
      if (alpha <= 0.004 || p <= 0) continue;
      if (_offscreen(slot)) {
        culled++;
        continue;
      }
      final double w = math.max(0, l[b + MorphLayout.width]);
      final double h = math.max(0, l[b + MorphLayout.height]);
      final double r = math.min(
        a[x + MorphAux.cornerRadius],
        math.min(w, h) / 2,
      );
      final double bw = math.min(
        a[x + MorphAux.borderWidth],
        math.min(w, h) / 2,
      );
      final double rot = a[x + MorphAux.rotation];
      final bool transformed = rot != 0 || p != 1;
      RRect outer;
      if (transformed) {
        canvas.save();
        _enterNode(canvas, slot);
        outer = RRect.fromLTRBR(
          -w / 2,
          -h / 2,
          w / 2,
          h / 2,
          Radius.circular(r),
        );
      } else {
        // Axis-aligned: map straight to local pixels, no canvas transform.
        final double cx = m0 * l[b + MorphLayout.currentX] + m12;
        final double cy = m5 * l[b + MorphLayout.currentY] + m13;
        final double hw = w * m0 / 2, hh = h * m5 / 2;
        outer = RRect.fromLTRBXY(
          cx - hw,
          cy - hh,
          cx + hw,
          cy + hh,
          r * m0,
          r * m5,
        );
      }
      final RRect inner = bw > 0
          ? outer.deflate(transformed ? bw : bw * math.min(m0, m5))
          : outer;
      if (bw > 0) {
        final MorphNodeSpec? spec = s.specs[slot];
        _borderPaint.color = alpha >= 0.999 && spec != null
            ? spec.borderColor
            : _argb(s.borderColors[slot], alpha);
        canvas.drawDRRect(outer, inner, _borderPaint);
        draws++;
      }
      final int atlasSlot = atlas == null
          ? -1
          : a[x + MorphAux.atlasSlot].toInt();
      if (atlasSlot >= 0) {
        final Float32List rr = atlas!.rects;
        canvas.save();
        canvas.clipRRect(inner);
        _imagePaint.color = Color.fromRGBO(255, 255, 255, alpha);
        final int tint = s.tintColors[slot];
        _imagePaint.colorFilter = (tint & 0x00ffffff) == 0x00ffffff
            ? null
            : ColorFilter.mode(Color(tint | 0xff000000), BlendMode.modulate);
        // Texel-centre rectangle (inset half a texel), so smoothing never
        // samples the atlas padding around the image.
        double sl = rr[atlasSlot * 4], st = rr[atlasSlot * 4 + 1];
        double sr = rr[atlasSlot * 4 + 2], sb = rr[atlasSlot * 4 + 3];
        final Rect dst = inner.outerRect;
        if (s.specs[slot]?.imageFit != MorphImageFit.fill &&
            dst.width > 0 &&
            dst.height > 0) {
          // Cover: crop the source to the node's aspect ratio, centred.
          final double nodeAspect = dst.width / dst.height;
          if (nodeAspect > (sr - sl) / (sb - st)) {
            final double h = (sr - sl) / nodeAspect, cy = (st + sb) / 2;
            st = cy - h / 2;
            sb = cy + h / 2;
          } else {
            final double w = (sb - st) * nodeAspect, cx = (sl + sr) / 2;
            sl = cx - w / 2;
            sr = cx + w / 2;
          }
        }
        canvas.drawImageRect(
          atlas.image,
          Rect.fromLTRB(sl, st, sr, sb),
          dst,
          _imagePaint,
        );
        canvas.restore();
      } else {
        // Opaque nodes reuse the spec's Color: no allocation per frame.
        final MorphNodeSpec? spec = s.specs[slot];
        _shapePaint.color = alpha >= 0.999 && spec != null
            ? (_dark ? (spec.darkColor ?? spec.color) : spec.color)
            : _argb(s.fillColors[slot], alpha);
        canvas.drawRRect(inner, _shapePaint);
      }
      draws++;
      if (sheen != null) {
        _overlayPaint
          ..shader = sheen.shader
          ..color = Color.fromRGBO(255, 255, 255, alpha);
        canvas.drawRRect(outer, _overlayPaint);
        draws++;
      }
      if (transformed) canvas.restore();
      if ((a[x + MorphAux.flags].toInt() & MorphAux.flagHasText) != 0) {
        _drawText(canvas, slot);
      }
    }
    perf.culled = culled;
    return draws;
  }

  /// Current (animated) axis-aligned bounds of a node in local pixels.
  Rect _localCurrentRect(int slot) {
    final MorphFieldStore s = solver.store;
    final int b = MorphLayout.base(slot), x = MorphAux.base(slot);
    final double r = s.aux[x + MorphAux.rotation];
    final double p = math.max(0, s.aux[x + MorphAux.presence]);
    final double w = s.layout[b + MorphLayout.width] * p;
    final double h = s.layout[b + MorphLayout.height] * p;
    final double c = math.cos(r).abs(), sn = math.sin(r).abs();
    final double ex = (w * c + h * sn) / 2, ey = (w * sn + h * c) / 2;
    final double cx = s.layout[b + MorphLayout.currentX];
    final double cy = s.layout[b + MorphLayout.currentY];
    return Rect.fromPoints(
      solver.designToLocal(Offset(cx - ex, cy - ey)),
      solver.designToLocal(Offset(cx + ex, cy + ey)),
    );
  }

  void _visitOverlap(int j) {
    if (_overlapFound || j <= _queryRank) return;
    final Float32List b = _restBoxes;
    final int o = j * 4;
    if (b[o] < _qr && b[o + 2] > _ql && b[o + 1] < _qb && b[o + 3] > _qt) {
      // Transparent or exiting nodes cannot hide text.
      final int x = MorphAux.base(solver.drawOrder[j]);
      final Float32List aux = solver.store.aux;
      if (aux[x + MorphAux.opacity] > 0.004 &&
          aux[x + MorphAux.presenceTarget] > 0) {
        _overlapFound = true;
      }
    }
  }

  /// Draws paint positions [start, end) — one drawVertices per 16-bit
  /// index batch they touch (plus the effect pass when enabled).
  int _drawMeshRange(
    Canvas canvas,
    int start,
    int end,
    MorphImageAtlas? atlas,
    MorphSheenShader? sheen,
  ) {
    int draws = 0;
    for (int k = 0; k < mesh.batchCount; k++) {
      final int qs = mesh.batchStart[k], qe = mesh.batchStart[k + 1];
      final int s0 = math.max(start, qs), e0 = math.min(end, qe);
      if (s0 >= e0) continue;
      // Indices are relative to the batch's first vertex, so the vertex view
      // starts there even when the run starts mid-batch.
      final int vBase = mesh.vertStart[qs];
      final int vCount = mesh.vertStart[e0] - vBase;
      final Float32List positions = Float32List.view(
        mesh.positions.buffer,
        mesh.positions.offsetInBytes + vBase * 2 * Float32List.bytesPerElement,
        vCount * 2,
      );
      final Uint16List indices = Uint16List.view(
        mesh.indices.buffer,
        mesh.indices.offsetInBytes +
            mesh.indexStart[s0] * Uint16List.bytesPerElement,
        mesh.indexStart[e0] - mesh.indexStart[s0],
      );
      final ui.Vertices vertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        positions,
        textureCoordinates: atlas == null
            ? null
            : Float32List.view(
                mesh.texCoords.buffer,
                mesh.texCoords.offsetInBytes +
                    vBase * 2 * Float32List.bytesPerElement,
                vCount * 2,
              ),
        colors: Int32List.view(
          mesh.colors.buffer,
          mesh.colors.offsetInBytes + vBase * Int32List.bytesPerElement,
          vCount,
        ),
        indices: indices,
      );
      MorphDebugStats.liveVertices++;
      _meshPaint.shader = atlas?.shader;
      canvas.drawVertices(
        vertices,
        atlas == null ? BlendMode.dst : BlendMode.modulate,
        _meshPaint,
      );
      vertices.dispose();
      MorphDebugStats.liveVertices--;
      draws++;
      if (sheen != null) {
        final ui.Vertices overlay = ui.Vertices.raw(
          ui.VertexMode.triangles,
          positions,
          colors: Int32List.view(
            mesh.overlayColors.buffer,
            mesh.overlayColors.offsetInBytes +
                vBase * Int32List.bytesPerElement,
            vCount,
          ),
          indices: indices,
        );
        MorphDebugStats.liveVertices++;
        _overlayPaint.shader = sheen.shader;
        canvas.drawVertices(overlay, BlendMode.modulate, _overlayPaint);
        overlay.dispose();
        MorphDebugStats.liveVertices--;
        draws++;
      }
    }
    return draws;
  }

  /// Applies the node's full transform (matrix, centre, rotation, presence)
  /// to [canvas] so drawing can happen in node-local design units.
  void _enterNode(Canvas canvas, int slot) {
    final MorphFieldStore s = solver.store;
    final int b = MorphLayout.base(slot), x = MorphAux.base(slot);
    final Float64List m = solver.matrix.storage;
    final double cx = s.layout[b + MorphLayout.currentX],
        cy = s.layout[b + MorphLayout.currentY];
    canvas.translate(
      m[0] * cx + m[4] * cy + m[12],
      m[1] * cx + m[5] * cy + m[13],
    );
    canvas.scale(m[0], m[5]);
    final double rot = s.aux[x + MorphAux.rotation];
    if (rot != 0) canvas.rotate(rot);
    final double p = math.max(0, s.aux[x + MorphAux.presence]);
    if (p != 1) canvas.scale(p, p);
  }

  void _drawText(Canvas canvas, int slot) {
    final MorphFieldStore s = solver.store;
    final MorphNodeSpec? spec = s.specs[slot];
    final Object? id = s.ids[slot];
    if (spec == null || id == null) return;
    final int b = MorphLayout.base(slot), x = MorphAux.base(slot);
    final double presence = s.aux[x + MorphAux.presence];
    final double alpha = (s.aux[x + MorphAux.opacity] * presence).clamp(
      0.0,
      1.0,
    );
    if (alpha <= 0.004 || presence <= 0.01) return;
    final double w = math.max(0, s.layout[b + MorphLayout.width]);
    final double h = math.max(0, s.layout[b + MorphLayout.height]);
    final double pad = s.aux[x + MorphAux.textPadding];
    final ui.Paragraph? paragraph = textCompiler.paragraphFor(
      id,
      spec,
      math.max(0, w - 2 * pad),
    );
    if (paragraph == null) return;
    final double top = switch (spec.textVerticalAlign) {
      MorphTextVerticalAlign.top => -h / 2 + pad,
      MorphTextVerticalAlign.center => -paragraph.height / 2,
      MorphTextVerticalAlign.bottom => h / 2 - pad - paragraph.height,
      MorphTextVerticalAlign.firstBaseline => -paragraph.alphabeticBaseline,
    };
    final bool overflow = paragraph.height > h - 2 * pad + 0.5;
    final bool fading = alpha < 0.996;
    canvas.save();
    _enterNode(canvas, slot);
    if (overflow || fading) {
      final Rect clip = Rect.fromLTRB(-w / 2, -h / 2, w / 2, h / 2);
      if (overflow) canvas.clipRect(clip);
      if (fading) {
        _layerPaint.color = Color.fromRGBO(0, 0, 0, alpha);
        canvas.saveLayer(clip, _layerPaint);
      }
    }
    canvas.translate(-w / 2 + pad, top);
    canvas.drawParagraph(paragraph, Offset.zero);
    if (fading) canvas.restore();
    canvas.restore();
  }

  void _paintDebugBounds(Canvas canvas, int n) {
    final Float32List b = mesh.bounds;
    for (int q = 0; q < n; q++) {
      canvas.drawRect(
        Rect.fromLTRB(b[q * 4], b[q * 4 + 1], b[q * 4 + 2], b[q * 4 + 3]),
        _debugPaint,
      );
    }
  }

  void _paintFocusRing(Canvas canvas) {
    final Object? id = _focusedId;
    if (id == null) return;
    final int? slot = solver.slotOf(id);
    if (slot == null) return;
    final MorphFieldStore s = solver.store;
    final int b = MorphLayout.base(slot), x = MorphAux.base(slot);
    final double w = s.layout[b + MorphLayout.width],
        h = s.layout[b + MorphLayout.height];
    final double scale = math.max(
      1e-6,
      math.sqrt((solver.scaleX * solver.scaleY).abs()),
    );
    final double gap = 3 / scale;
    _focusPaint
      ..color = _focusColor
      ..strokeWidth = 2 / scale;
    canvas.save();
    _enterNode(canvas, slot);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(-w / 2 - gap, -h / 2 - gap, w / 2 + gap, h / 2 + gap),
        Radius.circular(s.aux[x + MorphAux.cornerRadius] + gap),
      ),
      _focusPaint,
    );
    canvas.restore();
  }

  void _paintPerf(Canvas canvas) {
    final ui.Paragraph p = perf.paragraph();
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(6, 6, p.longestLine + 12, p.height + 8),
        const Radius.circular(4),
      ),
      _perfBackground,
    );
    canvas.drawParagraph(p, const Offset(12, 10));
  }

  // ------------------------------------------------------------- keyboard

  List<int> _focusOrder() {
    final MorphFieldStore s = solver.store;
    final List<int> slots = <int>[
      for (int i = 0; i < s.length; i++)
        if (s.hasFlag(i, MorphAux.flagInteractive) &&
            s.aux[MorphAux.base(i) + MorphAux.presenceTarget] > 0)
          i,
    ];
    slots.sort((int a, int b) {
      final Offset ca = s.targetCenter(a), cb = s.targetCenter(b);
      final int row = ca.dy.round().compareTo(cb.dy.round());
      return row != 0 ? row : ca.dx.compareTo(cb.dx);
    });
    return slots;
  }

  /// Moves keyboard focus to the next ([forward]) or previous node in
  /// reading order. Returns false at either end so focus can leave the field.
  bool focusNext({required bool forward}) {
    final List<int> order = _focusOrder();
    if (order.isEmpty) return false;
    final Object? focused = _focusedId;
    final int? current = focused == null ? null : solver.slotOf(focused);
    final int idx = current == null ? -1 : order.indexOf(current);
    final int next = idx == -1
        ? (forward ? 0 : order.length - 1)
        : idx + (forward ? 1 : -1);
    if (next < 0 || next >= order.length) {
      _focusedId = null;
      markNeedsPaint();
      return false;
    }
    _setFocused(order[next]);
    return true;
  }

  /// Moves keyboard focus to the nearest node in [direction].
  bool moveFocus(TraversalDirection direction) {
    final List<int> order = _focusOrder();
    if (order.isEmpty) return false;
    final Object? focused = _focusedId;
    final int? current = focused == null ? null : solver.slotOf(focused);
    if (current == null) {
      _setFocused(order.first);
      return true;
    }
    final MorphFieldStore s = solver.store;
    final Offset c = s.targetCenter(current);
    int best = -1;
    double bestScore = double.infinity;
    for (final int slot in order) {
      if (slot == current) continue;
      final Offset d = s.targetCenter(slot) - c;
      final (double primary, double secondary) = switch (direction) {
        TraversalDirection.left => (-d.dx, d.dy.abs()),
        TraversalDirection.right => (d.dx, d.dy.abs()),
        TraversalDirection.up => (-d.dy, d.dx.abs()),
        TraversalDirection.down => (d.dy, d.dx.abs()),
      };
      if (primary <= 0.5) continue;
      final double score = primary + 2 * secondary;
      if (score < bestScore) {
        bestScore = score;
        best = slot;
      }
    }
    if (best < 0) return false;
    _setFocused(best);
    return true;
  }

  /// Activates the focused node as if tapped.
  bool activateFocused() {
    final Object? id = _focusedId;
    if (id == null || onNodeTap == null) return false;
    final int? slot = solver.slotOf(id);
    if (slot == null) return false;
    handleNodeTap(slot);
    return true;
  }

  void _setFocused(int slot) {
    _focusedId = solver.store.ids[slot];
    if (_enableScroll && hasSize) {
      final Rect r = _localTargetRect(slot);
      final bool vertical = solver.scrollAxis == Axis.vertical;
      final double lo = vertical ? r.top : r.left;
      final double hi = vertical ? r.bottom : r.right;
      double off = solver.scrollOffset;
      if (lo < 0) off += lo - 8;
      if (hi > _viewportExtent) off += hi - _viewportExtent + 8;
      solver.scrollOffset = off.clamp(0.0, solver.maxScrollOffset);
      _controller?.notifyFieldChanged();
    }
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  Rect _localTargetRect(int slot) {
    final MorphFieldStore s = solver.store;
    final int b = MorphLayout.base(slot), x = MorphAux.base(slot);
    final double r = s.aux[x + MorphAux.rotation];
    final double w = s.aux[x + MorphAux.targetW],
        h = s.aux[x + MorphAux.targetH];
    final double c = math.cos(r).abs(), sn = math.sin(r).abs();
    final double ex = (w * c + h * sn) / 2, ey = (w * sn + h * c) / 2;
    final double tx = s.layout[b + MorphLayout.targetX],
        ty = s.layout[b + MorphLayout.targetY];
    return Rect.fromPoints(
      solver.designToLocal(Offset(tx - ex, ty - ey)),
      solver.designToLocal(Offset(tx + ex, ty + ey)),
    );
  }

  /// Local rectangle a node will occupy at rest (for tests and overlays).
  Rect? nodeRect(Object id) {
    final int? slot = solver.slotOf(id);
    return slot == null ? null : _localTargetRect(slot);
  }

  // ------------------------------------------------------------ semantics

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    if (!_semanticsEnabled) return;
    config
      ..isSemanticBoundary = true
      ..explicitChildNodes = true;
    if (!_enableScroll || !hasSize) return;
    final double max = solver.maxScrollOffset;
    if (max <= 0) return;
    final double offset = solver.scrollOffset.clamp(0.0, max);
    final double page = _viewportExtent * 0.8;
    config
      ..hasImplicitScrolling = true
      ..scrollPosition = offset
      ..scrollExtentMin = 0
      ..scrollExtentMax = max;
    // "Scroll up/left" moves the content that way, revealing what follows.
    void forward() => animateScrollTo(solver.scrollOffset + page);
    void backward() => animateScrollTo(solver.scrollOffset - page);
    if (solver.scrollAxis == Axis.vertical) {
      if (offset < max) config.onScrollUp = forward;
      if (offset > 0) config.onScrollDown = backward;
    } else {
      if (offset < max) config.onScrollLeft = forward;
      if (offset > 0) config.onScrollRight = backward;
    }
  }

  @override
  void assembleSemanticsNode(
    SemanticsNode node,
    SemanticsConfiguration config,
    Iterable<SemanticsNode> children,
  ) {
    if (!_semanticsEnabled) {
      super.assembleSemanticsNode(node, config, children);
      return;
    }
    final MorphFieldStore s = solver.store;
    final List<SemanticsNode> out = <SemanticsNode>[];
    final Set<Object> used = <Object>{};
    final Rect viewport = Offset.zero & size;
    final Rect cacheArea = viewport.inflate(math.max(size.width, size.height));
    for (int q = 0; q < s.length; q++) {
      final int slot = solver.drawOrder[q];
      final MorphNodeSpec? spec = s.specs[slot];
      final Object? id = s.ids[slot];
      if (spec == null || id == null) continue;
      if (s.aux[MorphAux.base(slot) + MorphAux.presenceTarget] == 0) continue;
      final String label = spec.semanticLabel ?? spec.text ?? '';
      if (label.isEmpty) continue;
      final Rect rect = _localTargetRect(slot);
      // Like scrolling lists, expose only nodes within one viewport of the
      // visible area, so huge fields don't build huge semantics trees.
      if (!rect.overlaps(cacheArea)) continue;
      final SemanticsNode child = _semanticsNodes[id] ??= SemanticsNode();
      final SemanticsConfiguration cfg = SemanticsConfiguration()
        ..label = label
        ..textDirection = textDirection
        ..isHidden = !rect.overlaps(viewport);
      if (spec.interactive && onNodeTap != null) {
        cfg
          ..isButton = true
          ..isFocused = _hasKeyboardFocus && _focusedId == id
          ..onTap = () {
            final int? live = solver.slotOf(id);
            if (live != null) handleNodeTap(live);
          };
      }
      child
        ..rect = rect
        ..updateWith(config: cfg);
      out.add(child);
      used.add(id);
    }
    _semanticsNodes.removeWhere(
      (Object k, SemanticsNode _) => !used.contains(k),
    );
    node.updateWith(
      config: config,
      childrenInInversePaintOrder: out.reversed.toList(),
    );
  }

  @override
  void clearSemantics() {
    super.clearSemantics();
    _semanticsNodes.clear();
  }

  // ---------------------------------------------------------------- debug

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(IntProperty('nodes', solver.store.length))
      ..add(DiagnosticsProperty<Size>('designSize', _spec.designSize))
      ..add(EnumProperty<MorphFit>('fit', _fit))
      ..add(
        FlagProperty('animating', value: solver.isActive, ifTrue: 'animating'),
      )
      ..add(
        FlagProperty(
          'enableScroll',
          value: _enableScroll,
          ifTrue: 'scrollable',
        ),
      )
      ..add(
        DoubleProperty('scrollOffset', solver.scrollOffset, defaultValue: 0.0),
      )
      ..add(
        FlagProperty(
          'reduceMotion',
          value: reduceMotion,
          ifTrue: 'reduce motion',
        ),
      )
      ..add(
        FlagProperty(
          'atlas',
          value: _usableAtlas != null,
          ifTrue: 'image atlas',
        ),
      )
      ..add(
        FlagProperty('sheen', value: _sheen != null, ifTrue: 'sheen effect'),
      )
      ..add(
        DiagnosticsProperty<Object?>(
          'focusedId',
          _focusedId,
          defaultValue: null,
        ),
      );
  }
}
