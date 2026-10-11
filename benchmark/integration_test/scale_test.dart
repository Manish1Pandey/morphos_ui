// Scaling: 20,000 / 50,000 / 100,000 cards.
//
//  * morph: every card moves (grid <-> list), 2 morphs x 1.2 s.
//  * one: only card 0 moves, 4 nudges x 1.2 s - the common "one thing
//    changed in a big field" case.
//
//   flutter drive --profile -d <device> --driver=test_driver/perf_driver.dart \
//     --target=integration_test/scale_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:morphos_benchmark/contenders.dart';

const List<int> kCounts = <int>[20000, 50000, 100000];
const List<Contender> kContenders = <Contender>[
  Contender.morphos,
  Contender.painter,
  Contender.flame,
  Contender.widgets,
];

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final int n in kCounts) {
    for (final Contender c in kContenders) {
      // A widget tree of 100,000 animated cards does not build in reasonable
      // time; it is measured up to 20,000.
      if (c == Contender.widgets && n > 20000) continue;
      testWidgets('${c.name}_$n', (WidgetTester tester) async {
        binding.framePolicy =
            LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
        final GlobalKey<BenchState> bench = GlobalKey<BenchState>();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: kWidth,
                  child: Bench(key: bench, contender: c, count: n),
                ),
              ),
            ),
          ),
        );
        for (int i = 0; i < 600 && bench.currentState == null; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(bench.currentState, isNotNull, reason: 'bench never built');
        await Future<void>.delayed(const Duration(seconds: 2));
        await binding.watchPerformance(() async {
          for (int round = 0; round < 4; round++) {
            bench.currentState!.nudgeOne();
            await Future<void>.delayed(const Duration(milliseconds: 1200));
          }
        }, reportKey: 'one_${c.name}_$n');
        await binding.watchPerformance(() async {
          for (int round = 0; round < 2; round++) {
            bench.currentState!.toggle();
            await Future<void>.delayed(const Duration(milliseconds: 1200));
          }
        }, reportKey: 'morph_${c.name}_$n');
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
    }
  }
}
