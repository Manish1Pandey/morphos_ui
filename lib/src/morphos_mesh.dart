// Geometry for the render bridge: turns node slots into triangle meshes in
// pre-allocated vertex, colour and UV buffers.
//
// Each node gets only the vertices its shape needs. A node is a centre
// vertex plus rings that trace its outline, each ring having R points:
//
//   centre      fill colour
//   ring A      fill edge (inside the border), fill colour
//   ring B, C   only with a border: B repeats A in border colour, C is the
//               outer edge in border colour
//   ring D      anti-aliasing fringe one device pixel outside the outer
//               edge, alpha 0 (drawVertices does not anti-alias)
//
// R is 4 for square corners, or 4 * (segments + 1) for rounded ones, where
// segments is picked from the corner radius in device pixels so the polygon
// stays within a quarter pixel of the true arc (1 to 12 per corner). A plain
// square card is 9 vertices; a large circle with a border is up to 209.
//
// The vertex counts, offsets and the index buffer form a "plan" that is
// rebuilt only when the nodes, their paint order or the on-screen scale
// change — never on an ordinary animation frame. Per-node state lives in
// private fields rather than closures, so writing a node allocates nothing.

import 'dart:math' as math;
import 'dart:typed_data';

import 'morphos_atlas.dart';
import 'morphos_solver.dart';
import 'morphos_spec.dart';

/// Pre-allocated vertex buffers and the current geometry plan.
final class MorphMesh {
  /// Creates buffers for [initialNodes] nodes.
  MorphMesh([int initialNodes = 16]) {
    _ensureNodes(math.max(1, initialNodes));
    _ensureVerts(64);
    _ensureIndices(256);
  }

  /// Most arc segments used per rounded corner.
  static const int maxCornerSegments = 12;

  /// Largest vertex count addressable by one 16-bit index batch.
  static const int maxBatchVertices = 65535;

  static final List<Float32List> _cos = <Float32List>[
    for (int s = 0; s <= maxCornerSegments; s++) _unitTable(s, true),
  ];
  static final List<Float32List> _sin = <Float32List>[
    for (int s = 0; s <= maxCornerSegments; s++) _unitTable(s, false),
  ];
  static final List<Int8List> _signX = <Int8List>[
    for (int s = 0; s <= maxCornerSegments; s++) _signTable(s, true),
  ];
  static final List<Int8List> _signY = <Int8List>[
    for (int s = 0; s <= maxCornerSegments; s++) _signTable(s, false),
  ];

  /// Interleaved x/y local pixel positions.
  Float32List positions = Float32List(0);

  /// Interleaved u/v texel coordinates (used only with an atlas).
  Float32List texCoords = Float32List(0);

  /// Vertex colours (ARGB).
  Int32List colors = Int32List(0);

  /// Vertex colours for the effect overlay pass (white, node alpha).
  Int32List overlayColors = Int32List(0);

  /// Triangle indices, relative to the first vertex of each batch.
  Uint16List indices = Uint16List(0);

  /// Local axis-aligned bounds per mesh node `[l, t, r, b]`.
  Float32List bounds = Float32List(0);

  /// First vertex of each paint position (length nodes + 1).
  Int32List vertStart = Int32List(0);

  /// First index of each paint position (length nodes + 1).
  Int32List indexStart = Int32List(0);

  /// Arc segments per corner for each paint position (0 = square).
  Uint8List segments = Uint8List(0);

  /// Whether each paint position has a border ring pair.
  Uint8List bordered = Uint8List(0);

  /// First paint position of each batch, then the node count.
  Int32List batchStart = Int32List(0);

  /// Number of batches in the plan.
  int batchCount = 0;

  /// Nodes in the plan.
  int planNodes = 0;

  int _planGeneration = -1;
  double _planScale = -1;

  /// Total vertices in the plan.
  int get vertexCount => planNodes == 0 ? 0 : vertStart[planNodes];

  /// Total indices in the plan.
  int get indexCount => planNodes == 0 ? 0 : indexStart[planNodes];

  /// Node capacity of the per-node arrays.
  int get capacity => segments.length;

  void _ensureNodes(int n) {
    if (segments.length >= n) return;
    final int cap = _grow(segments.length, n);
    bounds = Float32List(cap * 4);
    vertStart = Int32List(cap + 1);
    indexStart = Int32List(cap + 1);
    segments = Uint8List(cap);
    bordered = Uint8List(cap);
    batchStart = Int32List(cap + 1);
  }

  void _ensureVerts(int v) {
    if (colors.length >= v) return;
    final int cap = _grow(colors.length, v);
    positions = Float32List(cap * 2);
    texCoords = Float32List(cap * 2);
    colors = Int32List(cap);
    overlayColors = Int32List(cap);
  }

  void _ensureIndices(int i) {
    if (indices.length >= i) return;
    indices = Uint16List(_grow(indices.length, i));
  }

  static int _grow(int current, int needed) {
    int cap = math.max(16, current);
    while (cap < needed) {
      cap *= 2;
    }
    return cap;
  }

  /// Points per ring for [segments] arc segments per corner.
  @pragma('vm:prefer-inline')
  static int ringPoints(int segments) => 4 * (segments + 1);

  /// Vertices for a node with [segments] per corner and optional border.
  static int verticesFor(int segments, bool border) =>
      1 + ringPoints(segments) * (border ? 4 : 2);

  /// Indices for a node with [segments] per corner and optional border.
  static int indicesFor(int segments, bool border) =>
      ringPoints(segments) * (border ? 5 : 3) * 3;

  /// Segments needed so a corner of [radiusPx] device pixels deviates from
  /// the true arc by at most a quarter pixel.
  static int segmentsForRadius(double radiusPx) {
    if (!(radiusPx > 0)) return 0;
    if (radiusPx <= 0.25) return 1;
    final double step = math.acos(1 - 0.25 / radiusPx);
    final int s = (math.pi / 2 / (2 * step)).ceil();
    return s.clamp(1, maxCornerSegments);
  }

  static Float32List _unitTable(int s, bool cosine) {
    final int r = ringPoints(s);
    final Float32List t = Float32List(r);
    for (int k = 0; k < 4; k++) {
      for (int i = 0; i <= s; i++) {
        final double angle = s == 0
            ? -math.pi / 4 + k * math.pi / 2
            : -math.pi / 2 + k * math.pi / 2 + i * (math.pi / 2) / s;
        t[k * (s + 1) + i] = cosine ? math.cos(angle) : math.sin(angle);
      }
    }
    return t;
  }

  // Corner order: top-right, bottom-right, bottom-left, top-left.
  static Int8List _signTable(int s, bool x) {
    const List<int> sx = <int>[1, 1, -1, -1];
    const List<int> sy = <int>[-1, 1, 1, -1];
    final Int8List t = Int8List(ringPoints(s));
    for (int k = 0; k < 4; k++) {
      for (int i = 0; i <= s; i++) {
        t[k * (s + 1) + i] = x ? sx[k] : sy[k];
      }
    }
    return t;
  }

  /// Rebuilds the plan if the nodes, their order or [devicePixelsPerUnit]
  /// changed since the last call. Returns true when it rebuilt.
  bool ensurePlan(MorphFieldSolver solver, double devicePixelsPerUnit) {
    final int n = solver.store.length;
    if (_planGeneration == solver.generation &&
        _planScale == devicePixelsPerUnit &&
        planNodes == n) {
      return false;
    }
    _planGeneration = solver.generation;
    _planScale = devicePixelsPerUnit;
    planNodes = n;
    _ensureNodes(n);
    final Float32List a = solver.store.aux;
    final Int32List order = solver.drawOrder;
    int verts = 0, idx = 0, batchVerts = 0;
    batchCount = 0;
    for (int q = 0; q < n; q++) {
      final int x = MorphAux.base(order[q]);
      final double hw = a[x + MorphAux.targetW] / 2;
      final double hh = a[x + MorphAux.targetH] / 2;
      final double r = math.min(a[x + MorphAux.cornerRadius], math.min(hw, hh));
      final int seg = segmentsForRadius(r * devicePixelsPerUnit);
      final bool border = a[x + MorphAux.borderWidth] > 0;
      final int nv = verticesFor(seg, border);
      if (q == 0 || batchVerts + nv > maxBatchVertices) {
        batchStart[batchCount++] = q;
        batchVerts = 0;
      }
      segments[q] = seg;
      bordered[q] = border ? 1 : 0;
      vertStart[q] = verts;
      indexStart[q] = idx;
      verts += nv;
      idx += indicesFor(seg, border);
      batchVerts += nv;
    }
    vertStart[n] = verts;
    indexStart[n] = idx;
    batchStart[batchCount] = n;
    _ensureVerts(verts);
    _ensureIndices(idx);
    for (int b = 0; b < batchCount; b++) {
      final int base0 = vertStart[batchStart[b]];
      for (int q = batchStart[b]; q < batchStart[b + 1]; q++) {
        _writeIndices(q, vertStart[q] - base0);
      }
    }
    return true;
  }

  void _writeIndices(int q, int v0) {
    final int r = ringPoints(segments[q]);
    final bool border = bordered[q] == 1;
    final int a = v0 + 1;
    final int outer = border ? v0 + 1 + 2 * r : a;
    final int d = v0 + 1 + (border ? 3 : 1) * r;
    int o = indexStart[q];
    final Uint16List out = indices;
    for (int i = 0; i < r; i++) {
      final int j = i + 1 == r ? 0 : i + 1;
      out[o++] = v0;
      out[o++] = a + i;
      out[o++] = a + j;
    }
    if (border) {
      final int b = v0 + 1 + r;
      for (int i = 0; i < r; i++) {
        final int j = i + 1 == r ? 0 : i + 1;
        out[o++] = b + i;
        out[o++] = outer + i;
        out[o++] = outer + j;
        out[o++] = b + i;
        out[o++] = outer + j;
        out[o++] = b + j;
      }
    }
    for (int i = 0; i < r; i++) {
      final int j = i + 1 == r ? 0 : i + 1;
      out[o++] = outer + i;
      out[o++] = d + i;
      out[o++] = d + j;
      out[o++] = outer + i;
      out[o++] = d + j;
      out[o++] = outer + j;
    }
  }

  @pragma('vm:prefer-inline')
  static int _withAlpha(int argb, double alpha) {
    final int a = (((argb >> 24) & 0xff) * alpha).round().clamp(0, 255);
    return (a << 24) | (argb & 0x00ffffff);
  }

  // Per-node scratch state (set by writeNode, read by _put/_ring).
  double _cx = 0, _cy = 0, _hw = 0, _hh = 0, _r = 0, _rc = 1, _rs = 0;
  double _m0 = 1, _m1 = 0, _m4 = 0, _m5 = 1, _m12 = 0, _m13 = 0;
  double _u0 = 0, _v0 = 0, _u1 = 0, _v1 = 0;
  double _minX = 0, _minY = 0, _maxX = 0, _maxY = 0;
  int _vBase = 0, _seg = 0;
  bool _uv = false, _overlay = false;

  void _put(
    int vi,
    double lx,
    double ly,
    int color,
    bool texturedVertex,
    int overlayColor,
  ) {
    final double dx = lx * _rc - ly * _rs + _cx;
    final double dy = lx * _rs + ly * _rc + _cy;
    final double px = _m0 * dx + _m4 * dy + _m12;
    final double py = _m1 * dx + _m5 * dy + _m13;
    final int v = _vBase + vi;
    final int o = v * 2;
    positions[o] = px;
    positions[o + 1] = py;
    if (px < _minX) _minX = px;
    if (px > _maxX) _maxX = px;
    if (py < _minY) _minY = py;
    if (py > _maxY) _maxY = py;
    colors[v] = color;
    if (_overlay) overlayColors[v] = overlayColor;
    if (_uv) {
      if (texturedVertex && _hw > 0 && _hh > 0) {
        final double fx = (lx / (2 * _hw) + 0.5).clamp(0.0, 1.0);
        final double fy = (ly / (2 * _hh) + 0.5).clamp(0.0, 1.0);
        texCoords[o] = _u0 + (_u1 - _u0) * fx;
        texCoords[o + 1] = _v0 + (_v1 - _v0) * fy;
      } else {
        texCoords[o] = MorphImageAtlas.whiteU;
        texCoords[o + 1] = MorphImageAtlas.whiteV;
      }
    }
  }

  /// Writes one ring displaced [offset] from the outer edge (negative is
  /// inward).
  void _ring(
    int start,
    double offset,
    int color,
    bool textured,
    int overlayColor,
  ) {
    final int s = _seg;
    final int points = ringPoints(s);
    final Int8List sx = _signX[s], sy = _signY[s];
    if (s == 0) {
      final double ex = math.max(0, _hw + offset),
          ey = math.max(0, _hh + offset);
      for (int i = 0; i < points; i++) {
        _put(start + i, sx[i] * ex, sy[i] * ey, color, textured, overlayColor);
      }
      return;
    }
    final Float32List cs = _cos[s], sn = _sin[s];
    double rr = _r + offset;
    double ccx = _hw - _r, ccy = _hh - _r;
    if (rr < 0) {
      ccx = _hw + offset;
      ccy = _hh + offset;
      rr = 0;
    }
    if (ccx < 0) ccx = 0;
    if (ccy < 0) ccy = 0;
    for (int i = 0; i < points; i++) {
      _put(
        start + i,
        sx[i] * ccx + rr * cs[i],
        sy[i] * ccy + rr * sn[i],
        color,
        textured,
        overlayColor,
      );
    }
  }

  /// Narrows the image's texel rectangle to the node's on-screen aspect ratio
  /// (centred), so the image keeps its proportions: `BoxFit.cover`.
  void _cropToCover() {
    final double nodeW = _hw * _m0.abs(), nodeH = _hh * _m5.abs();
    final double texW = _u1 - _u0, texH = _v1 - _v0;
    if (nodeW <= 0 || nodeH <= 0 || texW <= 0 || texH <= 0) return;
    final double nodeAspect = nodeW / nodeH, texAspect = texW / texH;
    if (nodeAspect > texAspect) {
      final double h = texW / nodeAspect, cy = (_v0 + _v1) / 2;
      _v0 = cy - h / 2;
      _v1 = cy + h / 2;
    } else {
      final double w = texH * nodeAspect, cx = (_u0 + _u1) / 2;
      _u0 = cx - w / 2;
      _u1 = cx + w / 2;
    }
  }

  /// Writes the mesh for store slot [slot] at paint position [q] of the
  /// current plan.
  ///
  /// [aaDesign] is one device pixel in design units. With [atlas] non-null,
  /// UVs are written (the white block for untextured parts). With [overlay]
  /// true, overlay colours are written for the effect pass.
  void writeNode(
    int q,
    int slot,
    MorphFieldSolver solver, {
    required double aaDesign,
    MorphImageAtlas? atlas,
    bool overlay = false,
  }) {
    final MorphFieldStore s = solver.store;
    final Float32List l = s.layout, a = s.aux;
    final int b = MorphLayout.base(slot), x = MorphAux.base(slot);
    _cx = l[b + MorphLayout.currentX];
    _cy = l[b + MorphLayout.currentY];
    _hw = math.max(0, l[b + MorphLayout.width]) / 2;
    _hh = math.max(0, l[b + MorphLayout.height]) / 2;
    final double p = math.max(0, a[x + MorphAux.presence]);
    final double alpha = (a[x + MorphAux.opacity] * p).clamp(0.0, 1.0);
    _r = math.min(a[x + MorphAux.cornerRadius], math.min(_hw, _hh));
    final bool border = bordered[q] == 1;
    final double bw = border
        ? math.min(a[x + MorphAux.borderWidth], math.min(_hw, _hh))
        : 0;
    _seg = segments[q];
    final double rot = a[x + MorphAux.rotation];
    if (rot == 0) {
      _rc = p;
      _rs = 0;
    } else {
      _rc = math.cos(rot) * p;
      _rs = math.sin(rot) * p;
    }
    final List<double> m = solver.matrix.storage;
    _m0 = m[0];
    _m1 = m[1];
    _m4 = m[4];
    _m5 = m[5];
    _m12 = m[12];
    _m13 = m[13];

    final int atlasSlot = atlas == null
        ? -1
        : a[x + MorphAux.atlasSlot].toInt();
    final bool textured = atlasSlot >= 0;
    _uv = atlas != null;
    _overlay = overlay;
    if (textured) {
      final Float32List rr = atlas!.rects;
      _u0 = rr[atlasSlot * 4];
      _v0 = rr[atlasSlot * 4 + 1];
      _u1 = rr[atlasSlot * 4 + 2];
      _v1 = rr[atlasSlot * 4 + 3];
      if (s.specs[slot]?.imageFit != MorphImageFit.fill) _cropToCover();
    }

    final int fill = _withAlpha(
      textured ? s.tintColors[slot] : s.fillColors[slot],
      alpha,
    );
    final int edge = border ? _withAlpha(s.borderColors[slot], alpha) : fill;
    final int ov = ((alpha * 255).round().clamp(0, 255) << 24) | 0x00ffffff;
    final int r = ringPoints(_seg);

    _vBase = vertStart[q];
    _minX = _minY = double.infinity;
    _maxX = _maxY = double.negativeInfinity;

    _put(0, 0, 0, fill, textured, ov);
    _ring(1, -bw, fill, textured, ov);
    if (border) {
      _ring(1 + r, -bw, edge, false, ov);
      _ring(1 + 2 * r, 0, edge, false, ov);
      _ring(1 + 3 * r, aaDesign, edge & 0x00ffffff, false, ov & 0x00ffffff);
    } else {
      _ring(1 + r, aaDesign, edge & 0x00ffffff, textured, ov & 0x00ffffff);
    }

    final int bo = q * 4;
    bounds[bo] = _minX;
    bounds[bo + 1] = _minY;
    bounds[bo + 2] = _maxX;
    bounds[bo + 3] = _maxY;
  }

  /// Makes paint position [q] invisible without computing its geometry
  /// (used for nodes outside the viewport).
  void hideNode(int q, {bool overlay = false}) {
    final int v0 = vertStart[q], v1 = vertStart[q + 1];
    colors.fillRange(v0, v1, 0);
    if (overlay) overlayColors.fillRange(v0, v1, 0);
    final int bo = q * 4;
    bounds[bo] = bounds[bo + 1] = bounds[bo + 2] = bounds[bo + 3] = 0;
  }

  /// Releases large buffers when the plan has shrunk to under a quarter of
  /// their size (called after spec changes, never per frame).
  void shrinkToFit() {
    if (planNodes * 4 < segments.length && segments.length > 64) {
      final int keep = _grow(16, planNodes);
      bounds = Float32List(keep * 4)..setRange(0, planNodes * 4, bounds);
      vertStart = Int32List(keep + 1)..setRange(0, planNodes + 1, vertStart);
      indexStart = Int32List(keep + 1)..setRange(0, planNodes + 1, indexStart);
      segments = Uint8List(keep)..setRange(0, planNodes, segments);
      bordered = Uint8List(keep)..setRange(0, planNodes, bordered);
      batchStart = Int32List(keep + 1)..setRange(0, batchCount + 1, batchStart);
    }
    final int v = vertexCount;
    if (v * 4 < colors.length && colors.length > 1024) {
      final int keep = _grow(16, v);
      positions = Float32List(keep * 2);
      texCoords = Float32List(keep * 2);
      colors = Int32List(keep);
      overlayColors = Int32List(keep);
    }
    final int i = indexCount;
    if (i * 4 < indices.length && indices.length > 4096) {
      indices = Uint16List(_grow(16, i))..setRange(0, i, indices);
    }
  }
}
