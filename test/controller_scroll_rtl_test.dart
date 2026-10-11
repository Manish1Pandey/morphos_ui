import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphos_ui/morphos_ui.dart';

MorphOSRenderBridge bridgeOf(WidgetTester tester) =>
    tester.allRenderObjects.whereType<MorphOSRenderBridge>().single;

/// 30 rows of 20 design units in a 100-unit-wide design (scale 4 in a 400px
/// box), so content is 2,400+ px tall in a 400 px viewport.
MorphFieldSpec tallList() => MorphFieldSpec.list(
  width: 100,
  itemHeight: 20,
  nodes: <MorphNodeSpec>[
    for (int i = 0; i < 30; i++)
      MorphNodeSpec(id: i, size: Size.zero, text: 'Row $i'),
  ],
);

Widget host(Widget child, {TextDirection direction = TextDirection.ltr}) =>
    MediaQuery(
      data: const MediaQueryData(),
      child: Directionality(
        textDirection: direction,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 400, height: 400, child: child),
        ),
      ),
    );

void main() {
  group('MorphController', () {
    testWidgets('scrollToNode springs there and completes', (
      WidgetTester tester,
    ) async {
      final MorphController c = MorphController();
      int notifications = 0;
      c.addListener(() => notifications++);
      await tester.pumpWidget(
        host(
          MorphOSField(
            spec: tallList(),
            fit: MorphFit.fitWidth,
            enableScroll: true,
            controller: c,
          ),
        ),
      );
      expect(c.isAttached, isTrue);
      expect(c.maxScrollOffset, greaterThan(1000));

      bool done = false;
      unawaited(
        c.scrollToNode(20, alignment: 0.5).then((bool ok) => done = ok),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(done, isFalse, reason: 'animated, not instant');
      expect(c.isAnimating, isTrue);
      await tester.pumpAndSettle();
      expect(done, isTrue);
      final Rect r = c.nodeRect(20)!;
      expect(
        r.center.dy,
        closeTo(200, 1),
        reason: 'centred in the 400px viewport',
      );
      expect(notifications, greaterThan(1));
      expect(c.nodeAt(r.center), 20);

      c.jumpTo(0);
      expect(c.scrollOffset, 0);
      expect(c.nodeRect(0)!.top, 16 * 4);
      expect(await c.scrollToNode('missing'), isFalse);
    });

    testWidgets('whenSettled and onSettled fire once motion stops', (
      WidgetTester tester,
    ) async {
      final MorphController c = MorphController();
      int settles = 0;
      Widget build(double y) => host(
        MorphOSField(
          controller: c,
          onSettled: () => settles++,
          spec: MorphFieldSpec(
            designSize: const Size(100, 100),
            nodes: <MorphNodeSpec>[
              MorphNodeSpec(
                id: 1,
                size: const Size(10, 10),
                position: Offset(0, y),
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(build(0));
      await c.whenSettled(); // already at rest: completes at once
      await tester.pumpWidget(build(50));
      bool settled = false;
      unawaited(c.whenSettled().then((_) => settled = true));
      await tester.pump(const Duration(milliseconds: 100));
      expect(settled, isFalse);
      await tester.pumpAndSettle();
      expect(settled, isTrue);
      expect(settles, 1);
    });

    testWidgets('a user drag interrupts animateTo', (
      WidgetTester tester,
    ) async {
      final MorphController c = MorphController();
      await tester.pumpWidget(
        host(
          MorphOSField(
            spec: tallList(),
            fit: MorphFit.fitWidth,
            enableScroll: true,
            controller: c,
          ),
        ),
      );
      bool done = false;
      unawaited(c.animateTo(2000).then((_) => done = true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      await tester.dragFrom(const Offset(2, 300), const Offset(0, -100));
      await tester.pump();
      expect(done, isTrue);
      await tester.pumpAndSettle();
      expect(c.scrollOffset, lessThan(2000));
    });

    testWidgets('detaches on dispose and can move to another field', (
      WidgetTester tester,
    ) async {
      final MorphController c = MorphController();
      await tester.pumpWidget(
        host(MorphOSField(spec: tallList(), controller: c)),
      );
      await tester.pumpWidget(const SizedBox());
      expect(c.isAttached, isFalse);
      expect(c.scrollOffset, 0);
      expect(() => c.jumpTo(10), throwsStateError);
      await tester.pumpWidget(
        host(MorphOSField(spec: tallList(), controller: c)),
      );
      expect(c.isAttached, isTrue);
    });
  });

  testWidgets('horizontal scrolling follows horizontal drags only', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        MorphOSField(
          fit: MorphFit.fitHeight,
          enableScroll: true,
          scrollDirection: Axis.horizontal,
          spec: MorphFieldSpec(
            designSize: const Size(1000, 100),
            nodes: <MorphNodeSpec>[
              for (int i = 0; i < 10; i++)
                MorphNodeSpec(
                  id: i,
                  size: const Size(80, 80),
                  position: Offset(10 + i * 100.0, 10),
                ),
            ],
          ),
        ),
      ),
    );
    final MorphOSRenderBridge b = bridgeOf(tester);
    expect(b.solver.maxScrollOffset, closeTo(1000 * 4 - 400, 0.01));
    await tester.dragFrom(const Offset(200, 395), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(b.solver.scrollOffset, 0, reason: 'vertical drag ignored');
    await tester.flingFrom(const Offset(300, 395), const Offset(-200, 0), 1500);
    await tester.pumpAndSettle();
    expect(b.solver.scrollOffset, greaterThan(200));
    expect(b.nodeRect(0)!.left, lessThan(0), reason: 'content moved left');
  });

  group('right-to-left', () {
    MorphFieldSpec corner() => MorphFieldSpec(
      designSize: const Size(100, 100),
      nodes: const <MorphNodeSpec>[
        MorphNodeSpec(
          id: 'start',
          size: Size(20, 20),
          rotation: 0.3,
          text: 'hello',
        ),
      ],
    );

    testWidgets('mirrors node positions and rotation', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(MorphOSField(spec: corner()), direction: TextDirection.rtl),
      );
      final MorphOSRenderBridge b = bridgeOf(tester);
      expect(b.solver.store.targetCenter(0), const Offset(90, 10));
      expect(
        b.solver.store.aux[MorphAux.base(0) + MorphAux.rotation],
        closeTo(-0.3, 1e-6),
      );
      expect(
        b.debugHasScheduledFrame,
        isFalse,
        reason: 'first build is not animated',
      );
    });

    testWidgets('switching direction springs nodes across', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(MorphOSField(spec: corner())));
      final MorphOSRenderBridge b = bridgeOf(tester);
      expect(b.solver.store.targetCenter(0), const Offset(10, 10));
      await tester.pumpWidget(
        host(MorphOSField(spec: corner()), direction: TextDirection.rtl),
      );
      expect(b.solver.isActive, isTrue);
      await tester.pumpAndSettle();
      expect(b.solver.store.currentCenter(0), const Offset(90, 10));
    });

    testWidgets('mirrorInRtl: false keeps the layout', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          MorphOSField(spec: corner(), mirrorInRtl: false),
          direction: TextDirection.rtl,
        ),
      );
      expect(
        bridgeOf(tester).solver.store.targetCenter(0),
        const Offset(10, 10),
      );
    });
  });

  testWidgets('screen readers can scroll the field', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        MorphOSField(
          spec: tallList(),
          fit: MorphFit.fitWidth,
          enableScroll: true,
        ),
      ),
    );
    final MorphOSRenderBridge b = bridgeOf(tester);
    SemanticsData data = b.debugSemantics!.getSemanticsData();
    expect(data.hasAction(SemanticsAction.scrollUp), isTrue);
    expect(
      data.hasAction(SemanticsAction.scrollDown),
      isFalse,
      reason: 'already at the top',
    );
    b.debugSemantics!.owner!.performAction(
      b.debugSemantics!.id,
      SemanticsAction.scrollUp,
    );
    await tester.pumpAndSettle();
    expect(
      b.solver.scrollOffset,
      closeTo(320, 1),
      reason: '80% of a 400px page',
    );
    data = b.debugSemantics!.getSemanticsData();
    expect(data.hasAction(SemanticsAction.scrollDown), isTrue);
    expect(data.scrollPosition, closeTo(320, 1));
    handle.dispose();
  });
}
