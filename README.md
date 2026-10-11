# morphos_ui

A flat, matrix-driven UI field for Flutter. Hundreds or thousands of nodes
(cards, tiles, chips, image thumbnails) live in **one** render object instead
of a widget tree. One affine matrix lays them out, a built-in spring solver
animates them, and they are painted with `Canvas.drawVertices`.

```dart
MorphOSField(
  spec: isGrid ? gridSpec : listSpec,          // swap the spec → everything springs
  onNodeTap: (id, index) => print('tapped $id'),
)
```

## What it does, and what it doesn't

| Can | Cannot (by design) |
|---|---|
| Lay out N nodes by anchor + offset in a design space, fitted to the box by one `Matrix4` (`contain`, `cover`, `fill`, `fitWidth`, `fitHeight`, `none`) | Host child widgets. A `TextField`, video or map has to be stacked on top of the field |
| Animate position, size, entry and exit on per-node springs, with no `AnimationController` | Beat a plain widget tree for small screens. With a few dozen nodes, use normal widgets |
| Draw rounded, bordered, rotated, anti-aliased nodes either with the renderer's fast rounded-rectangle path (`paintMode: MorphPaintMode.shapes`, the default) or as batched `drawVertices` meshes (`MorphPaintMode.vertices`, one call per 65,535 vertices, no per-node allocation) | Be allocation-free in every mode. `shapes` creates one small `RRect` per node per frame. `vertices` creates one native `ui.Vertices` handle per batch, disposed right away, over preallocated buffers |
| Texture nodes from one image atlas (per-vertex UVs) in the same call | Draw many strings from one `ui.Paragraph`; text uses one cached paragraph per node |
| Taps, drags with fling momentum, hover and cursor, vertical or horizontal scrolling, Tab / arrow / Enter keyboard focus, screen-reader labels and scrolling | Scroll both axes at once |
| Mirror layouts for right-to-left languages, and drive or query the field from code (`MorphController`) | Read app state for you: it takes a spec and works with any state management (setState, Provider, Riverpod, Bloc, GetX) |

## Install

```yaml
dependencies:
  morphos_ui: ^0.1.0
```

## Describe nodes

```dart
final spec = MorphFieldSpec.grid(
  width: 400,              // design units; the field scales to its box
  columns: 3,
  nodes: [
    for (var i = 0; i < 60; i++)
      MorphNodeSpec(
        id: i,             // stable id: how nodes are matched across specs
        size: Size.zero,   // grid() fills in size and position
        color: Colors.indigo,
        cornerRadius: 12,
        text: 'Card $i',
        maxLines: 2,
      ),
  ],
);
```

`MorphFieldSpec.list(...)` and `MorphFieldSpec.stack(...)` work the same way.
You can also place nodes by hand:

- `anchor` works like `Alignment` over the design size. `(0, 0)` puts the
  node's top-left at the origin and `(1, 1)` puts its bottom-right in the far
  corner.
- `position` is an extra offset in design units.

## Motion

Each node has its own spring:

- `elasticity`: stiffness, higher is snappier.
- `mass`: higher is heavier and slower.
- `dampingRatio`: 1 settles without bounce, below 1 bounces.

Supply a new spec and every node with the same `id` moves from wherever it is
now, keeping its velocity. New ids grow in and missing ids shrink out
(`animateEntryExit`).

Stagger the start times:

```dart
stagger: MorphStagger.fromPoint(tapCentre),   // ripple out from a point
stagger: MorphStagger.byIndex(Duration(milliseconds: 20)),
```

The solver integrates at a fixed 1/240 s step, so the result is identical at
60, 120 and 144 Hz. A long frame (jank, a breakpoint) is clamped to 1/30 s, so
nothing jumps. When the platform asks for reduced motion
(`MediaQuery.disableAnimations`), changes snap instead. A resting field
schedules no frames and does no repaints.

## Interaction

- `onNodeTap(id, index)`: also fires on Enter or Space while a node has
  keyboard focus.
- `onNodeHover(id)`: mouse hover. The mouse cursor switches to `nodeCursor`
  over interactive nodes.
- `draggable: true` nodes follow the pointer. On release they keep their fling
  velocity and spring back, unless your `onNodeDragEnd` supplies a new spec
  that moves them.
- `enableScroll: true` scrolls by drag, fling or mouse wheel, with a
  rubber-band edge. It's vertical by default (use `MorphFit.fitWidth`). Set
  `scrollDirection: Axis.horizontal` with `MorphFit.fitHeight` for a
  sideways strip.
- Keyboard: Tab and Shift-Tab move through nodes in reading order, and arrow
  keys move to the nearest node in that direction. Focus leaves the field at
  either end.
- Semantics: every node with `semanticLabel` or `text` becomes an
  accessibility node with its own rect and a tap action. Screen readers can
  also scroll the field a page at a time.
- Right-to-left: under an RTL `Directionality`, node positions and rotations
  mirror, and switching direction springs nodes across. Text and images are
  not flipped. Turn it off with `mirrorInRtl: false`.

## Controller

```dart
final controller = MorphController();

MorphOSField(
  spec: spec,
  enableScroll: true,
  controller: controller,
  onSettled: () => print('everything is at rest'),
);

await controller.scrollToNode(42, alignment: 0.5); // spring it to the middle
controller.jumpTo(0);
final rect = controller.nodeRect(42);              // where it rests on screen
final id = controller.nodeAt(localPosition);       // what is under a point
await controller.whenSettled();
```

`MorphController` is a plain `ChangeNotifier` (part of Flutter): listeners
hear about scroll changes and settling. Its only dependency is Flutter itself.
A user drag interrupts a running `animateTo` / `scrollToNode`, which then
completes.

## Images

```dart
MorphOSField(
  spec: spec,                                    // nodes use imageKey: 'hero'
  images: {'hero': AssetImage('assets/hero.png')},
)
```

Images are resolved and packed into one texture (up to 4096×4096), off the
frame loop. A node with `imageKey` samples its part of the texture, tinted by
`imageTint`. Images keep their proportions and crop to fill the node
(`imageFit: MorphImageFit.cover`, the default), so a square photo in a wide
card isn't stretched. `MorphImageFit.fill` stretches instead. Flat nodes sample a reserved white block, so both kinds share one
draw call. If an image fails to load it is reported to `onAtlasError`, and
that node falls back to its colour.

## Extras

| Flag | Effect |
|---|---|
| `showPerfOverlay` | Paint time, fps, node count and draw calls |
| `debugPaintNodeBounds` | Outlines every node's bounds |
| `effect: MorphEffect.sheen` | GPU light that follows the pointer, drawn as a second pass with a fragment shader. Experimental: if the shader cannot load, the field draws without it |
| `recorder: MorphRecorder()` | Records solver commands; `replay()` rebuilds the exact state, so animation tests can compare bit-exact checksums |

## How it works

| Module | Job |
|---|---|
| `morphos_spec.dart` | Immutable `MorphNodeSpec` / `MorphFieldSpec`, and the packed buffers. Each node gets a stride-12 layout slot `[anchorX, anchorY, posX, posY, elasticity, mass, currentX, currentY, targetX, targetY, width, height]`, addressed as `(i << 3) + (i << 2)`, plus a stride-24 aux slot for velocities, size and presence targets, visuals and stagger state |
| `morphos_solver.dart` | Builds the field matrix from the box size; matches specs to slots by id; runs the spring integrator; handles stagger, drags and reduced motion |
| `morphos_gestures.dart` | Maps pointer positions back into design space through the inverse matrix and tests them against the buffers (rotation and rounded corners included). Above 2,000 nodes it uses a uniform grid. Gesture recognizers join the normal arena |
| `morphos_mesh.dart` | Per-node geometry sized to the shape: 9 vertices for a square card, and up to 12 arc segments per rounded corner, chosen so each corner stays within a quarter pixel of a true arc on screen. Each node is a fill fan, an optional border band and a one-device-pixel alpha fringe (drawVertices has no anti-aliasing). Vertex counts and the index buffer are planned when the nodes or the zoom change, not every frame |
| `morphos_render_core.dart` | The `RenderBox`: layout, intrinsics, paint, semantics, keyboard focus, scrolling and the frame callback |
| `morphos_controller.dart` | `MorphController`: scroll to a node, jump, query rects and hits, wait for rest |
| `morphos_atlas.dart` | Paragraph cache and image atlas |

**Scaling.** Off-screen nodes are skipped in both paint modes, and screen
readers get only nodes within one viewport of the visible area. The solver
keeps an active set, so only moving nodes are integrated and checked each
frame. `spec.withNode(node)` / `spec.withNodes([...])` replace nodes by id
while sharing the rest, and applying the result rewrites only the changed
slots.

Paint order follows `zIndex`, with spec order breaking ties. In `shapes`
mode each node's text is drawn right after its shape, so layering is exact.
In `vertices` mode text is drawn after the meshes. The exception is a text
node that another, later node covers **at rest**: the batch is split there so
the later node covers the text. These splits are worked out once per spec
change, not every frame.

## Performance

`benchmark/` compares five ways of animating N cards between a grid and a
list (rounded corners, text up to 1,000 cards):

- **MorphOS-UI**, `shapes` mode (the default) and `vertices` mode.
- **A hand-written `CustomPainter`** with the same spring physics, cached
  `TextPainter`s and no widget rebuilds. This is the fastest thing you'd
  write by hand, with none of MorphOS-UI's features.
- **[Flame](https://pub.dev/packages/flame)**, one component per card,
  animated with Flame effects.
- **A widget tree:** `Stack` + `AnimatedPositioned` + `DecoratedBox` +
  `Text`.

Setup: macOS desktop (Apple M3 Pro), profile mode, Flutter 3.47.6. Each
contender does 4 morphs, each measured over a fixed 1.2 s window. The table
shows the median of 4 runs; runs where macOS throttled the window in the
background were discarded.

| UI-thread frame time, avg / p90 (ms) | 100 cards | 1,000 cards | 5,000 cards |
|---|---|---|---|
| **MorphOS-UI** (shapes) | **0.40** / 0.93 | 2.15 / 4.11 | **2.34** / 4.73 |
| Hand-written CustomPainter | 0.46 / 0.85 | **1.72** / 3.39 | 2.37 / **4.60** |
| MorphOS-UI (vertices) | 0.50 / 1.18 | 2.17 / 4.03 | 2.54 / 4.71 |
| Flame | 0.63 / 1.16 | 2.31 / 4.47 | 4.95 / 6.50 |
| Widget tree | 0.60 / 1.51 | 2.55 / 6.28 | 4.58 / 11.23 |

GPU raster time at 5,000 cards is about 0.36 ms for MorphOS-UI, the painter
and Flame alike. Frames over budget per run at 5,000 cards: 0–1 for
MorphOS-UI, the painter and Flame; 7–9 for the widget tree.

What this shows, and what it doesn't:

- MorphOS-UI is **level with a hand-written CustomPainter** at 5,000 cards
  and fastest at 100. At 1,000 cards the painter is about 20% faster. In
  return you get hit testing, keyboard focus, semantics, right-to-left
  support, scrolling, images and a controller, none of which the painter
  has.
- At 5,000 cards it is **about 2× faster than Flame and the widget tree**,
  and its p90 is less than half the widget tree's.
- The worst single frames in the table come from other processes on the
  test machine, not from MorphOS-UI. Timeline traces of the same 5,000-card
  morphs show both MorphOS-UI and the painter with no frame over 8 ms (worst
  4.9 ms vs 5.1 ms; median 1.83 vs 1.75 ms). Applying a 5,000-node spec costs
  about 1.3 ms in total.
- MorphOS-UI still triggers more garbage-collection pauses than the painter
  (107 vs 62 over 6 morphs), because each layout change builds a new
  5,000-node spec. That's the cost of describing layouts declaratively.
- `shapes` mode beats `vertices` mode on GPU time (0.36 vs 0.71 ms at 5,000
  cards). That's why it's the default. Use `vertices` if you specifically
  need the batched, allocation-free path.
- Averages include frames after an animation has finished. That slightly
  favours the widget tree and Flame, whose animations are shorter (700 ms).
- Only measured on macOS so far, not on phones.

### At scale: 20,000–100,000 cards

MorphOS-UI only draws what's on screen and only animates what's moving.
That's where it pulls ahead. Two scenarios, same setup as above, cards in a
scrolling 400-px-wide column:

- **One card changes** (moved with `spec.withNode(...)`, the way an app would
  edit one item)
- **All cards morph** between grid and list

| UI-thread avg (ms) | 20,000 | 50,000 | 100,000 |
|---|---|---|---|
| **MorphOS-UI**, one card changes | **0.27** | **0.62** | **0.95** |
| Hand-written CustomPainter, one card changes | 4.27 | 8.11 | 31.92 |
| Flame, one card changes | 10.82 | 26.32 | 52.83 |
| **MorphOS-UI**, all cards morph | **0.81** | **2.02** | **3.88** |
| Hand-written CustomPainter, all cards morph | 6.38 | 17.52 | 31.16 |
| Flame, all cards morph | 19.47 | 49.44 | 109.52 |
| Widget tree (built only up to 20,000) | one: 5.77 · morph: 12.16 | — | — |

At 100,000 cards MorphOS-UI holds full frame rate and drops 2–3 frames per
run, all on the layout-change frame (building and applying a 100,000-node
spec takes about 60 ms). The painter drops most of its frames, and Flame drops
all of them.

To be fair to the alternatives: a hand-written painter *could* skip
off-screen items and still items too. MorphOS-UI does both for you.

Run it yourself (profile mode, on a real device); see `benchmark/README.md`
for the timeline-trace and spec-cost runs:

```sh
cd benchmark
flutter drive --profile -d <device> \
  --driver=test_driver/perf_driver.dart \
  --target=integration_test/compare_test.dart
```

## Limits

- Leaf render object: no child widgets inside the field.
- One scroll axis at a time.
- Text is drawn per node through cached paragraphs. Fades use a `saveLayer`
  while a text node is partly transparent.
- `MorphEffect.sheen` depends on fragment-shader support for `drawVertices`
  on the active renderer.

## Links

- **Documentation and live demo:** [flutterdev.in/packages/morphos_ui](https://flutterdev.in/packages/morphos_ui/)
- **More Flutter packages:** [flutterdev.in](https://flutterdev.in)
- **Learn data structures & algorithms in Dart:** [Algoistan](https://algoistan.flutterdev.in)

## License

MIT
