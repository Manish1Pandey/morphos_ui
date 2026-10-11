// Profiles the one-off cost of a layout change at 5,000 cards, split into:
// building the node specs, constructing/validating the field spec, comparing
// it with the previous one, and applying it in the render object.
//
//   flutter drive --profile -d macos --driver=test_driver/integration_test.dart \
//     --target=integration_test/spec_cost_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:morphos_benchmark/contenders.dart';
import 'package:morphos_ui/morphos_ui.dart';

List<MorphNodeSpec> nodesFor(bool grid, int n) {
  final List<Rect> r = cells(n, grid);
  return <MorphNodeSpec>[
    for (int i = 0; i < n; i++)
      MorphNodeSpec(
        id: i,
        size: r[i].size,
        position: r[i].topLeft,
        cornerRadius: 4,
        color: cardColor(i),
      ),
  ];
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('spec change cost at 5,000 cards', (WidgetTester tester) async {
    const int n = 5000;
    final MorphFieldSpec grid = MorphFieldSpec(
      designSize: Size(kWidth, contentHeight(n, true)),
      nodes: nodesFor(true, n),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: kWidth,
          height: 800,
          child: MorphOSField(spec: grid),
        ),
      ),
    );
    final MorphOSRenderBridge b = tester.allRenderObjects
        .whereType<MorphOSRenderBridge>()
        .single;
    final List<int> build = <int>[],
        construct = <int>[],
        equal = <int>[],
        apply = <int>[];
    bool g = false;
    for (int round = 0; round < 12; round++) {
      final Stopwatch sw = Stopwatch()..start();
      final List<MorphNodeSpec> nodes = nodesFor(g, n);
      build.add(sw.elapsedMicroseconds);
      sw
        ..reset()
        ..start();
      final MorphFieldSpec spec = MorphFieldSpec(
        designSize: Size(kWidth, contentHeight(n, g)),
        nodes: nodes,
      );
      construct.add(sw.elapsedMicroseconds);
      sw
        ..reset()
        ..start();
      final bool same = spec == b.spec;
      equal.add(sw.elapsedMicroseconds);
      b.spec = spec;
      apply.add(b.perf.lastApplyMicros);
      expect(same, isFalse);
      g = !g;
      await tester.pump(const Duration(milliseconds: 16));
    }
    int med(List<int> v) =>
        (List<int>.of(v.skip(2))..sort())[(v.length - 2) ~/ 2];
    debugPrint(
      'SPEC_COST n=$n median us: build=${med(build)} construct+validate=${med(construct)} '
      'equality=${med(equal)} apply=${med(apply)}',
    );
  });
}
