import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphos_ui/morphos_ui.dart';

MorphOSRenderBridge bridgeOf(WidgetTester tester) =>
    tester.allRenderObjects.whereType<MorphOSRenderBridge>().single;

/// Three 20×20 nodes on a 100×100 design: a at (0,0), b at (40,0), c at (80,0).
MorphFieldSpec row({double shift = 0, bool withText = true}) => MorphFieldSpec(
  designSize: const Size(100, 100),
  nodes: <MorphNodeSpec>[
    for (final (int i, String id) in <(int, String)>[
      (0, 'a'),
      (1, 'b'),
      (2, 'c'),
    ])
      MorphNodeSpec(
        id: id,
        size: const Size(20, 20),
        position: Offset(i * 40.0, shift),
        text: withText ? id.toUpperCase() : null,
      ),
  ],
);

Widget host(
  Widget child, {
  double size = 400,
  bool disableAnimations = false,
}) => MediaQuery(
  data: MediaQueryData(disableAnimations: disableAnimations),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: size, height: size, child: child),
    ),
  ),
);

/// Global position of design point [design] for a field at the origin with a
/// 400px box over a 100-unit design (scale 4).
Offset at(Offset design) => design * 4;

void main() {
  setUp(MorphDebugStats.reset);

  testWidgets('lays out under tight, loose and unbounded constraints', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(MorphOSField(spec: row())));
    expect(bridgeOf(tester).size, const Size(400, 400));

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          child: SizedBox(width: 300, child: MorphOSField(spec: row())),
        ),
      ),
    );
    // Bounded on both axes (the screen bounds the height): the field fills it.
    expect(bridgeOf(tester).size, const Size(300, 600));

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 300, child: MorphOSField(spec: row())),
          ),
        ),
      ),
    );
    // Unbounded height: the design aspect ratio decides.
    expect(bridgeOf(tester).size, const Size(300, 300));

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          child: UnconstrainedBox(child: MorphOSField(spec: row())),
        ),
      ),
    );
    expect(bridgeOf(tester).size, const Size(100, 100));
    final MorphOSRenderBridge b = bridgeOf(tester);
    expect(b.getMaxIntrinsicHeight(250), 250);
    expect(b.getMinIntrinsicWidth(50), 50);
    expect(
      b.getDryLayout(const BoxConstraints(maxWidth: 80)),
      const Size(80, 80),
    );
  });

  testWidgets('tap reports the node under the pointer', (
    WidgetTester tester,
  ) async {
    final List<Object> taps = <Object>[];
    await tester.pumpWidget(
      host(
        MorphOSField(
          spec: row(),
          onNodeTap: (Object id, int index) => taps.add(id),
        ),
      ),
    );
    await tester.tapAt(at(const Offset(50, 10)));
    await tester.tapAt(at(const Offset(30, 10))); // gap between a and b
    await tester.tapAt(at(const Offset(5, 5)));
    expect(taps, <Object>['b', 'a']);
  });

  testWidgets('taps still fire when the pan recognizer is also listening', (
    WidgetTester tester,
  ) async {
    // Scrolling or a draggable node adds a pan recognizer; when the pointer
    // lifts without moving, the pan loses the arena and the tap must win.
    for (final (bool scroll, bool draggable) in <(bool, bool)>[
      (true, false),
      (false, true),
      (true, true),
    ]) {
      final List<Object> taps = <Object>[];
      await tester.pumpWidget(
        host(
          MorphOSField(
            fit: MorphFit.fitWidth,
            enableScroll: scroll,
            onNodeTap: (Object id, int index) => taps.add(id),
            spec: MorphFieldSpec(
              designSize: const Size(100, 300),
              nodes: <MorphNodeSpec>[
                MorphNodeSpec(
                  id: 'n',
                  size: const Size(40, 40),
                  draggable: draggable,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tapAt(at(const Offset(20, 20)));
      await tester.pump();
      expect(taps, <Object>[
        'n',
      ], reason: 'scroll=$scroll draggable=$draggable');
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('draws every node in one drawVertices call', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(MorphOSField(spec: row(), paintMode: MorphPaintMode.vertices)),
    );
    expect(bridgeOf(tester).perf.drawCalls, 1);
    expect(bridgeOf(tester).perf.nodes, 3);
  });

  testWidgets('shapes mode: one draw per node, text right after its node', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(MorphOSField(spec: row())));
    final MorphOSRenderBridge b = bridgeOf(tester);
    expect(b.paintMode, MorphPaintMode.shapes);
    expect(b.perf.drawCalls, 3);
    expect(MorphDebugStats.liveVertices, 0);
    // A bordered node is a ring plus a fill (fresh field: no exiting nodes).
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      host(
        MorphOSField(
          spec: MorphFieldSpec(
            designSize: const Size(100, 100),
            nodes: const <MorphNodeSpec>[
              MorphNodeSpec(id: 1, size: Size(20, 20), borderWidth: 2),
            ],
          ),
        ),
      ),
    );
    expect(bridgeOf(tester).perf.drawCalls, 2);
  });

  testWidgets('text under a later node splits the draw so z-order holds', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        MorphOSField(
          paintMode: MorphPaintMode.vertices,
          spec: MorphFieldSpec(
            designSize: const Size(100, 100),
            nodes: const <MorphNodeSpec>[
              MorphNodeSpec(id: 'under', size: Size(40, 40), text: 'hidden'),
              MorphNodeSpec(
                id: 'over',
                size: Size(30, 30),
                position: Offset(10, 10),
              ),
            ],
          ),
        ),
      ),
    );
    expect(bridgeOf(tester).perf.drawCalls, 2);
  });

  testWidgets('animates on spec change, then stops scheduling frames', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(MorphOSField(spec: row())));
    final MorphOSRenderBridge b = bridgeOf(tester);
    expect(b.debugHasScheduledFrame, isFalse);

    await tester.pumpWidget(host(MorphOSField(spec: row(shift: 50))));
    expect(b.debugHasScheduledFrame, isTrue);
    await tester.pump(); // first animation frame has dt = 0
    await tester.pump(const Duration(milliseconds: 100));
    final double mid = b.solver.store.currentCenter(0).dy;
    expect(mid, greaterThan(10));
    expect(mid, lessThan(70));

    await tester.pumpAndSettle();
    expect(b.solver.store.currentCenter(0), const Offset(10, 60));
    expect(b.debugHasScheduledFrame, isFalse);
    final int paints = b.debugPaintCount;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(
      b.debugPaintCount,
      paints,
      reason: 'a resting field must not repaint',
    );
  });

  testWidgets('hot path reuses its buffers across 1000 frames', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(MorphOSField(spec: row(), paintMode: MorphPaintMode.vertices)),
    );
    final MorphOSRenderBridge b = bridgeOf(tester);
    final Float32List layout = b.solver.store.layout;
    final Float32List positions = b.mesh.positions;
    final Int32List colors = b.mesh.colors;
    for (int i = 0; i < 1000; i++) {
      if (i % 100 == 0) {
        await tester.pumpWidget(
          host(
            MorphOSField(
              spec: row(shift: (i ~/ 100).isEven ? 40 : 0),
              paintMode: MorphPaintMode.vertices,
            ),
          ),
        );
      }
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(identical(b.solver.store.layout, layout), isTrue);
    expect(identical(b.mesh.positions, positions), isTrue);
    expect(identical(b.mesh.colors, colors), isTrue);
    expect(MorphDebugStats.liveVertices, 0);
  });

  testWidgets('releases paragraphs, vertices and shaders on unmount', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(MorphOSField(spec: row(), showPerfOverlay: true)),
    );
    expect(MorphDebugStats.liveParagraphs, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    expect(MorphDebugStats.liveParagraphs, 0);
    expect(MorphDebugStats.liveVertices, 0);
    expect(MorphDebugStats.liveShaders, 0);
    expect(MorphDebugStats.liveAtlases, 0);
  });

  testWidgets('Tab, arrows and Enter drive node focus', (
    WidgetTester tester,
  ) async {
    final List<Object> taps = <Object>[];
    // A WidgetsApp supplies the default Tab traversal shortcuts.
    await tester.pumpWidget(
      MaterialApp(
        home: host(
          MorphOSField(
            spec: row(),
            onNodeTap: (Object id, int index) => taps.add(id),
          ),
        ),
      ),
    );
    final MorphOSRenderBridge b = bridgeOf(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(b.focusedId, 'a');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(b.focusedId, 'b');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    expect(b.focusedId, 'c');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(taps, <Object>['c']);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(b.focusedId, 'b');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(taps, <Object>['c', 'b']);
  });

  testWidgets('mouse hover reports nodes and uses the node cursor', (
    WidgetTester tester,
  ) async {
    final List<Object?> hovers = <Object?>[];
    await tester.pumpWidget(
      host(MorphOSField(spec: row(), onNodeHover: hovers.add)),
    );
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: at(const Offset(50, 90)));
    await mouse.moveTo(at(const Offset(50, 10)));
    await tester.pump();
    expect(hovers, <Object?>['b']);
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
    );
    await mouse.moveTo(at(const Offset(90, 10)));
    await mouse.moveTo(at(const Offset(50, 90)));
    await tester.pump();
    expect(hovers, <Object?>['b', 'c', null]);
    await mouse.removePointer();
  });

  testWidgets('nodes with text or labels are exposed to semantics', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(MorphOSField(spec: row(), onNodeTap: (Object id, int i) {})),
    );
    final List<SemanticsNode> nodes = <SemanticsNode>[];
    bridgeOf(tester).debugSemantics!.visitChildren((SemanticsNode n) {
      nodes.add(n);
      return true;
    });
    // Children are visited in inverse paint order.
    expect(nodes.map((SemanticsNode n) => n.label), <String>['C', 'B', 'A']);
    final SemanticsNode node = nodes[1];
    expect(node.rect, const Rect.fromLTWH(160, 0, 80, 80));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    handle.dispose();
  });

  testWidgets('dragging a node then flicking it hands momentum to the spring', (
    WidgetTester tester,
  ) async {
    Offset? releaseVelocity;
    await tester.pumpWidget(
      host(
        MorphOSField(
          spec: MorphFieldSpec(
            designSize: const Size(100, 100),
            nodes: const <MorphNodeSpec>[
              MorphNodeSpec(id: 'd', size: Size(20, 20), draggable: true),
            ],
          ),
          onNodeDragEnd: (Object id, Offset c, Offset v) => releaseVelocity = v,
        ),
      ),
    );
    final MorphOSRenderBridge b = bridgeOf(tester);
    await tester.flingFrom(
      at(const Offset(10, 10)),
      const Offset(160, 0),
      1500,
    );
    expect(releaseVelocity, isNotNull);
    expect(releaseVelocity!.dx, greaterThan(100));
    await tester.pump(const Duration(milliseconds: 16));
    expect(b.solver.isActive, isTrue);
    await tester.pumpAndSettle();
    expect(b.solver.store.currentCenter(0), const Offset(10, 10));
  });

  testWidgets('scrolls tall content and settles within bounds', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        MorphOSField(
          fit: MorphFit.fitWidth,
          enableScroll: true,
          spec: MorphFieldSpec.list(
            width: 100,
            itemHeight: 20,
            nodes: <MorphNodeSpec>[
              for (int i = 0; i < 30; i++)
                MorphNodeSpec(id: i, size: Size.zero),
            ],
          ),
        ),
      ),
    );
    final MorphOSRenderBridge b = bridgeOf(tester);
    expect(b.solver.maxScrollOffset, greaterThan(1000));
    await tester.flingFrom(const Offset(200, 300), const Offset(0, -200), 2000);
    await tester.pumpAndSettle();
    expect(b.solver.scrollOffset, greaterThan(200));
    expect(b.solver.scrollOffset, lessThanOrEqualTo(b.solver.maxScrollOffset));
    await tester.flingFrom(const Offset(200, 100), const Offset(0, 300), 4000);
    await tester.pumpAndSettle();
    expect(b.solver.scrollOffset, 0);
  });

  testWidgets('reduced motion snaps with no animation frames', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(MorphOSField(spec: row()), disableAnimations: true),
    );
    await tester.pumpWidget(
      host(MorphOSField(spec: row(shift: 50)), disableAnimations: true),
    );
    final MorphOSRenderBridge b = bridgeOf(tester);
    expect(b.solver.store.currentCenter(0), const Offset(10, 60));
    expect(b.debugHasScheduledFrame, isFalse);
  });

  testWidgets('dark brightness uses darkColor', (WidgetTester tester) async {
    final MorphFieldSpec spec = MorphFieldSpec(
      designSize: const Size(10, 10),
      nodes: const <MorphNodeSpec>[
        MorphNodeSpec(
          id: 1,
          size: Size(5, 5),
          color: Color(0xFFFFFFFF),
          darkColor: Color(0xFF000000),
        ),
      ],
    );
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(platformBrightness: Brightness.dark),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MorphOSField(spec: spec),
        ),
      ),
    );
    expect(
      bridgeOf(tester).solver.store.fillColors[0] & 0xFFFFFFFF,
      0xFF000000,
    );
  });

  testWidgets('sheen effect adds one overlay pass, or falls back cleanly', (
    WidgetTester tester,
  ) async {
    // Load on the real clock first: the widget reuses this cached load, and a
    // load started inside the test's fake clock could never time out.
    final ui.FragmentProgram? program = await tester
        .runAsync<ui.FragmentProgram?>(MorphShaderLibrary.sheen);
    await tester.pumpWidget(
      host(
        MorphOSField(
          spec: row(withText: false),
          effect: MorphEffect.sheen,
          paintMode: MorphPaintMode.vertices,
        ),
      ),
    );
    // The cached load completed on the real clock, so its callback runs
    // there; let it, then build.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    final MorphOSRenderBridge b = bridgeOf(tester);
    if (program == null) {
      expect(b.perf.drawCalls, 1);
    } else {
      expect(b.sheenProgram, isNotNull);
      expect(b.perf.drawCalls, 2);
      expect(MorphDebugStats.liveShaders, 1);
    }
    await tester.pumpWidget(const SizedBox());
    expect(MorphDebugStats.liveShaders, 0);
  });

  testWidgets('images are packed into an atlas and textured nodes use it', (
    WidgetTester tester,
  ) async {
    final Uint8List png = (await tester.runAsync(() async {
      final ui.PictureRecorder r = ui.PictureRecorder();
      Canvas(r).drawRect(
        const Rect.fromLTWH(0, 0, 8, 8),
        Paint()..color = const Color(0xFFFF0000),
      );
      final ui.Picture p = r.endRecording();
      final ui.Image img = await p.toImage(8, 8);
      p.dispose();
      final ByteData? data = await img.toByteData(
        format: ui.ImageByteFormat.png,
      );
      img.dispose();
      return data!.buffer.asUint8List();
    }))!;
    await tester.pumpWidget(
      host(
        MorphOSField(
          spec: MorphFieldSpec(
            designSize: const Size(100, 100),
            nodes: const <MorphNodeSpec>[
              MorphNodeSpec(id: 'img', size: Size(50, 50), imageKey: 'red'),
              MorphNodeSpec(
                id: 'plain',
                size: Size(20, 20),
                position: Offset(60, 0),
              ),
            ],
          ),
          images: <String, ImageProvider>{'red': MemoryImage(png)},
          paintMode: MorphPaintMode.vertices,
        ),
      ),
    );
    final MorphOSRenderBridge b = bridgeOf(tester);
    for (int i = 0; i < 20 && b.atlas == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(b.atlas, isNotNull);
    expect(b.solver.store.aux[MorphAux.base(0) + MorphAux.atlasSlot], 0);
    expect(b.solver.store.aux[MorphAux.base(1) + MorphAux.atlasSlot], -1);
    expect(b.perf.drawCalls, 1);
    await tester.pumpWidget(const SizedBox());
    expect(MorphDebugStats.liveAtlases, 0);
  });

  testWidgets('recorder replays a live field exactly', (
    WidgetTester tester,
  ) async {
    final MorphRecorder rec = MorphRecorder();
    await tester.pumpWidget(host(MorphOSField(spec: row(), recorder: rec)));
    await tester.pumpWidget(
      host(
        MorphOSField(
          spec: row(shift: 30),
          recorder: rec,
          stagger: const MorphStagger.byIndex(Duration(milliseconds: 40)),
        ),
      ),
    );
    for (int i = 0; i < 25; i++) {
      await tester.pump(Duration(milliseconds: 7 + i % 5));
    }
    expect(rec.replay().checksum(), bridgeOf(tester).solver.checksum());
  });
}
