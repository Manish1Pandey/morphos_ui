## 0.1.0

First release.

- `MorphOSField` widget and `MorphOSRenderBridge` render object: a whole field
  of nodes in one leaf `RenderBox`.
- Stride-12 packed layout buffer plus a stride-24 auxiliary buffer; buffers
  grow only on spec changes.
- One field matrix per layout (`contain`, `cover`, `fill`, `fitWidth`, `none`).
- Fixed-step (1/240 s) semi-implicit spring solver: position, size and
  presence; nodes matched by id across spec changes; animated entry and exit;
  stagger by index or from a point; reduced-motion snapping.
- Two paint modes: `shapes` (default; one `drawRRect` per node, text layered
  exactly) and `vertices`: rounded, bordered, rotated, anti-aliased nodes drawn with
  `Canvas.drawVertices`. Geometry is sized to each shape: 9 vertices for a
  square card, and just enough arc segments for rounded corners to stay
  within a quarter pixel. One call per 65,535 vertices, split only when text
  must sit under a later node at rest.
- Image atlas with per-vertex UVs so textured and flat nodes share a draw.
  Images keep their proportions (`imageFit: MorphImageFit.cover`, the
  default) or stretch (`MorphImageFit.fill`).
- Cached paragraphs for node text with max lines, ellipsis and clipping.
- Hit testing through the inverse matrix (rotation, rounded corners), with a
  uniform grid above 2,000 nodes.
- Taps, drags with fling momentum, mouse hover and cursor, wheel and drag
  scrolling, keyboard focus (Tab, arrows, Enter/Space), semantics.
- `MorphController` (a plain `ChangeNotifier`): `scrollToNode`, `animateTo`,
  `jumpTo`, `nodeRect`, `nodeAt`, `whenSettled`; plus an `onSettled` callback.
- Vertical or horizontal scrolling (`scrollDirection`, `MorphFit.fitHeight`),
  with screen-reader scroll actions.
- Right-to-left mirroring of node positions and rotations (`mirrorInRtl`).
- Node, vertex and index buffers shrink after a large field becomes small.
- Scaling: viewport culling in both paint modes, an active set in the solver
  (only moving nodes are integrated), `MorphFieldSpec.withNode` /
  `withNodes` for cheap single-node edits, and semantics limited to nodes near
  the viewport. Measured up to 100,000 nodes.
- `benchmark/` app (not published): five-way comparison with a hand-written
  CustomPainter, Flame and a widget tree, a 20k–100k scaling run, plus
  timeline-trace and spec-cost runs.
- Optional sheen fragment-shader overlay, performance overlay, node-bounds
  debug overlay, and a recorder for bit-exact replay.
