// Compares morphos_ui with a widget tree, a hand-written CustomPainter and
// Flame on the same workload. Run in profile mode on a real device:
//
//   flutter drive --profile -d <device> \
//     --driver=test_driver/perf_driver.dart \
//     --target=integration_test/compare_test.dart
//
// Each run: warm up, then 4 grid<->list morphs measured over a fixed
// 1.2 s window each (Flame's loop never stops, so "until settled" would not
// end). Idle cost is not measured here: the integration-test harness keeps
// producing frames for every contender.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:morphos_benchmark/contenders.dart';

const List<int> kCounts = <int>[100, 1000, 5000];

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final int n in kCounts) {
    for (final Contender c in Contender.values) {
      final String key = '${c.name}_$n';
      testWidgets(key, (WidgetTester tester) async {
        final GlobalKey<BenchState> bench = GlobalKey<BenchState>();
        // Build under the normal live policy (the very first frame needs it),
        // then measure with frames only when the app asks for them.
        binding.framePolicy =
            LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
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
        // Wait for the first build (the very first test can need a moment),
        // then let it warm up.
        for (int i = 0; i < 300 && bench.currentState == null; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(bench.currentState, isNotNull, reason: 'bench never built');
        await Future<void>.delayed(const Duration(seconds: 1));
        await binding.watchPerformance(() async {
          for (int round = 0; round < 4; round++) {
            bench.currentState!.toggle();
            await Future<void>.delayed(const Duration(milliseconds: 1200));
          }
        }, reportKey: key);
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
    }
  }
}
