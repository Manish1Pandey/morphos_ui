import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphos_ui/morphos_ui.dart';

MorphOSRenderBridge bridgeOf(WidgetTester tester) =>
    tester.allRenderObjects.whereType<MorphOSRenderBridge>().single;

/// [n] rows, 20 design units tall, in a 100-unit-wide field.
MorphFieldSpec rows(int n, {bool text = false}) => MorphFieldSpec.list(
  width: 100,
  itemHeight: 20,
  nodes: <MorphNodeSpec>[
    for (int i = 0; i < n; i++)
      MorphNodeSpec(id: i, size: Size.zero, text: text ? 'Row $i' : null),
  ],
);

Widget host(Widget child) => MediaQuery(
  data: const MediaQueryData(),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 400, height: 400, child: child),
    ),
  ),
);

void main() {
  group('active set', () {
    test('changing one node of 10,000 animates exactly one', () {
      final MorphFieldSpec base = rows(10000);
      final MorphFieldSolver s = MorphFieldSolver()..applySpec(base);
      expect(s.activeCount, 0);
      final MorphNodeSpec moved = base.nodes[1234].copyWith(
        position: base.nodes[1234].position + const Offset(30, 0),
      );
      s.applySpec(
        base.withNode(moved),
        stagger: const MorphStagger.byIndex(Duration(milliseconds: 10)),
      );
      expect(s.activeCount, 1);
      expect(s.isActive, isTrue);
      // Unchanged nodes were not rewritten, so no stagger restarted on them.
      expect(s.store.aux[MorphAux.base(5000) + MorphAux.delay], 0);
      double t = 0;
      while (s.step(1 / 60) && t < 5) {
        t += 1 / 60;
        expect(s.activeCount, lessThanOrEqualTo(1));
      }
      expect(s.activeCount, 0);
      expect(s.store.targetCenter(1234), s.store.currentCenter(1234));
    });

    test('a flick in a 10,000-node field animates one node', () {
      final MorphFieldSolver s = MorphFieldSolver()..applySpec(rows(10000));
      s
        ..beginDrag(42)
        ..dragBy(42, const Offset(10, 0))
        ..endDrag(42, const Offset(300, 0));
      expect(s.activeCount, 1);
      s.step(1 / 60);
      expect(s.activeCount, 1);
    });

    test('replay stays bit-exact with the active set', () {
      final MorphRecorder rec = MorphRecorder();
      final MorphFieldSpec base = rows(500);
      final MorphFieldSolver live = MorphFieldSolver()..observer = rec;
      live.applySpec(base);
      live.applySpec(
        base.withNodes(<MorphNodeSpec>[
          base.nodes[3].copyWith(position: const Offset(40, 40)),
          base.nodes[300].copyWith(size: const Size(50, 50)),
        ]),
      );
      for (int i = 0; i < 30; i++) {
        live.step(1 / 75);
      }
      expect(rec.replay().checksum(), live.checksum());
    });
  });

  group('withNode', () {
    test('replaces by id and shares every other node', () {
      final MorphFieldSpec base = rows(100);
      final MorphNodeSpec changed = base.nodes[7].copyWith(color: Colors.red);
      final MorphFieldSpec next = base.withNode(changed);
      expect(identical(next.nodes[7], changed), isTrue);
      expect(identical(next.nodes[8], base.nodes[8]), isTrue);
      expect(next.nodes.length, 100);
    });

    test('rejects unknown ids, duplicates and invalid nodes', () {
      final MorphFieldSpec base = rows(10);
      expect(
        () => base.withNode(const MorphNodeSpec(id: 'nope', size: Size(1, 1))),
        throwsArgumentError,
      );
      expect(
        () => base.withNodes(<MorphNodeSpec>[base.nodes[1], base.nodes[1]]),
        throwsArgumentError,
      );
      expect(
        () => base.withNode(base.nodes[1].copyWith(mass: -1)),
        throwsArgumentError,
      );
      expect(identical(base.withNodes(const <MorphNodeSpec>[]), base), isTrue);
    });
  });

  group('culling', () {
    for (final MorphPaintMode mode in MorphPaintMode.values) {
      testWidgets('${mode.name}: only on-screen rows are drawn', (
        WidgetTester tester,
      ) async {
        await tester.pumpWidget(
          host(
            MorphOSField(
              spec: rows(2000),
              fit: MorphFit.fitWidth,
              enableScroll: true,
              paintMode: mode,
            ),
          ),
        );
        final MorphOSRenderBridge b = bridgeOf(tester);
        // 400px viewport at scale 4 shows ~5 rows of 80px (+ gaps).
        expect(b.perf.culled, greaterThan(1980));
        if (mode == MorphPaintMode.shapes) {
          expect(b.perf.drawCalls, lessThan(10));
        }
        b.controller ??= MorphController();
        b.controller!.jumpTo(40000);
        await tester.pump();
        expect(
          b.perf.culled,
          greaterThan(1980),
          reason: 'still culled mid-list',
        );
      });
    }

    testWidgets('semantics covers only rows near the viewport', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          MorphOSField(
            spec: rows(2000, text: true),
            fit: MorphFit.fitWidth,
            enableScroll: true,
          ),
        ),
      );
      int count = 0;
      bridgeOf(tester).debugSemantics!.visitChildren((SemanticsNode n) {
        count++;
        return true;
      });
      expect(count, greaterThan(3));
      expect(count, lessThan(40), reason: 'not all 2,000 rows');
      handle.dispose();
    });
  });
}
