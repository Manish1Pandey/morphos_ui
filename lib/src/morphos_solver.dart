// Module 2: the matrix field resolution engine.
//
// Nodes live and move in design space. One affine matrix, derived from the
// box the field is laid out in, maps design space to local pixels; the
// painter and hit tester apply it (or its inverse) in a single pass over the
// buffers. Motion comes from a fixed-step spring integrator, so no
// AnimationController is involved.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/painting.dart' show Axis;
import 'package:vector_math/vector_math_64.dart';

import 'morphos_spec.dart';

/// How the design space is fitted into the box the field is laid out in.
enum MorphFit {
  /// Uniform scale so the whole design fits; centred.
  contain,

  /// Uniform scale so the design covers the box; centred and clipped.
  cover,

  /// Independent x/y scale so the design exactly fills the box.
  fill,

  /// Uniform scale so the design width fills the box; top-aligned. Use with
  /// vertical scrolling.
  fitWidth,

  /// Uniform scale so the design height fills the box; start-aligned. Use
  /// with horizontal scrolling.
  fitHeight,

  /// No scaling; centred.
  none,
}

/// When each node starts moving after a spec change.
sealed class MorphStagger {
  const MorphStagger();

  /// Every node starts at once.
  static const MorphStagger none = _NoStagger();

  /// Node `i` in spec order starts `i * step` later, capped at [max].
  const factory MorphStagger.byIndex(Duration step, {Duration max}) =
      _IndexStagger;

  /// Nodes start later the further their new centre is from [origin]
  /// (design space): [perHundredUnits] of delay per 100 design units, capped
  /// at [max]. Gives a ripple from a tap point.
  const factory MorphStagger.fromPoint(
    Offset origin, {
    Duration perHundredUnits,
    Duration max,
  }) = _PointStagger;

  /// Delay in seconds for the node at [index] whose target centre is [center].
  double delayFor(int index, Offset center);
}

final class _NoStagger extends MorphStagger {
  const _NoStagger();

  @override
  double delayFor(int index, Offset center) => 0;

  @override
  bool operator ==(Object other) => other is _NoStagger;

  @override
  int get hashCode => 0;
}

final class _IndexStagger extends MorphStagger {
  const _IndexStagger(
    this.step, {
    this.max = const Duration(milliseconds: 600),
  });

  final Duration step;
  final Duration max;

  @override
  double delayFor(int index, Offset center) =>
      math.min(index * step.inMicroseconds, max.inMicroseconds) / 1e6;

  @override
  bool operator ==(Object other) =>
      other is _IndexStagger && other.step == step && other.max == max;

  @override
  int get hashCode => Object.hash(step, max);
}

final class _PointStagger extends MorphStagger {
  const _PointStagger(
    this.origin, {
    this.perHundredUnits = const Duration(milliseconds: 40),
    this.max = const Duration(milliseconds: 600),
  });

  final Offset origin;
  final Duration perHundredUnits;
  final Duration max;

  @override
  double delayFor(int index, Offset center) {
    final double d =
        (center - origin).distance / 100 * perHundredUnits.inMicroseconds;
    return math.min(d, max.inMicroseconds.toDouble()) / 1e6;
  }

  @override
  bool operator ==(Object other) =>
      other is _PointStagger &&
      other.origin == origin &&
      other.perHundredUnits == perHundredUnits &&
      other.max == max;

  @override
  int get hashCode => Object.hash(origin, perHundredUnits, max);
}

/// Receives every physics-relevant command a [MorphFieldSolver] executes.
/// Implemented by `MorphRecorder` for deterministic replay.
abstract interface class MorphSolverObserver {
  /// A spec was applied.
  void onApplySpec(
    MorphFieldSpec spec,
    MorphStagger stagger, {
    required bool animateEntryExit,
    required bool brightnessDark,
    required bool mirror,
  });

  /// The solver advanced by [dt] seconds.
  void onStep(double dt);

  /// A drag began on node [id].
  void onBeginDrag(Object id);

  /// Node [id] was dragged by [delta] design units.
  void onDragBy(Object id, Offset delta);

  /// A drag on node [id] ended with [velocity] design units per second.
  void onEndDrag(Object id, Offset velocity);

  /// Reduced-motion mode was switched.
  void onReduceMotion(bool value);
}

/// Owns the node buffers, the field matrix and the spring integrator.
final class MorphFieldSolver {
  /// Creates an empty solver.
  MorphFieldSolver();

  /// Fixed integration step in seconds.
  static const double substep = 1 / 240;

  /// Largest frame delta accepted; longer gaps (jank, breakpoints) are clamped
  /// so springs never jump.
  static const double maxFrameDt = 1 / 30;

  /// Position tolerance (design units) below which a node is at rest.
  static const double restPosition = 0.01;

  /// Velocity tolerance below which a node is at rest.
  static const double restVelocity = 0.05;

  /// Node buffers.
  final MorphFieldStore store = MorphFieldStore();
  final MorphFieldStore _snapshot = MorphFieldStore();

  /// Design space to local pixels.
  final Matrix4 matrix = Matrix4.identity();

  /// Local pixels to design space. Valid only when [invertible].
  final Matrix4 inverse = Matrix4.identity();

  /// Whether [matrix] could be inverted (false for a zero-sized box).
  bool invertible = true;

  /// Design size of the current spec.
  Size designSize = const Size(1, 1);

  /// Box the matrix was computed for.
  Size boxSize = Size.zero;

  /// Fit used for the matrix.
  MorphFit fit = MorphFit.contain;

  double _scrollOffset = 0;

  /// Paint order: slot indices sorted by zIndex (stable).
  Int32List drawOrder = Int32List(16);

  /// Inverse of [drawOrder]: position of each slot in paint order.
  Int32List drawRank = Int32List(16);

  /// Union of all target rectangles in design space.
  Rect contentBounds = Rect.zero;

  Map<Object, int> _slotById = <Object, int>{};
  // Double buffer for [_slotById]: a spec change reads the old map while
  // filling this one, then they swap. No 5,000-entry copy per change.
  Map<Object, int> _slotByIdSpare = <Object, int>{};

  /// Receives every command, for recording.
  MorphSolverObserver? observer;

  double _accumulator = 0;
  bool _active = false;
  bool _needsCompaction = false;

  // Active set: slots that are moving, waiting on a stagger delay, entering or
  // exiting. Only these are integrated and settle-checked each frame, so a
  // field where one node moves costs the same at 100 nodes as at 100,000.
  Int32List _activeList = Int32List(16);
  Uint8List _isActive = Uint8List(16);
  int _activeCount = 0;

  /// Number of nodes the last [step] integrated (diagnostics and tests).
  int get activeCount => _activeCount;

  bool _lastMirror = false;
  bool _reduceMotion = false;
  bool _hasApplied = false;
  bool _dark = false;

  /// Monotonic counter bumped whenever slots are re-ordered or replaced, so
  /// caches keyed by slot know to refresh.
  int generation = 0;

  /// Whether any node is still moving or waiting on a stagger delay.
  bool get isActive => _active;

  /// Current vertical scroll offset in local pixels.
  double get scrollOffset => _scrollOffset;

  /// When true, every change snaps to its target (accessibility setting).
  bool get reduceMotion => _reduceMotion;

  set reduceMotion(bool value) {
    if (value == _reduceMotion) return;
    _reduceMotion = value;
    observer?.onReduceMotion(value);
    if (value) _snapAll();
  }

  /// Slot of node [id], or null if it is not in the field.
  int? slotOf(Object id) => _slotById[id];

  /// Ids currently in the field (including exiting nodes).
  Iterable<Object> get ids => _slotById.keys;

  /// Horizontal scale of [matrix].
  double get scaleX => matrix.storage[0];

  /// Vertical scale of [matrix].
  double get scaleY => matrix.storage[5];

  // ---------------------------------------------------------------- matrix

  /// Recomputes [matrix] and [inverse] for a box of [box] pixels. Returns true
  /// if the matrix changed.
  bool updateMatrix(Size box, MorphFit fit) {
    if (box == boxSize && fit == this.fit) return false;
    boxSize = box;
    this.fit = fit;
    _rebuildMatrix();
    return true;
  }

  /// Axis the scroll offset moves content along.
  Axis get scrollAxis => _scrollAxis;
  Axis _scrollAxis = Axis.vertical;
  set scrollAxis(Axis value) {
    if (value == _scrollAxis) return;
    _scrollAxis = value;
    _rebuildMatrix();
  }

  /// Sets the scroll offset (local pixels, along [scrollAxis]) and rebuilds
  /// the matrix.
  set scrollOffset(double value) {
    if (value == _scrollOffset || !value.isFinite) return;
    _scrollOffset = value;
    _rebuildMatrix();
  }

  void _rebuildMatrix() {
    final double dw = designSize.width, dh = designSize.height;
    final double bw = boxSize.width, bh = boxSize.height;
    double sx, sy, tx, ty;
    switch (fit) {
      case MorphFit.contain:
        sx = sy = math.min(bw / dw, bh / dh);
        tx = (bw - dw * sx) / 2;
        ty = (bh - dh * sy) / 2;
      case MorphFit.cover:
        sx = sy = math.max(bw / dw, bh / dh);
        tx = (bw - dw * sx) / 2;
        ty = (bh - dh * sy) / 2;
      case MorphFit.fill:
        sx = bw / dw;
        sy = bh / dh;
        tx = ty = 0;
      case MorphFit.fitWidth:
        sx = sy = bw / dw;
        tx = ty = 0;
      case MorphFit.fitHeight:
        sx = sy = bh / dh;
        tx = ty = 0;
      case MorphFit.none:
        sx = sy = 1;
        tx = (bw - dw) / 2;
        ty = (bh - dh) / 2;
    }
    if (!sx.isFinite) sx = 0;
    if (!sy.isFinite) sy = 0;
    matrix
      ..setIdentity()
      ..setEntry(0, 0, sx)
      ..setEntry(1, 1, sy)
      ..setEntry(
        0,
        3,
        tx - (_scrollAxis == Axis.horizontal ? _scrollOffset : 0),
      )
      ..setEntry(1, 3, ty - (_scrollAxis == Axis.vertical ? _scrollOffset : 0));
    invertible = inverse.copyInverse(matrix) != 0;
  }

  /// Largest meaningful scroll offset for the current content and box.
  double get maxScrollOffset {
    if (_scrollAxis == Axis.horizontal) {
      final double right =
          contentBounds.right * scaleX + matrix.storage[12] + _scrollOffset;
      return math.max(0, right - boxSize.width);
    }
    final double bottom =
        contentBounds.bottom * scaleY + matrix.storage[13] + _scrollOffset;
    return math.max(0, bottom - boxSize.height);
  }

  /// Maps a local pixel point to design space. Returns null when the matrix
  /// is degenerate.
  Offset? localToDesign(Offset local) {
    if (!invertible) return null;
    final Float64List m = inverse.storage;
    return Offset(
      m[0] * local.dx + m[4] * local.dy + m[12],
      m[1] * local.dx + m[5] * local.dy + m[13],
    );
  }

  /// Maps a design-space point to local pixels.
  Offset designToLocal(Offset design) {
    final Float64List m = matrix.storage;
    return Offset(
      m[0] * design.dx + m[4] * design.dy + m[12],
      m[1] * design.dx + m[5] * design.dy + m[13],
    );
  }

  /// Single affine pass over the layout buffer: writes every node's animated
  /// centre, mapped to local pixels, into [out] as interleaved x/y pairs.
  void transformCentersInto(Float32List out) {
    final Float64List m = matrix.storage;
    final Float32List l = store.layout;
    final int n = store.length;
    if (out.length < n * 2) {
      throw ArgumentError.value(out.length, 'out.length', 'needs ${n * 2}');
    }
    for (int i = 0; i < n; i++) {
      final int b = MorphLayout.base(i);
      final double x = l[b + MorphLayout.currentX],
          y = l[b + MorphLayout.currentY];
      out[i * 2] = m[0] * x + m[4] * y + m[12];
      out[i * 2 + 1] = m[1] * x + m[5] * y + m[13];
    }
  }

  // ------------------------------------------------------------------ spec

  /// Applies [spec], matching nodes to existing slots by id so motion carries
  /// over. New nodes grow in from presence 0 and removed nodes shrink out
  /// when [animateEntryExit] is true. [stagger] delays each node's start.
  ///
  /// With [mirror] (right-to-left layouts) every node is placed at its
  /// mirror image across the design's vertical centre line and its rotation
  /// is reversed; text and images are not flipped.
  void applySpec(
    MorphFieldSpec spec, {
    MorphStagger stagger = MorphStagger.none,
    bool animateEntryExit = true,
    bool brightnessDark = false,
    bool mirror = false,
  }) {
    observer?.onApplySpec(
      spec,
      stagger,
      animateEntryExit: animateEntryExit,
      brightnessDark: brightnessDark,
      mirror: mirror,
    );
    final bool darkChanged = _dark != brightnessDark;
    _dark = brightnessDark;
    final bool first = !_hasApplied;
    _hasApplied = true;
    final bool designChanged = spec.designSize != designSize;
    designSize = spec.designSize;

    _snapshot.copyFrom(store);
    final int oldLength = _snapshot.length;
    final Map<Object, int> oldSlots = _slotById;
    final Uint8List matched = Uint8List(oldLength);
    final List<MorphNodeSpec> nodes = spec.nodes;
    final int n = nodes.length;
    store.ensureCapacity(n + oldLength);
    final Float32List l = store.layout, a = store.aux;
    final Float32List ol = _snapshot.layout, oa = _snapshot.aux;
    final bool instant = first || _reduceMotion;
    // Unchanged nodes (same spec object, same slot, same mirroring and
    // brightness) keep their slot exactly as it is: no rewrite, no restarted
    // stagger. Small edits to big fields stay cheap.
    final bool reusable =
        !instant && !designChanged && mirror == _lastMirror && !darkChanged;
    _lastMirror = mirror;

    for (int j = 0; j < n; j++) {
      final MorphNodeSpec node = nodes[j];
      if (reusable &&
          j < oldLength &&
          identical(_snapshot.specs[j], node) &&
          _snapshot.aux[MorphAux.base(j) + MorphAux.presenceTarget] == 1) {
        matched[j] = 1;
        continue;
      }
      final Offset raw = node.centerIn(designSize);
      final Offset c = mirror ? Offset(designSize.width - raw.dx, raw.dy) : raw;
      final int b = MorphLayout.base(j), x = MorphAux.base(j);
      l[b + MorphLayout.anchorX] = node.anchor.dx;
      l[b + MorphLayout.anchorY] = node.anchor.dy;
      l[b + MorphLayout.posX] = node.position.dx;
      l[b + MorphLayout.posY] = node.position.dy;
      l[b + MorphLayout.elasticity] = node.elasticity;
      l[b + MorphLayout.mass] = node.mass;
      l[b + MorphLayout.targetX] = c.dx;
      l[b + MorphLayout.targetY] = c.dy;
      a[x + MorphAux.targetW] = node.size.width;
      a[x + MorphAux.targetH] = node.size.height;
      a[x + MorphAux.presenceTarget] = 1;
      a[x + MorphAux.damping] =
          2 * node.dampingRatio * math.sqrt(node.elasticity * node.mass);
      a[x + MorphAux.cornerRadius] = node.cornerRadius;
      a[x + MorphAux.opacity] = node.opacity;
      a[x + MorphAux.rotation] = mirror ? -node.rotation : node.rotation;
      a[x + MorphAux.borderWidth] = node.borderWidth;
      a[x + MorphAux.zIndex] = node.zIndex.toDouble();
      a[x + MorphAux.textPadding] = node.textPadding;
      a[x + MorphAux.atlasSlot] = -1;
      int flags = 0;
      if (node.interactive) flags |= MorphAux.flagInteractive;
      if (node.draggable) flags |= MorphAux.flagDraggable;
      if (node.text != null && node.text!.isNotEmpty) {
        flags |= MorphAux.flagHasText;
      }
      store.fillColors[j] =
          (_dark ? (node.darkColor ?? node.color) : node.color).toARGB32();
      store.borderColors[j] = node.borderColor.toARGB32();
      store.tintColors[j] = node.imageTint.toARGB32();
      store.ids[j] = node.id;
      store.specs[j] = node;

      final int? old = oldSlots[node.id];
      if (old != null && !instant) {
        matched[old] = 1;
        final int ob = MorphLayout.base(old), ox = MorphAux.base(old);
        l[b + MorphLayout.currentX] = ol[ob + MorphLayout.currentX];
        l[b + MorphLayout.currentY] = ol[ob + MorphLayout.currentY];
        l[b + MorphLayout.width] = ol[ob + MorphLayout.width];
        l[b + MorphLayout.height] = ol[ob + MorphLayout.height];
        a[x + MorphAux.velX] = oa[ox + MorphAux.velX];
        a[x + MorphAux.velY] = oa[ox + MorphAux.velY];
        a[x + MorphAux.velW] = oa[ox + MorphAux.velW];
        a[x + MorphAux.velH] = oa[ox + MorphAux.velH];
        a[x + MorphAux.presence] = oa[ox + MorphAux.presence];
        a[x + MorphAux.velPresence] = oa[ox + MorphAux.velPresence];
        a[x + MorphAux.prevTargetX] = ol[ob + MorphLayout.targetX];
        a[x + MorphAux.prevTargetY] = ol[ob + MorphLayout.targetY];
        a[x + MorphAux.prevTargetW] = oa[ox + MorphAux.targetW];
        a[x + MorphAux.prevTargetH] = oa[ox + MorphAux.targetH];
        a[x + MorphAux.prevPresenceTarget] = oa[ox + MorphAux.presenceTarget];
        if ((oa[ox + MorphAux.flags].toInt() & MorphAux.flagDragging) != 0) {
          flags |= MorphAux.flagDragging;
        }
      } else {
        if (old != null) matched[old] = 1;
        final bool enter = animateEntryExit && !instant;
        l[b + MorphLayout.currentX] = c.dx;
        l[b + MorphLayout.currentY] = c.dy;
        l[b + MorphLayout.width] = node.size.width;
        l[b + MorphLayout.height] = node.size.height;
        a[x + MorphAux.velX] = 0;
        a[x + MorphAux.velY] = 0;
        a[x + MorphAux.velW] = 0;
        a[x + MorphAux.velH] = 0;
        a[x + MorphAux.presence] = enter ? 0 : 1;
        a[x + MorphAux.velPresence] = 0;
        a[x + MorphAux.prevTargetX] = c.dx;
        a[x + MorphAux.prevTargetY] = c.dy;
        a[x + MorphAux.prevTargetW] = node.size.width;
        a[x + MorphAux.prevTargetH] = node.size.height;
        a[x + MorphAux.prevPresenceTarget] = enter ? 0 : 1;
      }
      a[x + MorphAux.flags] = flags.toDouble();
      a[x + MorphAux.delay] = instant ? 0 : stagger.delayFor(j, c);
    }

    int k = n;
    if (animateEntryExit && !instant) {
      for (int i = 0; i < oldLength; i++) {
        if (matched[i] == 1) continue;
        final int ox = MorphAux.base(i);
        if (oa[ox + MorphAux.presence] <= 0.001 &&
            oa[ox + MorphAux.presenceTarget] == 0) {
          continue;
        }
        store.copySlotFrom(_snapshot, i, k);
        final int b = MorphLayout.base(k), x = MorphAux.base(k);
        l[b + MorphLayout.targetX] = l[b + MorphLayout.currentX];
        l[b + MorphLayout.targetY] = l[b + MorphLayout.currentY];
        a[x + MorphAux.presenceTarget] = 0;
        a[x + MorphAux.prevPresenceTarget] = 0;
        a[x + MorphAux.prevTargetX] = l[b + MorphLayout.currentX];
        a[x + MorphAux.prevTargetY] = l[b + MorphLayout.currentY];
        a[x + MorphAux.prevTargetW] = a[x + MorphAux.targetW];
        a[x + MorphAux.prevTargetH] = a[x + MorphAux.targetH];
        a[x + MorphAux.delay] = 0;
        a[x + MorphAux.flags] =
            (a[x + MorphAux.flags].toInt() &
                    ~(MorphAux.flagDragging | MorphAux.flagInteractive))
                .toDouble();
        k++;
      }
    }
    store.length = k;
    store.releaseTail();
    store.shrinkToFit();
    _snapshot.length = 0;
    _snapshot.releaseTail();
    _snapshot.shrinkToFit();
    _afterSlotsChanged();
    if (designChanged) _rebuildMatrix();
    _rebuildActiveSet();
    _active = _activeCount > 0;
    _accumulator = 0;
    if (_reduceMotion) _snapAll();
  }

  /// Scans every slot once and records the ones not exactly at rest.
  void _rebuildActiveSet() {
    final int n = store.length;
    if (_isActive.length < n || _isActive.length > math.max(64, n * 4)) {
      int cap = 16;
      while (cap < n) {
        cap *= 2;
      }
      _isActive = Uint8List(cap);
      _activeList = Int32List(cap);
    } else {
      _isActive.fillRange(0, _isActive.length, 0);
    }
    _activeCount = 0;
    final Float32List l = store.layout, a = store.aux;
    for (int i = 0; i < n; i++) {
      final int b = MorphLayout.base(i), x = MorphAux.base(i);
      final bool atRest =
          a[x + MorphAux.delay] <= 0 &&
          l[b + MorphLayout.currentX] == l[b + MorphLayout.targetX] &&
          l[b + MorphLayout.currentY] == l[b + MorphLayout.targetY] &&
          l[b + MorphLayout.width] == a[x + MorphAux.targetW] &&
          l[b + MorphLayout.height] == a[x + MorphAux.targetH] &&
          a[x + MorphAux.presence] == a[x + MorphAux.presenceTarget] &&
          a[x + MorphAux.velX] == 0 &&
          a[x + MorphAux.velY] == 0 &&
          a[x + MorphAux.velW] == 0 &&
          a[x + MorphAux.velH] == 0 &&
          a[x + MorphAux.velPresence] == 0;
      if (!atRest) {
        _isActive[i] = 1;
        _activeList[_activeCount++] = i;
      }
    }
  }

  void _markActive(int slot) {
    if (_isActive[slot] == 1) return;
    _isActive[slot] = 1;
    _activeList[_activeCount++] = slot;
  }

  void _afterSlotsChanged() {
    generation++;
    final Map<Object, int> next = _slotByIdSpare..clear();
    final int n = store.length;
    for (int i = 0; i < n; i++) {
      next[store.ids[i]!] = i;
    }
    _slotByIdSpare = _slotById;
    _slotById = next;
    _rebuildDrawOrder();
    _rebuildContentBounds();
  }

  void _rebuildDrawOrder() {
    final int n = store.length;
    if (drawOrder.length < n) {
      int cap = drawOrder.length;
      while (cap < n) {
        cap *= 2;
      }
      drawOrder = Int32List(cap);
      drawRank = Int32List(cap);
    }
    final Float32List a = store.aux;
    bool uniform = true;
    final double z0 = n > 0 ? a[MorphAux.zIndex] : 0;
    for (int i = 0; i < n; i++) {
      drawOrder[i] = i;
      if (a[MorphAux.base(i) + MorphAux.zIndex] != z0) uniform = false;
    }
    if (!uniform) {
      final List<int> order = List<int>.generate(n, (int i) => i);
      order.sort((int p, int q) {
        final int c = a[MorphAux.base(p) + MorphAux.zIndex].compareTo(
          a[MorphAux.base(q) + MorphAux.zIndex],
        );
        return c != 0 ? c : p.compareTo(q);
      });
      for (int i = 0; i < n; i++) {
        drawOrder[i] = order[i];
      }
    }
    for (int i = 0; i < n; i++) {
      drawRank[drawOrder[i]] = i;
    }
  }

  void _rebuildContentBounds() {
    final int n = store.length;
    if (n == 0) {
      contentBounds = Offset.zero & designSize;
      return;
    }
    double minX = 0,
        minY = 0,
        maxX = designSize.width,
        maxY = designSize.height;
    final Float32List l = store.layout, a = store.aux;
    for (int i = 0; i < n; i++) {
      final int b = MorphLayout.base(i), x = MorphAux.base(i);
      final double r = a[x + MorphAux.rotation];
      final double w = a[x + MorphAux.targetW], h = a[x + MorphAux.targetH];
      // Unrotated nodes (the common case) skip the trigonometry.
      final double c = r == 0 ? 1 : math.cos(r).abs();
      final double s = r == 0 ? 0 : math.sin(r).abs();
      final double ex = (w * c + h * s) / 2, ey = (w * s + h * c) / 2;
      minX = math.min(minX, l[b + MorphLayout.targetX] - ex);
      maxX = math.max(maxX, l[b + MorphLayout.targetX] + ex);
      minY = math.min(minY, l[b + MorphLayout.targetY] - ey);
      maxY = math.max(maxY, l[b + MorphLayout.targetY] + ey);
    }
    contentBounds = Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  // ---------------------------------------------------------------- physics

  /// Advances every spring by [dt] seconds using fixed 1/240 s semi-implicit
  /// Euler sub-steps. Returns true while anything is still moving.
  bool step(double dt) {
    observer?.onStep(dt);
    if (!dt.isFinite || dt < 0) dt = 0;
    if (dt > maxFrameDt) dt = maxFrameDt;
    if (_reduceMotion) {
      _snapAll();
      return false;
    }
    if (!_active) return false;
    _accumulator += dt;
    while (_accumulator >= substep) {
      _integrate(substep);
      _accumulator -= substep;
    }
    _active = _settle();
    if (_needsCompaction) _compact();
    return _active;
  }

  void _integrate(double h) {
    final Float32List l = store.layout, a = store.aux;
    final Int32List active = _activeList;
    final int count = _activeCount;
    for (int ai = 0; ai < count; ai++) {
      final int i = active[ai];
      final int b = MorphLayout.base(i), x = MorphAux.base(i);
      double tx, ty, tw, th, tp;
      final double delay = a[x + MorphAux.delay];
      if (delay > 0) {
        a[x + MorphAux.delay] = delay - h;
        tx = a[x + MorphAux.prevTargetX];
        ty = a[x + MorphAux.prevTargetY];
        tw = a[x + MorphAux.prevTargetW];
        th = a[x + MorphAux.prevTargetH];
        tp = a[x + MorphAux.prevPresenceTarget];
      } else {
        tx = l[b + MorphLayout.targetX];
        ty = l[b + MorphLayout.targetY];
        tw = a[x + MorphAux.targetW];
        th = a[x + MorphAux.targetH];
        tp = a[x + MorphAux.presenceTarget];
      }
      final double k = l[b + MorphLayout.elasticity];
      final double invM = 1 / l[b + MorphLayout.mass];
      final double c = a[x + MorphAux.damping];

      if ((a[x + MorphAux.flags].toInt() & MorphAux.flagDragging) == 0) {
        double v = a[x + MorphAux.velX];
        double p = l[b + MorphLayout.currentX];
        v += (-k * (p - tx) - c * v) * invM * h;
        l[b + MorphLayout.currentX] = p + v * h;
        a[x + MorphAux.velX] = v;

        v = a[x + MorphAux.velY];
        p = l[b + MorphLayout.currentY];
        v += (-k * (p - ty) - c * v) * invM * h;
        l[b + MorphLayout.currentY] = p + v * h;
        a[x + MorphAux.velY] = v;
      }

      double v = a[x + MorphAux.velW];
      double p = l[b + MorphLayout.width];
      v += (-k * (p - tw) - c * v) * invM * h;
      l[b + MorphLayout.width] = p + v * h;
      a[x + MorphAux.velW] = v;

      v = a[x + MorphAux.velH];
      p = l[b + MorphLayout.height];
      v += (-k * (p - th) - c * v) * invM * h;
      l[b + MorphLayout.height] = p + v * h;
      a[x + MorphAux.velH] = v;

      v = a[x + MorphAux.velPresence];
      p = a[x + MorphAux.presence];
      v += (-k * (p - tp) - c * v) * invM * h;
      a[x + MorphAux.presence] = p + v * h;
      a[x + MorphAux.velPresence] = v;
    }
  }

  /// Snaps nodes that are within tolerance and reports whether any are still
  /// moving.
  bool _settle() {
    final Float32List l = store.layout, a = store.aux;
    final Int32List active = _activeList;
    final int count = _activeCount;
    int keep = 0;
    for (int k = 0; k < count; k++) {
      final int i = active[k];
      final int b = MorphLayout.base(i), x = MorphAux.base(i);
      if (a[x + MorphAux.delay] > 0) {
        active[keep++] = i;
        continue;
      }
      final bool dragging =
          (a[x + MorphAux.flags].toInt() & MorphAux.flagDragging) != 0;
      final double tx = l[b + MorphLayout.targetX],
          ty = l[b + MorphLayout.targetY];
      final double tw = a[x + MorphAux.targetW], th = a[x + MorphAux.targetH];
      final double tp = a[x + MorphAux.presenceTarget];
      // Float32 positions far from the origin move in coarse steps; the last
      // tiny spring moves round away and a node can stall a few steps short
      // of its target. Scale the tolerance to ~32 float steps at this
      // magnitude, and the velocity tolerance to the stall velocity it
      // implies, so such nodes still come to rest.
      final double posTol = math.max(
        restPosition,
        math.max(tx.abs(), ty.abs()) * 4e-6,
      );
      final double velTol = math.max(
        restVelocity,
        posTol *
            2 *
            math.sqrt(l[b + MorphLayout.elasticity] / l[b + MorphLayout.mass]),
      );
      final bool rest =
          (dragging ||
              ((l[b + MorphLayout.currentX] - tx).abs() < posTol &&
                  (l[b + MorphLayout.currentY] - ty).abs() < posTol &&
                  a[x + MorphAux.velX].abs() < velTol &&
                  a[x + MorphAux.velY].abs() < velTol)) &&
          (l[b + MorphLayout.width] - tw).abs() < restPosition &&
          (l[b + MorphLayout.height] - th).abs() < restPosition &&
          a[x + MorphAux.velW].abs() < restVelocity &&
          a[x + MorphAux.velH].abs() < restVelocity &&
          (a[x + MorphAux.presence] - tp).abs() < 0.001 &&
          a[x + MorphAux.velPresence].abs() < 0.01;
      if (!rest) {
        active[keep++] = i;
        continue;
      }
      _isActive[i] = 0;
      if (!dragging) {
        l[b + MorphLayout.currentX] = tx;
        l[b + MorphLayout.currentY] = ty;
        a[x + MorphAux.velX] = 0;
        a[x + MorphAux.velY] = 0;
      }
      l[b + MorphLayout.width] = tw;
      l[b + MorphLayout.height] = th;
      a[x + MorphAux.velW] = 0;
      a[x + MorphAux.velH] = 0;
      a[x + MorphAux.presence] = tp;
      a[x + MorphAux.velPresence] = 0;
      if (tp == 0) _needsCompaction = true;
    }
    _activeCount = keep;
    return keep > 0;
  }

  void _snapAll() {
    final Float32List l = store.layout, a = store.aux;
    final int n = store.length;
    for (int i = 0; i < n; i++) {
      final int b = MorphLayout.base(i), x = MorphAux.base(i);
      if ((a[x + MorphAux.flags].toInt() & MorphAux.flagDragging) == 0) {
        l[b + MorphLayout.currentX] = l[b + MorphLayout.targetX];
        l[b + MorphLayout.currentY] = l[b + MorphLayout.targetY];
      }
      l[b + MorphLayout.width] = a[x + MorphAux.targetW];
      l[b + MorphLayout.height] = a[x + MorphAux.targetH];
      a[x + MorphAux.presence] = a[x + MorphAux.presenceTarget];
      a[x + MorphAux.velX] = 0;
      a[x + MorphAux.velY] = 0;
      a[x + MorphAux.velW] = 0;
      a[x + MorphAux.velH] = 0;
      a[x + MorphAux.velPresence] = 0;
      a[x + MorphAux.delay] = 0;
      if (a[x + MorphAux.presenceTarget] == 0) _needsCompaction = true;
    }
    _active = false;
    for (int k = 0; k < _activeCount; k++) {
      _isActive[_activeList[k]] = 0;
    }
    _activeCount = 0;
    _accumulator = 0;
    if (_needsCompaction) _compact();
  }

  /// Drops exited nodes (presence reached 0) by shifting later slots down in
  /// place.
  void _compact() {
    _needsCompaction = false;
    final Float32List a = store.aux;
    final int n = store.length;
    int w = 0;
    for (int r = 0; r < n; r++) {
      final int x = MorphAux.base(r);
      final bool gone =
          a[x + MorphAux.presenceTarget] == 0 &&
          a[x + MorphAux.presence] <= 0.001;
      if (gone) continue;
      if (w != r) store.copySlotFrom(store, r, w);
      w++;
    }
    if (w == n) return;
    store.length = w;
    store.releaseTail();
    store.shrinkToFit();
    _afterSlotsChanged();
    _rebuildActiveSet();
  }

  // ------------------------------------------------------------------ drags

  /// Starts a drag on [id]: the node stops following its spring until
  /// [endDrag].
  void beginDrag(Object id) {
    observer?.onBeginDrag(id);
    final int? i = _slotById[id];
    if (i == null) return;
    store.setFlag(i, MorphAux.flagDragging, true);
    final int x = MorphAux.base(i);
    store.aux[x + MorphAux.velX] = 0;
    store.aux[x + MorphAux.velY] = 0;
  }

  /// Moves a dragged node by [delta] design units.
  void dragBy(Object id, Offset delta) {
    observer?.onDragBy(id, delta);
    final int? i = _slotById[id];
    if (i == null || !delta.isFinite) return;
    final int b = MorphLayout.base(i);
    store.layout[b + MorphLayout.currentX] += delta.dx;
    store.layout[b + MorphLayout.currentY] += delta.dy;
  }

  /// Releases a drag. [velocity] (design units/s) is handed to the spring so a
  /// flick glides before settling.
  void endDrag(Object id, Offset velocity) {
    observer?.onEndDrag(id, velocity);
    final int? i = _slotById[id];
    if (i == null) return;
    store.setFlag(i, MorphAux.flagDragging, false);
    final int x = MorphAux.base(i);
    store.aux[x + MorphAux.velX] = velocity.dx.isFinite ? velocity.dx : 0;
    store.aux[x + MorphAux.velY] = velocity.dy.isFinite ? velocity.dy : 0;
    _markActive(i);
    _active = true;
    if (_reduceMotion) _snapAll();
  }

  /// Bit-exact fingerprint of the physics state; see
  /// [MorphFieldStore.checksum].
  int checksum() => store.checksum();
}
