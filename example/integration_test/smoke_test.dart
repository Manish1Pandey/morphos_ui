// On-device smoke test: runs the real engine (Impeller on iOS/Android,
// the desktop renderer on Linux/macOS/Windows) and checks behaviour and
// actual pixels, not just Dart-side logic.
//
//   flutter test integration_test/smoke_test.dart -d <device>

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:morphos_ui/morphos_ui.dart';
import 'package:morphos_ui_example/main.dart';

MorphOSRenderBridge bridgeOf(WidgetTester t) =>
    t.allRenderObjects.whereType<MorphOSRenderBridge>().single;

/// Captures what the field itself painted (its own repaint-boundary layer).
Future<(ByteData, int)> capture(MorphOSRenderBridge b) async {
  final OffsetLayer layer = b.debugLayer! as OffsetLayer;
  final ui.Image img = await layer.toImage(Offset.zero & b.size);
  final ByteData data = (await img.toByteData())!;
  final int w = img.width;
  img.dispose();
  return (data, w);
}

/// RGBA at local logical point [p] (pixel ratio 1 capture).
List<int> pixel((ByteData, int) shot, Offset p) {
  final (ByteData d, int w) = shot;
  final int o = (p.dy.floor() * w + p.dx.floor()) * 4;
  return <int>[
    d.getUint8(o),
    d.getUint8(o + 1),
    d.getUint8(o + 2),
    d.getUint8(o + 3),
  ];
}

void expectColor(List<int> rgba, int r, int g, int b, {String? reason}) {
  for (int i = 0; i < 3; i++) {
    expect(
      (rgba[i] - <int>[r, g, b][i]).abs(),
      lessThanOrEqualTo(6),
      reason: '${reason ?? ''} got $rgba want ($r,$g,$b)',
    );
  }
  expect(rgba[3], greaterThan(245), reason: '${reason ?? ''} alpha $rgba');
}

Widget host(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 300, height: 300, child: child),
    ),
  ),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final MorphPaintMode mode in MorphPaintMode.values) {
    testWidgets(
      'pixels (${mode.name}): fills, rounded corners, rotation, borders, z-order',
      (t) async {
        await t.pumpWidget(
          host(
            MorphOSField(
              paintMode: mode,
              spec: MorphFieldSpec(
                designSize: const Size(300, 300),
                nodes: const <MorphNodeSpec>[
                  MorphNodeSpec(
                    id: 'red',
                    size: Size(100, 100),
                    color: Color(0xFFFF0000),
                  ),
                  MorphNodeSpec(
                    id: 'circle',
                    size: Size(100, 100),
                    position: Offset(150, 0),
                    color: Color(0xFF00FF00),
                    cornerRadius: 50,
                    borderWidth: 10,
                    borderColor: Color(0xFF0000FF),
                  ),
                  MorphNodeSpec(
                    id: 'diamond',
                    size: Size(80, 80),
                    position: Offset(110, 170),
                    color: Color(0xFF0000FF),
                    rotation: 0.785398,
                  ),
                  MorphNodeSpec(
                    id: 'over',
                    size: Size(40, 40),
                    position: Offset(80, 80),
                    color: Color(0xFFFFFF00),
                    zIndex: 5,
                  ),
                ],
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        final MorphOSRenderBridge b = bridgeOf(t);
        // vertices: one batched call; shapes: one per node plus the border ring.
        expect(b.perf.drawCalls, mode == MorphPaintMode.vertices ? 1 : 5);
        final (ByteData, int) shot = await capture(b);
        expectColor(
          pixel(shot, const Offset(50, 50)),
          255,
          0,
          0,
          reason: 'red fill',
        );
        expectColor(
          pixel(shot, const Offset(200, 50)),
          0,
          255,
          0,
          reason: 'circle fill',
        );
        expectColor(
          pixel(shot, const Offset(200, 3)),
          0,
          0,
          255,
          reason: 'circle border',
        );
        expect(
          pixel(shot, const Offset(154, 4))[3],
          lessThan(40),
          reason: 'circle corner is cut',
        );
        expectColor(
          pixel(shot, const Offset(150, 175)),
          0,
          0,
          255,
          reason: 'diamond top tip',
        );
        expect(
          pixel(shot, const Offset(113, 173))[3],
          lessThan(40),
          reason: 'rotated corner is empty',
        );
        expectColor(
          pixel(shot, const Offset(95, 95)),
          255,
          255,
          0,
          reason: 'zIndex draws on top',
        );
        expect(
          pixel(shot, const Offset(280, 280))[3],
          0,
          reason: 'background untouched',
        );
      },
    );

    testWidgets('pixels (${mode.name}): images cover wide nodes, not stretch', (
      t,
    ) async {
      // 16x16 image: red centre square (4..12), blue border.
      final Uint8List png = (await t.runAsync(() async {
        final ui.PictureRecorder r = ui.PictureRecorder();
        final Canvas c = Canvas(r);
        c.drawRect(
          const Rect.fromLTWH(0, 0, 16, 16),
          Paint()..color = const Color(0xFF0000FF),
        );
        c.drawRect(
          const Rect.fromLTWH(4, 4, 8, 8),
          Paint()..color = const Color(0xFFFF0000),
        );
        final ui.Picture p = r.endRecording();
        final ui.Image img = await p.toImage(16, 16);
        p.dispose();
        final ByteData? d = await img.toByteData(
          format: ui.ImageByteFormat.png,
        );
        img.dispose();
        return d!.buffer.asUint8List();
      }))!;
      await t.pumpWidget(
        host(
          MorphOSField(
            paintMode: mode,
            images: <String, ImageProvider>{'target': MemoryImage(png)},
            spec: MorphFieldSpec(
              designSize: const Size(300, 300),
              nodes: const <MorphNodeSpec>[
                MorphNodeSpec(
                  id: 'wide',
                  size: Size(240, 60),
                  imageKey: 'target',
                ),
              ],
            ),
          ),
        ),
      );
      final MorphOSRenderBridge b = bridgeOf(t);
      for (int i = 0; i < 100 && b.atlas == null; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      await t.pumpAndSettle();
      final (ByteData, int) shot = await capture(b);
      // Cover keeps the image square: a 4:1 band through its middle, which is
      // red even near the node's top edge. Stretching would show blue there.
      expectColor(
        pixel(shot, const Offset(120, 6)),
        255,
        0,
        0,
        reason: 'cover, not stretch',
      );
      expectColor(
        pixel(shot, const Offset(6, 30)),
        0,
        0,
        255,
        reason: 'blue border at the sides',
      );
    });

    testWidgets('pixels (${mode.name}): atlas texture and text', (t) async {
      final Uint8List png = (await t.runAsync(() async {
        final ui.PictureRecorder r = ui.PictureRecorder();
        Canvas(r).drawRect(
          const Rect.fromLTWH(0, 0, 16, 16),
          Paint()..color = const Color(0xFFFF00FF),
        );
        final ui.Picture p = r.endRecording();
        final ui.Image img = await p.toImage(16, 16);
        p.dispose();
        final ByteData? d = await img.toByteData(
          format: ui.ImageByteFormat.png,
        );
        img.dispose();
        return d!.buffer.asUint8List();
      }))!;
      await t.pumpWidget(
        host(
          MorphOSField(
            paintMode: mode,
            images: <String, ImageProvider>{'magenta': MemoryImage(png)},
            spec: MorphFieldSpec(
              designSize: const Size(300, 300),
              nodes: const <MorphNodeSpec>[
                MorphNodeSpec(
                  id: 'tex',
                  size: Size(120, 120),
                  imageKey: 'magenta',
                ),
                MorphNodeSpec(
                  id: 'text',
                  size: Size(140, 60),
                  position: Offset(150, 0),
                  color: Color(0xFF000000),
                  text: 'MorphOS',
                  textStyle: TextStyle(fontSize: 28, color: Color(0xFFFFFFFF)),
                ),
              ],
            ),
          ),
        ),
      );
      final MorphOSRenderBridge b = bridgeOf(t);
      for (int i = 0; i < 100 && b.atlas == null; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      expect(b.atlas, isNotNull, reason: 'image atlas built on device');
      await t.pumpAndSettle();
      final (ByteData, int) shot = await capture(b);
      expectColor(
        pixel(shot, const Offset(60, 60)),
        255,
        0,
        255,
        reason: 'textured node',
      );
      int white = 0;
      for (int y = 10; y < 50; y++) {
        for (int x = 160; x < 280; x++) {
          if (pixel(shot, Offset(x.toDouble(), y.toDouble()))[0] > 200) white++;
        }
      }
      expect(
        white,
        greaterThan(100),
        reason: 'text glyphs drawn over the black node',
      );
    });

    testWidgets('sheen (${mode.name}): shader loads and draws an extra pass', (
      t,
    ) async {
      await t.pumpWidget(
        host(
          MorphOSField(
            paintMode: mode,
            effect: MorphEffect.sheen,
            spec: MorphFieldSpec(
              designSize: const Size(300, 300),
              nodes: const <MorphNodeSpec>[
                MorphNodeSpec(
                  id: 1,
                  size: Size(300, 300),
                  color: Color(0xFF202020),
                ),
              ],
            ),
          ),
        ),
      );
      final ui.FragmentProgram? program = await MorphShaderLibrary.sheen();
      await t.pump();
      final MorphOSRenderBridge b = bridgeOf(t);
      debugPrint(
        'MORPH_SMOKE platform=${defaultTargetPlatform.name} sheenLoaded=${program != null}',
      );
      expect(
        program,
        isNotNull,
        reason: 'fragment shader compiles on this platform',
      );
      expect(b.perf.drawCalls, 2);
      final (ByteData, int) shot = await capture(b);
      final List<int> lit = pixel(shot, const Offset(150, 100));
      expect(
        lit[0],
        greaterThan(0x20),
        reason: 'sheen brightened the node: $lit',
      );
    });
  }

  testWidgets('demo app: tap, morph to list, settle, flick, scroll', (t) async {
    await t.pumpWidget(const MorphDemoApp());
    await t.pumpAndSettle();
    final MorphOSRenderBridge b = bridgeOf(t);
    expect(b.solver.store.length, 24);

    final Rect r0 = b.nodeRect(0)!;
    final Offset origin = t.getTopLeft(find.byType(MorphOSField));
    await t.tapAt(origin + r0.center);
    await t.pumpAndSettle();
    expect(find.text('Tapped card 0'), findsOneWidget);
    // nodeRect is the axis-aligned box around the (now slightly rotated)
    // card, so compare the card's own size instead.
    expect(
      b.solver.store.currentSize(b.solver.slotOf(0)!).width,
      closeTo(r0.width * 1.2 / b.solver.scaleX, 0.5),
    );

    await t.tap(find.byTooltip('Show as list'));
    await t.pump();
    expect(b.solver.isActive, isTrue);
    await t.pumpAndSettle();
    expect(b.solver.isActive, isFalse);
    expect(
      b.nodeRect(1)!.left,
      b.nodeRect(2)!.left,
      reason: 'list: one column',
    );

    // Card 3 is draggable (round); flick it and let it spring home.
    final Rect r3 = b.nodeRect(3)!;
    await t.flingFrom(origin + r3.center, const Offset(120, 0), 1500);
    await t.pump(const Duration(milliseconds: 16));
    expect(find.textContaining('Flicked card 3'), findsOneWidget);
    await t.pumpAndSettle();
    final int s3 = b.solver.slotOf(3)!;
    debugPrint(
      'MORPH_SMOKE flick size=${b.size} r3=$r3 after=${b.nodeRect(3)} '
      'cur=${b.solver.store.currentCenter(s3)} tgt=${b.solver.store.targetCenter(s3)} '
      'active=${b.solver.isActive} '
      'dragging=${b.solver.store.hasFlag(s3, MorphAux.flagDragging)} '
      'scroll=${b.solver.scrollOffset}',
    );
    expect(b.nodeRect(3)!.center.dx, closeTo(r3.center.dx, 0.5));

    // Drag on the empty left margin so no (possibly draggable) card is hit.
    await t.dragFrom(origin + const Offset(6, 200), const Offset(0, -300));
    await t.pumpAndSettle();
    expect(b.solver.scrollOffset, greaterThan(100));
  });

  testWidgets('keyboard focus moves between nodes and activates', (t) async {
    final List<Object> taps = <Object>[];
    await t.pumpWidget(
      host(
        MorphOSField(
          onNodeTap: (Object id, int i) => taps.add(id),
          spec: MorphFieldSpec.grid(
            width: 300,
            columns: 3,
            nodes: <MorphNodeSpec>[
              for (int i = 0; i < 6; i++) MorphNodeSpec(id: i, size: Size.zero),
            ],
          ),
        ),
      ),
    );
    final MorphOSRenderBridge b = bridgeOf(t);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    expect(b.focusedId, 0);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(b.focusedId, 3);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(taps, <Object>[3]);
  });
}
