import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:flutter_test/flutter_test.dart';
import 'package:morphos_ui/morphos_ui.dart';

MorphNodeSpec node(
  Object id, {
  Offset pos = Offset.zero,
  Size size = const Size(10, 10),
}) => MorphNodeSpec(id: id, size: size, position: pos);

MorphFieldSpec field(
  List<MorphNodeSpec> nodes, {
  Size design = const Size(100, 100),
}) => MorphFieldSpec(designSize: design, nodes: nodes);

/// Steps until settled or [maxSeconds] passed; returns seconds simulated.
double settle(
  MorphFieldSolver s, {
  double dt = 1 / 60,
  double maxSeconds = 10,
}) {
  double t = 0;
  while (s.step(dt) && t < maxSeconds) {
    t += dt;
  }
  return t;
}

void main() {
  group('MorphLayout / MorphAux offsets', () {
    test('stride-12 base uses shifts and matches i*12', () {
      for (int i = 0; i < 1000; i++) {
        expect(MorphLayout.base(i), i * 12);
        expect(MorphAux.base(i), i * 24);
      }
    });

    test('field order matches the documented layout', () {
      expect(<int>[
        MorphLayout.anchorX,
        MorphLayout.anchorY,
        MorphLayout.posX,
        MorphLayout.posY,
        MorphLayout.elasticity,
        MorphLayout.mass,
        MorphLayout.currentX,
        MorphLayout.currentY,
        MorphLayout.targetX,
        MorphLayout.targetY,
        MorphLayout.width,
        MorphLayout.height,
      ], List<int>.generate(12, (int i) => i));
    });
  });

  group('MorphNodeSpec validation', () {
    test('rejects bad values', () {
      expect(
        () => field(<MorphNodeSpec>[
          const MorphNodeSpec(id: 1, size: Size(-1, 1)),
        ]),
        throwsArgumentError,
      );
      expect(
        () => field(<MorphNodeSpec>[
          const MorphNodeSpec(id: 1, size: Size(1, 1), mass: 0),
        ]),
        throwsArgumentError,
      );
      expect(
        () => field(<MorphNodeSpec>[
          const MorphNodeSpec(id: 1, size: Size(1, 1), opacity: 2),
        ]),
        throwsArgumentError,
      );
      expect(
        () => field(<MorphNodeSpec>[
          const MorphNodeSpec(
            id: 1,
            size: Size(1, 1),
            position: Offset(double.nan, 0),
          ),
        ]),
        throwsArgumentError,
      );
      expect(
        () => field(<MorphNodeSpec>[
          const MorphNodeSpec(
            id: 1,
            size: Size(1, 1),
            elasticity: 1e6,
            mass: 1,
          ),
        ]),
        throwsArgumentError,
      );
      expect(
        () => field(<MorphNodeSpec>[node(1), node(1)]),
        throwsArgumentError,
      );
      expect(
        () => MorphFieldSpec(
          designSize: Size.zero,
          nodes: const <MorphNodeSpec>[],
        ),
        throwsArgumentError,
      );
    });

    test('anchor works like Alignment', () {
      const MorphNodeSpec n = MorphNodeSpec(
        id: 1,
        size: Size(10, 20),
        anchor: Offset(1, 1),
      );
      expect(n.centerIn(const Size(100, 100)), const Offset(95, 90));
    });
  });

  group('MorphFieldSpec helpers', () {
    test('grid places cells row by row and grows the design height', () {
      final MorphFieldSpec g = MorphFieldSpec.grid(
        width: 100,
        columns: 2,
        gap: 10,
        padding: EdgeInsets.zero,
        nodes: <MorphNodeSpec>[for (int i = 0; i < 5; i++) node(i)],
      );
      expect(g.nodes[0].size, const Size(45, 45));
      expect(g.nodes[1].position, const Offset(55, 0));
      expect(g.nodes[2].position, const Offset(0, 55));
      expect(g.designSize.height, 45 * 3 + 20);
    });

    test('equal specs compare equal', () {
      expect(field(<MorphNodeSpec>[node(1)]), field(<MorphNodeSpec>[node(1)]));
      expect(
        field(<MorphNodeSpec>[node(1)]) == field(<MorphNodeSpec>[node(2)]),
        isFalse,
      );
    });
  });

  group('MorphFieldStore', () {
    test('grows by doubling and keeps contents', () {
      final MorphFieldStore s = MorphFieldStore(2);
      s.layout[MorphLayout.base(1) + MorphLayout.mass] = 7;
      s.ensureCapacity(5);
      expect(s.capacity, 8);
      expect(s.layout[MorphLayout.base(1) + MorphLayout.mass], 7);
    });
  });

  test('node buffers shrink after a large field becomes small', () {
    final MorphFieldSolver s = MorphFieldSolver()
      ..applySpec(
        field(<MorphNodeSpec>[for (int i = 0; i < 5000; i++) node(i)]),
      );
    final int big = s.store.capacity;
    s.applySpec(
      field(<MorphNodeSpec>[node(0), node(1)]),
      animateEntryExit: false,
    );
    expect(s.store.capacity, lessThan(big ~/ 4));
    expect(s.slotOf(1), 1);
    expect(s.store.specs[1]!.id, 1);
  });

  group('field matrix', () {
    final MorphFieldSolver s = MorphFieldSolver()
      ..applySpec(field(<MorphNodeSpec>[node(1)], design: const Size(100, 50)));

    test('contain centres a uniform scale', () {
      s.updateMatrix(const Size(400, 400), MorphFit.contain);
      expect(s.scaleX, 4);
      expect(s.designToLocal(Offset.zero), const Offset(0, 100));
      expect(s.localToDesign(const Offset(200, 200)), const Offset(50, 25));
    });

    test('fill scales axes independently', () {
      s.updateMatrix(const Size(200, 200), MorphFit.fill);
      expect(s.scaleX, 2);
      expect(s.scaleY, 4);
    });

    test('cover and fitWidth', () {
      s.updateMatrix(const Size(100, 100), MorphFit.cover);
      expect(s.scaleX, 2);
      s.updateMatrix(const Size(300, 10), MorphFit.fitWidth);
      expect(s.designToLocal(Offset.zero), Offset.zero);
      expect(s.scaleY, 3);
    });

    test('degenerate box is reported as not invertible', () {
      s.updateMatrix(Size.zero, MorphFit.contain);
      expect(s.invertible, isFalse);
      expect(s.localToDesign(Offset.zero), isNull);
    });

    test('transformCentersInto is one affine pass', () {
      s.updateMatrix(const Size(200, 100), MorphFit.fill);
      final Float32List out = Float32List(2);
      s.transformCentersInto(out);
      expect(out[0], 10); // centre x 5 * 2
      expect(out[1], 10); // centre y 5 * 2
    });
  });

  group('springs', () {
    for (final double dt in <double>[1 / 60, 1 / 144, 1 / 30]) {
      test('converges to target at dt=${dt.toStringAsFixed(4)}', () {
        final MorphFieldSolver s = MorphFieldSolver()
          ..applySpec(field(<MorphNodeSpec>[node(1)]));
        s.applySpec(field(<MorphNodeSpec>[node(1, pos: const Offset(50, 30))]));
        expect(s.isActive, isTrue);
        final double t = settle(s, dt: dt);
        expect(t, lessThan(5));
        expect(s.store.currentCenter(0), const Offset(55, 35));
        expect(s.isActive, isFalse);
      });
    }

    test('stays bounded under jank (huge dt is clamped)', () {
      final MorphFieldSolver s = MorphFieldSolver()
        ..applySpec(field(<MorphNodeSpec>[node(1)]));
      s.applySpec(field(<MorphNodeSpec>[node(1, pos: const Offset(80, 0))]));
      for (int i = 0; i < 50; i++) {
        s.step(5);
        expect(s.store.currentCenter(0).dx.abs(), lessThan(1000));
      }
    });

    test('underdamped springs overshoot, critically damped do not', () {
      double peak(double zeta) {
        final MorphFieldSolver s = MorphFieldSolver()
          ..applySpec(
            field(<MorphNodeSpec>[
              MorphNodeSpec(
                id: 1,
                size: const Size(10, 10),
                dampingRatio: zeta,
              ),
            ]),
          );
        s.applySpec(
          field(<MorphNodeSpec>[
            MorphNodeSpec(
              id: 1,
              size: const Size(10, 10),
              dampingRatio: zeta,
              position: const Offset(50, 0),
            ),
          ]),
        );
        double m = 0;
        for (int i = 0; i < 600; i++) {
          s.step(1 / 120);
          m = m > s.store.currentCenter(0).dx ? m : s.store.currentCenter(0).dx;
        }
        return m;
      }

      expect(peak(0.3), greaterThan(55.5));
      expect(
        peak(1.0),
        lessThanOrEqualTo(55.0 + MorphFieldSolver.restPosition),
      );
    });
  });

  test('far-from-origin nodes still come to rest (float32 rounding)', () {
    final MorphFieldSolver s = MorphFieldSolver()
      ..applySpec(
        field(<MorphNodeSpec>[node(1)], design: const Size(100, 20000)),
      );
    s.applySpec(
      field(<MorphNodeSpec>[
        node(1, pos: const Offset(0, 9138)),
      ], design: const Size(100, 20000)),
    );
    expect(settle(s), lessThan(4));
    expect(s.isActive, isFalse);
    expect(s.store.currentCenter(0).dy, 9143);
  });

  group('id matching, entry and exit', () {
    test('a moved node keeps its mid-flight position and velocity', () {
      final MorphFieldSolver s = MorphFieldSolver()
        ..applySpec(field(<MorphNodeSpec>[node('a'), node('b')]));
      s.applySpec(
        field(<MorphNodeSpec>[node('a', pos: const Offset(60, 0)), node('b')]),
      );
      for (int i = 0; i < 6; i++) {
        s.step(1 / 60);
      }
      final Offset mid = s.store.currentCenter(0);
      expect(mid.dx, greaterThan(5));
      expect(mid.dx, lessThan(65));
      // Reorder the spec: 'a' moves to slot 1 but must not jump.
      s.applySpec(
        field(<MorphNodeSpec>[node('b'), node('a', pos: const Offset(60, 0))]),
      );
      expect(s.slotOf('a'), 1);
      expect(s.store.currentCenter(1), mid);
    });

    test('new nodes grow in, removed nodes shrink out and are freed', () {
      final MorphFieldSolver s = MorphFieldSolver()
        ..applySpec(field(<MorphNodeSpec>[node('a')]));
      s.applySpec(field(<MorphNodeSpec>[node('b')]));
      expect(s.store.length, 2); // b entering + a exiting
      expect(s.store.aux[MorphAux.base(0) + MorphAux.presence], 0);
      settle(s);
      expect(s.store.length, 1);
      expect(s.slotOf('a'), isNull);
      expect(s.store.aux[MorphAux.base(0) + MorphAux.presence], 1);
    });

    test('animateEntryExit false drops removed nodes at once', () {
      final MorphFieldSolver s = MorphFieldSolver()
        ..applySpec(field(<MorphNodeSpec>[node('a')]));
      s.applySpec(field(<MorphNodeSpec>[node('b')]), animateEntryExit: false);
      expect(s.store.length, 1);
      expect(s.store.aux[MorphAux.base(0) + MorphAux.presence], 1);
    });

    test('zIndex orders painting, ties keep spec order', () {
      final MorphFieldSolver s = MorphFieldSolver()
        ..applySpec(
          field(<MorphNodeSpec>[
            const MorphNodeSpec(id: 'a', size: Size(1, 1), zIndex: 2),
            const MorphNodeSpec(id: 'b', size: Size(1, 1)),
            const MorphNodeSpec(id: 'c', size: Size(1, 1)),
          ]),
        );
      expect(s.drawOrder.sublist(0, 3), <int>[1, 2, 0]);
      expect(s.drawRank[0], 2);
    });
  });

  group('stagger', () {
    test('byIndex delays later nodes', () {
      final MorphFieldSolver s = MorphFieldSolver()
        ..applySpec(field(<MorphNodeSpec>[node(0), node(1)]));
      s.applySpec(
        field(<MorphNodeSpec>[
          node(0, pos: const Offset(50, 0)),
          node(1, pos: const Offset(50, 0)),
        ]),
        stagger: const MorphStagger.byIndex(Duration(milliseconds: 200)),
      );
      for (int i = 0; i < 6; i++) {
        s.step(1 / 60); // 100 ms
      }
      expect(s.store.currentCenter(0).dx, greaterThan(6));
      expect(s.store.currentCenter(1).dx, 5); // still waiting
      settle(s);
      expect(s.store.currentCenter(1).dx, 55);
    });

    test('fromPoint grows with distance and is capped', () {
      const MorphStagger st = MorphStagger.fromPoint(
        Offset.zero,
        perHundredUnits: Duration(milliseconds: 100),
        max: Duration(milliseconds: 250),
      );
      expect(st.delayFor(0, const Offset(100, 0)), closeTo(0.1, 1e-9));
      expect(st.delayFor(0, const Offset(1000, 0)), closeTo(0.25, 1e-9));
    });
  });

  group('reduce motion and drags', () {
    test('reduceMotion snaps immediately', () {
      final MorphFieldSolver s = MorphFieldSolver()
        ..applySpec(field(<MorphNodeSpec>[node(1)]));
      s.reduceMotion = true;
      s.applySpec(field(<MorphNodeSpec>[node(1, pos: const Offset(40, 0))]));
      expect(s.store.currentCenter(0), const Offset(45, 5));
      expect(s.isActive, isFalse);
    });

    test('a flicked node carries its velocity then returns to target', () {
      final MorphFieldSolver s = MorphFieldSolver()
        ..applySpec(field(<MorphNodeSpec>[node(1)]));
      s.beginDrag(1);
      s.dragBy(1, const Offset(20, 0));
      s.step(1 / 60);
      expect(s.store.currentCenter(0).dx, 25); // held by the drag
      s.endDrag(1, const Offset(500, 0));
      s.step(1 / 60);
      expect(s.store.currentCenter(0).dx, greaterThan(25)); // momentum
      settle(s);
      expect(s.store.currentCenter(0), const Offset(5, 5));
    });
  });

  group('MorphRecorder', () {
    test('replay is bit-identical', () {
      final MorphRecorder rec = MorphRecorder();
      final MorphFieldSolver live = MorphFieldSolver()..observer = rec;
      live.applySpec(field(<MorphNodeSpec>[node('a'), node('b')]));
      live.applySpec(
        field(<MorphNodeSpec>[node('a', pos: const Offset(30, 40)), node('c')]),
        stagger: const MorphStagger.byIndex(Duration(milliseconds: 30)),
      );
      for (int i = 0; i < 20; i++) {
        live.step(1 / 61 + i * 0.0003);
      }
      live.beginDrag('a');
      live.dragBy('a', const Offset(3, -2));
      live.endDrag('a', const Offset(120, 80));
      for (int i = 0; i < 40; i++) {
        live.step(1 / 90);
      }
      final MorphFieldSolver replayed = rec.replay();
      expect(replayed.store.length, live.store.length);
      expect(replayed.checksum(), live.checksum());
    });
  });
}
