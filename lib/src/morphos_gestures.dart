// Module 3: the low-level gesture and interaction router.
//
// Pointer positions are mapped back into design space with the inverse field
// matrix and tested directly against the node buffers (rotation, presence
// scale and rounded corners included). No per-node render objects exist.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'morphos_solver.dart';
import 'morphos_spec.dart';

/// A uniform grid over axis-aligned boxes, stored as compressed rows
/// (counts → offsets → items) in reusable typed lists.
final class MorphUniformGrid {
  /// Creates an empty grid.
  MorphUniformGrid();

  Int32List _offsets = Int32List(2);
  Int32List _items = Int32List(16);
  Int32List _cursor = Int32List(1);

  /// Grid bounds.
  double minX = 0, minY = 0, maxX = 0, maxY = 0;

  /// Cells per row and per column.
  int cols = 0, rows = 0;
  double _cellW = 1, _cellH = 1;

  /// Whether the grid holds data.
  bool valid = false;

  /// Builds the grid from [count] boxes stored as `[l, t, r, b]` quadruples
  /// in [boxes]. Lists grow only when a larger build is requested.
  void build(Float32List boxes, int count) {
    valid = false;
    if (count == 0) return;
    minX = minY = double.infinity;
    maxX = maxY = double.negativeInfinity;
    for (int i = 0; i < count; i++) {
      final int o = i * 4;
      minX = math.min(minX, boxes[o]);
      minY = math.min(minY, boxes[o + 1]);
      maxX = math.max(maxX, boxes[o + 2]);
      maxY = math.max(maxY, boxes[o + 3]);
    }
    if (!(maxX > minX) || !(maxY > minY)) return;
    final int side = math.max(1, math.min(256, math.sqrt(count / 2).ceil()));
    cols = rows = side;
    _cellW = (maxX - minX) / cols;
    _cellH = (maxY - minY) / rows;
    final int cells = cols * rows;
    if (_offsets.length < cells + 1) _offsets = Int32List(cells + 1);
    if (_cursor.length < cells) _cursor = Int32List(cells);
    _offsets.fillRange(0, cells + 1, 0);
    int total = 0;
    for (int i = 0; i < count; i++) {
      final int o = i * 4;
      final int c0 = _col(boxes[o]), c1 = _col(boxes[o + 2]);
      final int r0 = _row(boxes[o + 1]), r1 = _row(boxes[o + 3]);
      for (int r = r0; r <= r1; r++) {
        for (int c = c0; c <= c1; c++) {
          _offsets[r * cols + c + 1]++;
          total++;
        }
      }
    }
    for (int c = 0; c < cells; c++) {
      _offsets[c + 1] += _offsets[c];
      _cursor[c] = _offsets[c];
    }
    if (_items.length < total) _items = Int32List(total);
    for (int i = 0; i < count; i++) {
      final int o = i * 4;
      final int c0 = _col(boxes[o]), c1 = _col(boxes[o + 2]);
      final int r0 = _row(boxes[o + 1]), r1 = _row(boxes[o + 3]);
      for (int r = r0; r <= r1; r++) {
        for (int c = c0; c <= c1; c++) {
          _items[_cursor[r * cols + c]++] = i;
        }
      }
    }
    valid = true;
  }

  int _col(double x) => ((x - minX) / _cellW).floor().clamp(0, cols - 1);
  int _row(double y) => ((y - minY) / _cellH).floor().clamp(0, rows - 1);

  /// Calls [visit] with every box index registered in the cell containing
  /// `(x, y)`. Returns false if the point is outside the grid.
  bool visitPoint(double x, double y, void Function(int index) visit) {
    if (!valid || x < minX || x > maxX || y < minY || y > maxY) return false;
    final int cell = _row(y) * cols + _col(x);
    for (int k = _offsets[cell]; k < _offsets[cell + 1]; k++) {
      visit(_items[k]);
    }
    return true;
  }

  /// Calls [visit] with every box index registered in any cell overlapping the
  /// rectangle. A box spanning several cells can be visited more than once.
  void visitRect(
    double l,
    double t,
    double r,
    double b,
    void Function(int index) visit,
  ) {
    if (!valid || r < minX || l > maxX || b < minY || t > maxY) return;
    final int c0 = _col(l), c1 = _col(r), r0 = _row(t), r1 = _row(b);
    for (int row = r0; row <= r1; row++) {
      for (int col = c0; col <= c1; col++) {
        final int cell = row * cols + col;
        for (int k = _offsets[cell]; k < _offsets[cell + 1]; k++) {
          visit(_items[k]);
        }
      }
    }
  }
}

/// Finds which node a point falls on.
///
/// Scans nodes top-most first. Above [gridThreshold] nodes, and only while the
/// field is at rest, a [MorphUniformGrid] built from resting positions
/// answers the query instead of the linear scan.
final class MorphHitTester {
  /// Creates a hit tester reading [solver]'s buffers.
  MorphHitTester(this.solver);

  /// Node count above which the spatial grid is used.
  static int gridThreshold = 2000;

  /// The solver whose buffers are tested.
  final MorphFieldSolver solver;

  final MorphUniformGrid _grid = MorphUniformGrid();
  Float32List _boxes = Float32List(64);
  int _gridGeneration = -1;
  bool _gridDirty = true;

  int _best = -1;
  int _bestRank = -1;
  double _qx = 0, _qy = 0;

  /// Marks the grid stale (call whenever nodes move).
  void invalidate() => _gridDirty = true;

  /// Whether the last query used the grid (for tests and diagnostics).
  bool lastQueryUsedGrid = false;

  /// Returns the slot under local pixel [local], or -1.
  int hitTestLocal(Offset local) {
    final Offset? d = solver.localToDesign(local);
    if (d == null) return -1;
    return hitTestDesign(d.dx, d.dy);
  }

  /// Returns the slot under design-space point `(x, y)`, or -1.
  int hitTestDesign(double x, double y) {
    lastQueryUsedGrid = false;
    final int n = solver.store.length;
    if (n == 0 || !x.isFinite || !y.isFinite) return -1;
    if (n > gridThreshold && !solver.isActive) {
      _ensureGrid();
      if (_grid.valid) {
        lastQueryUsedGrid = true;
        _best = -1;
        _bestRank = -1;
        _qx = x;
        _qy = y;
        _grid.visitPoint(x, y, _visit);
        return _best;
      }
    }
    return hitTestLinear(x, y);
  }

  /// Reference linear scan, top-most first.
  int hitTestLinear(double x, double y) {
    final Int32List order = solver.drawOrder;
    for (int q = solver.store.length - 1; q >= 0; q--) {
      final int slot = order[q];
      if (contains(slot, x, y)) return slot;
    }
    return -1;
  }

  void _visit(int slot) {
    final int rank = solver.drawRank[slot];
    if (rank > _bestRank && contains(slot, _qx, _qy)) {
      _best = slot;
      _bestRank = rank;
    }
  }

  void _ensureGrid() {
    if (!_gridDirty && _gridGeneration == solver.generation) return;
    final MorphFieldStore s = solver.store;
    final int n = s.length;
    if (_boxes.length < n * 4) _boxes = Float32List(n * 4);
    for (int i = 0; i < n; i++) {
      final int b = MorphLayout.base(i), x = MorphAux.base(i);
      final double r = s.aux[x + MorphAux.rotation];
      final double p = math.max(0, s.aux[x + MorphAux.presence]);
      final double w = s.layout[b + MorphLayout.width] * p;
      final double h = s.layout[b + MorphLayout.height] * p;
      final double c = r == 0 ? 1 : math.cos(r).abs();
      final double sn = r == 0 ? 0 : math.sin(r).abs();
      final double ex = (w * c + h * sn) / 2, ey = (w * sn + h * c) / 2;
      final double cx = s.layout[b + MorphLayout.currentX];
      final double cy = s.layout[b + MorphLayout.currentY];
      _boxes[i * 4] = cx - ex;
      _boxes[i * 4 + 1] = cy - ey;
      _boxes[i * 4 + 2] = cx + ex;
      _boxes[i * 4 + 3] = cy + ey;
    }
    _grid.build(_boxes, n);
    _gridGeneration = solver.generation;
    _gridDirty = false;
  }

  /// Whether design point `(x, y)` lies inside slot [slot]'s rounded,
  /// rotated, presence-scaled rectangle. Exiting and non-interactive nodes
  /// never hit.
  bool contains(int slot, double x, double y) {
    final MorphFieldStore s = solver.store;
    final int b = MorphLayout.base(slot), a = MorphAux.base(slot);
    final Float32List aux = s.aux;
    if ((aux[a + MorphAux.flags].toInt() & MorphAux.flagInteractive) == 0) {
      return false;
    }
    if (aux[a + MorphAux.presenceTarget] == 0) return false;
    final double p = aux[a + MorphAux.presence];
    if (p < 0.05) return false;
    double dx = x - s.layout[b + MorphLayout.currentX];
    double dy = y - s.layout[b + MorphLayout.currentY];
    final double rot = aux[a + MorphAux.rotation];
    if (rot != 0) {
      final double c = math.cos(rot), sn = math.sin(rot);
      final double rx = dx * c + dy * sn;
      final double ry = -dx * sn + dy * c;
      dx = rx;
      dy = ry;
    }
    dx = dx.abs() / p;
    dy = dy.abs() / p;
    final double hw = s.layout[b + MorphLayout.width] / 2;
    final double hh = s.layout[b + MorphLayout.height] / 2;
    if (dx > hw || dy > hh) return false;
    final double r = math.min(aux[a + MorphAux.cornerRadius], math.min(hw, hh));
    if (r <= 0) return true;
    final double qx = dx - (hw - r), qy = dy - (hh - r);
    if (qx <= 0 || qy <= 0) return true;
    return qx * qx + qy * qy <= r * r;
  }
}

/// What a render object must provide to [MorphGestureRouter].
abstract interface class MorphGestureHost {
  /// Solver whose nodes are hit.
  MorphFieldSolver get solver;

  /// Hit tester for local positions.
  MorphHitTester get hitTester;

  /// Whether empty-space drags and the mouse wheel scroll the field.
  bool get scrollEnabled;

  /// Axis that scrolling moves along.
  Axis get scrollAxis;

  /// Whether a node tap handler is installed.
  bool get hasTapHandler;

  /// A node was tapped.
  void handleNodeTap(int slot);

  /// The hovered node changed (-1 for none).
  void handleHover(int slot);

  /// A node drag moved; the node is already repositioned.
  void handleNodeDragUpdate(Object id);

  /// A node drag ended; [designVelocity] is in design units per second.
  void handleNodeDragEnd(Object id, Offset designVelocity);

  /// Scrolls by [delta] local pixels (positive moves content up).
  void scrollBy(double delta);

  /// Starts a scroll drag.
  void beginScrollDrag();

  /// Ends a scroll drag with [velocity] local pixels per second.
  void endScrollDrag(double velocity);

  /// Records the latest pointer position (local pixels), for effects.
  void notePointer(Offset local);

  /// Requests a repaint.
  void requestPaint();
}

/// Routes raw pointer events through real gesture recognizers so the field
/// takes part in the gesture arena (and cooperates with parent scrollables).
final class MorphGestureRouter {
  /// Creates a router for [host].
  MorphGestureRouter(this.host) {
    _tap = TapGestureRecognizer(debugOwner: this)
      ..onTapUp = _onTapUp
      ..onTapCancel = _onTapCancel;
    _pan = PanGestureRecognizer(debugOwner: this)
      ..onStart = _onPanStart
      ..onUpdate = _onPanUpdate
      ..onEnd = _onPanEnd
      ..onCancel = _onPanCancel;
  }

  /// The render object being driven.
  final MorphGestureHost host;

  /// Whether released drags hand their velocity to the spring.
  bool inheritFlingVelocity = true;

  late final TapGestureRecognizer _tap;
  late final PanGestureRecognizer _pan;

  int _pressedSlot = -1;
  int _pressedGeneration = -1;
  Object? _dragId;
  bool _scrollDrag = false;
  int _hoverSlot = -1;

  /// Id of the node currently being dragged, if any.
  Object? get draggingId => _dragId;

  /// Currently hovered slot, or -1.
  int get hoverSlot => _hoverSlot;

  /// Entry point from `RenderBox.handleEvent`. [event] is already in local
  /// coordinates.
  void handleEvent(PointerEvent event) {
    host.notePointer(event.localPosition);
    if (event is PointerDownEvent) {
      _pressedSlot = host.hitTester.hitTestLocal(event.localPosition);
      _pressedGeneration = host.solver.generation;
      if (_pressedSlot >= 0 && host.hasTapHandler) _tap.addPointer(event);
      final bool draggable =
          _pressedSlot >= 0 &&
          host.solver.store.hasFlag(_pressedSlot, MorphAux.flagDraggable);
      if (draggable || host.scrollEnabled) _pan.addPointer(event);
    } else if (event is PointerPanZoomStartEvent) {
      if (host.scrollEnabled) _pan.addPointerPanZoom(event);
    } else if (event is PointerHoverEvent) {
      updateHover(host.hitTester.hitTestLocal(event.localPosition));
    } else if (event is PointerScrollEvent) {
      if (host.scrollEnabled) {
        GestureBinding.instance.pointerSignalResolver.register(event, (
          PointerSignalEvent e,
        ) {
          final Offset d = (e as PointerScrollEvent).scrollDelta;
          // A plain mouse wheel only reports dy; let it drive horizontal
          // fields too.
          host.scrollBy(
            host.scrollAxis == Axis.vertical ? d.dy : (d.dx != 0 ? d.dx : d.dy),
          );
        });
      }
    }
  }

  /// Sets the hovered slot and notifies the host when it changes.
  void updateHover(int slot) {
    if (slot == _hoverSlot) return;
    _hoverSlot = slot;
    host.handleHover(slot);
  }

  int _liveSlot() {
    if (_pressedSlot < 0) return -1;
    if (_pressedGeneration == host.solver.generation) return _pressedSlot;
    return -1;
  }

  void _onTapUp(TapUpDetails details) {
    final int slot = _liveSlot();
    if (slot >= 0) host.handleNodeTap(slot);
    _pressedSlot = -1;
  }

  void _onTapCancel() {}

  void _onPanStart(DragStartDetails details) {
    final int slot = _liveSlot();
    if (slot >= 0 && host.solver.store.hasFlag(slot, MorphAux.flagDraggable)) {
      final Object id = host.solver.store.ids[slot]!;
      _dragId = id;
      host.solver.beginDrag(id);
      host.requestPaint();
    } else if (host.scrollEnabled) {
      _scrollDrag = true;
      host.beginScrollDrag();
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final Object? id = _dragId;
    if (id != null) {
      final double sx = host.solver.scaleX, sy = host.solver.scaleY;
      if (sx == 0 || sy == 0) return;
      host.solver.dragBy(
        id,
        Offset(details.delta.dx / sx, details.delta.dy / sy),
      );
      host.hitTester.invalidate();
      host.handleNodeDragUpdate(id);
      host.requestPaint();
    } else if (_scrollDrag) {
      host.scrollBy(
        host.scrollAxis == Axis.vertical
            ? -details.delta.dy
            : -details.delta.dx,
      );
    }
  }

  void _onPanEnd(DragEndDetails details) {
    final Object? id = _dragId;
    final Offset v = details.velocity.pixelsPerSecond;
    if (id != null) {
      final double sx = host.solver.scaleX, sy = host.solver.scaleY;
      final Offset dv = inheritFlingVelocity && sx != 0 && sy != 0
          ? Offset(v.dx / sx, v.dy / sy)
          : Offset.zero;
      host.solver.endDrag(id, dv);
      host.handleNodeDragEnd(id, dv);
      _dragId = null;
    } else if (_scrollDrag) {
      final double along = host.scrollAxis == Axis.vertical ? v.dy : v.dx;
      host.endScrollDrag(inheritFlingVelocity ? -along : 0);
      _scrollDrag = false;
    }
    _pressedSlot = -1;
  }

  // The pan recognizer also cancels when it merely loses the arena to a tap
  // (pointer lifted without moving). In that case no drag started and the
  // tap still needs _pressedSlot, so only clean up what a drag set.
  void _onPanCancel() {
    final Object? id = _dragId;
    if (id != null) {
      host.solver.endDrag(id, Offset.zero);
      host.handleNodeDragEnd(id, Offset.zero);
      _dragId = null;
      _pressedSlot = -1;
    }
    if (_scrollDrag) {
      host.endScrollDrag(0);
      _scrollDrag = false;
      _pressedSlot = -1;
    }
  }

  /// Releases the recognizers.
  void dispose() {
    _tap.dispose();
    _pan.dispose();
  }
}

/// Hit-testing and pointer/mouse plumbing for a field render object.
///
/// `hitTestSelf` answers from the node buffers instead of child render
/// objects, and `handleEvent` forwards to a [MorphGestureRouter]. The mixin
/// also makes the render object a [MouseTrackerAnnotation], so hover and the
/// mouse cursor follow individual nodes.
mixin MorphHitTestMixin on RenderBox implements MouseTrackerAnnotation {
  /// Router receiving this render object's pointer events.
  MorphGestureRouter get gestureRouter;

  /// Hit tester used by [hitTestSelf].
  MorphHitTester get morphHitTester;

  /// Whether the whole box (not just nodes) should be hit, e.g. for scrolling.
  bool get hitTestWholeBox;

  /// Cursor shown over interactive nodes.
  MouseCursor get nodeCursor;

  int _lastHitSlot = -1;

  /// Slot found by the most recent [hitTestSelf], or -1.
  int get lastHitSlot => _lastHitSlot;

  @override
  bool hitTestSelf(Offset position) {
    _lastHitSlot = morphHitTester.hitTestLocal(position);
    return _lastHitSlot >= 0 || hitTestWholeBox;
  }

  @override
  void handleEvent(PointerEvent event, covariant BoxHitTestEntry entry) {
    assert(debugHandleEvent(event, entry));
    gestureRouter.handleEvent(event);
  }

  @override
  MouseCursor get cursor => _lastHitSlot >= 0 ? nodeCursor : MouseCursor.defer;

  @override
  PointerEnterEventListener? get onEnter => null;

  @override
  PointerExitEventListener? get onExit => _handleExit;

  void _handleExit(PointerExitEvent event) {
    _lastHitSlot = -1;
    gestureRouter.updateHover(-1);
  }

  @override
  bool get validForMouseTracker => attached;
}
