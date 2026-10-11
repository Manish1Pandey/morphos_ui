import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morphos_ui/morphos_ui.dart';

MorphFieldSolver solverWith(
  List<MorphNodeSpec> nodes, {
  Size design = const Size(100, 100),
}) {
  final MorphFieldSolver s = MorphFieldSolver()
    ..applySpec(MorphFieldSpec(designSize: design, nodes: nodes));
  s.updateMatrix(design, MorphFit.fill);
  return s;
}

void main() {
  group('MorphHitTester', () {
    test('returns the top-most node', () {
      final MorphFieldSolver s = solverWith(const <MorphNodeSpec>[
        MorphNodeSpec(id: 'under', size: Size(50, 50), zIndex: 0),
        MorphNodeSpec(id: 'over', size: Size(30, 30), zIndex: 1),
      ]);
      final MorphHitTester h = MorphHitTester(s);
      expect(s.store.ids[h.hitTestLocal(const Offset(10, 10))], 'over');
      expect(s.store.ids[h.hitTestLocal(const Offset(40, 40))], 'under');
      expect(h.hitTestLocal(const Offset(80, 80)), -1);
    });

    test('respects rotation and rounded corners', () {
      final MorphFieldSolver s = solverWith(const <MorphNodeSpec>[
        MorphNodeSpec(
          id: 'r',
          size: Size(40, 10),
          anchor: Offset(0.5, 0.5),
          rotation: math.pi / 2,
        ),
        MorphNodeSpec(
          id: 'round',
          size: Size(20, 20),
          cornerRadius: 10,
          anchor: Offset(1, 1),
        ),
      ]);
      final MorphHitTester h = MorphHitTester(s);
      expect(h.hitTestLocal(const Offset(50, 35)), 0); // rotated: tall now
      expect(
        h.hitTestLocal(const Offset(65, 50)),
        -1,
      ); // outside after rotation
      expect(
        h.hitTestLocal(const Offset(81, 81)),
        -1,
      ); // cut-off corner of the circle
      expect(h.hitTestLocal(const Offset(90, 90)), 1);
    });

    test('non-interactive nodes are never hit', () {
      final MorphFieldSolver s = solverWith(const <MorphNodeSpec>[
        MorphNodeSpec(id: 'a', size: Size(50, 50), interactive: false),
      ]);
      expect(MorphHitTester(s).hitTestLocal(const Offset(5, 5)), -1);
    });

    test('grid query agrees with the linear scan', () {
      final math.Random rnd = math.Random(7);
      final List<MorphNodeSpec> nodes = <MorphNodeSpec>[
        for (int i = 0; i < 2500; i++)
          MorphNodeSpec(
            id: i,
            size: Size(5 + rnd.nextDouble() * 30, 5 + rnd.nextDouble() * 30),
            position: Offset(rnd.nextDouble() * 950, rnd.nextDouble() * 950),
            rotation: rnd.nextDouble() * 3,
            cornerRadius: rnd.nextDouble() * 5,
            zIndex: rnd.nextInt(3),
          ),
      ];
      final MorphFieldSolver s = solverWith(
        nodes,
        design: const Size(1000, 1000),
      );
      final MorphHitTester h = MorphHitTester(s);
      int hits = 0;
      for (int i = 0; i < 3000; i++) {
        final double x = rnd.nextDouble() * 1000, y = rnd.nextDouble() * 1000;
        final int fast = h.hitTestDesign(x, y);
        expect(h.lastQueryUsedGrid, isTrue);
        expect(fast, h.hitTestLinear(x, y));
        if (fast >= 0) hits++;
      }
      expect(hits, greaterThan(100));
    });
  });

  group('MorphMesh', () {
    MorphFieldSolver solverOf(List<MorphNodeSpec> nodes) {
      final MorphFieldSolver s = MorphFieldSolver()
        ..applySpec(
          MorphFieldSpec(designSize: const Size(1000, 1000), nodes: nodes),
        );
      s.updateMatrix(const Size(1000, 1000), MorphFit.fill);
      return s;
    }

    test('square cards are 9 vertices; shape decides the rest', () {
      final MorphFieldSolver s = solverOf(const <MorphNodeSpec>[
        MorphNodeSpec(id: 'square', size: Size(40, 40)),
        MorphNodeSpec(id: 'round', size: Size(40, 40), cornerRadius: 20),
        MorphNodeSpec(id: 'bordered', size: Size(40, 40), borderWidth: 2),
      ]);
      final MorphMesh mesh = MorphMesh()..ensurePlan(s, 1);
      expect(mesh.vertStart[1] - mesh.vertStart[0], 9);
      final int seg = MorphMesh.segmentsForRadius(20);
      expect(
        mesh.vertStart[2] - mesh.vertStart[1],
        MorphMesh.verticesFor(seg, false),
      );
      expect(mesh.vertStart[3] - mesh.vertStart[2], 17);
      expect(mesh.batchCount, 1);
    });

    test('arc segments keep the polygon within a quarter pixel', () {
      expect(MorphMesh.segmentsForRadius(0), 0);
      for (final double r in <double>[0.5, 2, 8, 30, 80]) {
        final int seg = MorphMesh.segmentsForRadius(r);
        final double error = r * (1 - math.cos(math.pi / 2 / seg / 2));
        expect(error, lessThanOrEqualTo(0.25 + 1e-9), reason: 'r=$r seg=$seg');
      }
      expect(MorphMesh.segmentsForRadius(10000), MorphMesh.maxCornerSegments);
    });

    test('plans split into 16-bit batches with in-range indices', () {
      final MorphFieldSolver s = solverOf(<MorphNodeSpec>[
        for (int i = 0; i < 3000; i++)
          MorphNodeSpec(
            id: i,
            size: const Size(30, 30),
            position: Offset((i % 30) * 32.0, (i ~/ 30) * 9.0),
            cornerRadius: 15,
            borderWidth: 1,
          ),
      ]);
      final MorphMesh mesh = MorphMesh()..ensurePlan(s, 2);
      expect(mesh.batchCount, greaterThan(1));
      for (int k = 0; k < mesh.batchCount; k++) {
        final int qs = mesh.batchStart[k], qe = mesh.batchStart[k + 1];
        final int verts = mesh.vertStart[qe] - mesh.vertStart[qs];
        expect(verts, lessThanOrEqualTo(MorphMesh.maxBatchVertices));
        int maxIndex = 0;
        for (int i = mesh.indexStart[qs]; i < mesh.indexStart[qe]; i++) {
          maxIndex = math.max(maxIndex, mesh.indices[i]);
        }
        expect(maxIndex, verts - 1);
      }
      expect(mesh.ensurePlan(s, 2), isFalse, reason: 'cached until changes');
      expect(mesh.ensurePlan(s, 3), isTrue, reason: 'zoom changes segments');
    });

    test('writes a node at its transformed position', () {
      final MorphFieldSolver s = MorphFieldSolver()
        ..applySpec(
          MorphFieldSpec(
            designSize: const Size(100, 100),
            nodes: const <MorphNodeSpec>[
              MorphNodeSpec(
                id: 1,
                size: Size(20, 10),
                position: Offset(10, 20),
              ),
            ],
          ),
        );
      s.updateMatrix(const Size(200, 200), MorphFit.fill);
      final MorphMesh mesh = MorphMesh()..ensurePlan(s, 2);
      mesh.writeNode(0, 0, s, aaDesign: 0);
      expect(mesh.positions[0], 40); // centre (20, 25) * 2
      expect(mesh.positions[1], 50);
      expect(mesh.bounds.sublist(0, 4), <double>[20, 40, 60, 60]);
    });

    test('images cover the node instead of stretching', () async {
      final ui.PictureRecorder rec = ui.PictureRecorder();
      Canvas(rec).drawRect(
        const Rect.fromLTWH(0, 0, 40, 40),
        Paint()..color = const Color(0xFFFF0000),
      );
      final ui.Picture pic = rec.endRecording();
      final ui.Image img = await pic.toImage(40, 40);
      pic.dispose();
      final MorphImageAtlas atlas = await MorphImageAtlas.fromImages(
        <String, ui.Image>{'sq': img},
      );
      img.dispose();
      MorphMesh meshFor(MorphImageFit fit) {
        final MorphFieldSolver s = MorphFieldSolver()
          ..applySpec(
            MorphFieldSpec(
              designSize: const Size(200, 100),
              nodes: <MorphNodeSpec>[
                MorphNodeSpec(
                  id: 1,
                  size: const Size(200, 50),
                  imageKey: 'sq',
                  imageFit: fit,
                ),
              ],
            ),
          );
        s.updateMatrix(const Size(200, 100), MorphFit.fill);
        s.store.aux[MorphAux.base(0) + MorphAux.atlasSlot] = 0;
        return MorphMesh()
          ..ensurePlan(s, 1)
          ..writeNode(0, 0, s, aaDesign: 0, atlas: atlas);
      }

      double span(MorphMesh m, int axis) {
        double lo = double.infinity, hi = double.negativeInfinity;
        for (int v = 1; v < m.vertStart[1]; v++) {
          final double t = m.texCoords[v * 2 + axis];
          if (t == MorphImageAtlas.whiteU) continue; // untextured white texel
          lo = math.min(lo, t);
          hi = math.max(hi, t);
        }
        return hi - lo;
      }

      final Float32List r = atlas.rects;
      final double texW = r[2] - r[0], texH = r[3] - r[1];
      final MorphMesh fill = meshFor(MorphImageFit.fill);
      expect(span(fill, 0), closeTo(texW, 0.01));
      expect(span(fill, 1), closeTo(texH, 0.01));
      final MorphMesh cover = meshFor(MorphImageFit.cover);
      expect(span(cover, 0), closeTo(texW, 0.01), reason: 'full width');
      expect(span(cover, 1), closeTo(texW / 4, 0.01), reason: '4:1 band');
      atlas.dispose();
    });

    test('shrinks buffers after a large field becomes small', () {
      final MorphFieldSolver s = solverOf(<MorphNodeSpec>[
        for (int i = 0; i < 4000; i++)
          MorphNodeSpec(id: i, size: const Size(10, 10), cornerRadius: 5),
      ]);
      final MorphMesh mesh = MorphMesh()..ensurePlan(s, 1);
      final int big = mesh.colors.length;
      s.applySpec(
        MorphFieldSpec(
          designSize: const Size(1000, 1000),
          nodes: const <MorphNodeSpec>[
            MorphNodeSpec(id: 0, size: Size(10, 10)),
          ],
        ),
        animateEntryExit: false,
      );
      mesh
        ..ensurePlan(s, 1)
        ..shrinkToFit();
      expect(mesh.colors.length, lessThan(big ~/ 4));
      expect(mesh.capacity, lessThan(4000));
    });
  });

  group('MorphImageAtlas', () {
    Future<ui.Image> solid(int w, int h, Color c) {
      final ui.PictureRecorder r = ui.PictureRecorder();
      Canvas(r).drawRect(
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()..color = c,
      );
      final ui.Picture p = r.endRecording();
      return p.toImage(w, h).whenComplete(p.dispose);
    }

    test('packs images and reports texel rects', () async {
      final ui.Image a = await solid(16, 8, const Color(0xFFFF0000));
      final ui.Image b = await solid(32, 32, const Color(0xFF00FF00));
      final MorphImageAtlas atlas = await MorphImageAtlas.fromImages(
        <String, ui.Image>{'a': a, 'b': b},
      );
      expect(atlas.slotOf('a'), isNonNegative);
      expect(atlas.slotOf('missing'), -1);
      final int sb = atlas.slotOf('b');
      expect(atlas.rects[sb * 4 + 2] - atlas.rects[sb * 4], 31);
      final ByteData? bytes = await atlas.image.toByteData();
      final int x = (atlas.rects[sb * 4] + 4).floor(),
          y = (atlas.rects[sb * 4 + 1] + 4).floor();
      final int o = (y * atlas.image.width + x) * 4;
      expect(<int>[bytes!.getUint8(o), bytes.getUint8(o + 1)], <int>[0, 255]);
      expect(
        bytes.getUint8(((2 * atlas.image.width) + 2) * 4),
        255,
      ); // white block
      atlas.dispose();
      a.dispose();
      b.dispose();
      expect(atlas.isDisposed, isTrue);
    });

    test('rejects atlases larger than the limit', () async {
      final ui.Image a = await solid(64, 64, const Color(0xFF000000));
      await expectLater(
        MorphImageAtlas.fromImages(<String, ui.Image>{
          'a': a,
        }, maxDimension: 32),
        throwsA(isA<MorphAtlasException>()),
      );
      a.dispose();
    });
  });

  group('MorphTextCompiler', () {
    test('caches by text inputs and only relayouts on width change', () {
      MorphDebugStats.reset();
      final MorphTextCompiler c = MorphTextCompiler();
      const MorphNodeSpec n = MorphNodeSpec(
        id: 1,
        size: Size(10, 10),
        text: 'hello',
      );
      final ui.Paragraph p1 = c.paragraphFor(1, n, 100)!;
      expect(identical(c.paragraphFor(1, n, 60), p1), isTrue);
      final ui.Paragraph p2 = c.paragraphFor(1, n.copyWith(text: 'bye'), 60)!;
      expect(identical(p1, p2), isFalse);
      expect(MorphDebugStats.liveParagraphs, 1);
      c.retain((Object id) => false);
      expect(c.length, 0);
      expect(MorphDebugStats.liveParagraphs, 0);
      c.dispose();
    });
  });
}
