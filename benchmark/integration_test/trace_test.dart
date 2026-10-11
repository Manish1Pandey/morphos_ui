// Records a timeline (including GC) while MorphOS-UI and the hand-written
// painter morph 5,000 cards, so slow frames can be attributed.
//
//   flutter drive --profile -d macos --driver=test_driver/trace_driver.dart \
//     --target=integration_test/trace_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:morphos_benchmark/contenders.dart';

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  for (final Contender c in <Contender>[Contender.morphos, Contender.painter]) {
    testWidgets('trace ${c.name}', (WidgetTester tester) async {
      final GlobalKey<BenchState> bench = GlobalKey<BenchState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: kWidth,
                child: Bench(key: bench, contender: c, count: 5000),
              ),
            ),
          ),
        ),
      );
      for (int i = 0; i < 300 && bench.currentState == null; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      await binding.traceAction(
        () async {
          for (int round = 0; round < 6; round++) {
            bench.currentState!.toggle();
            await Future<void>.delayed(const Duration(milliseconds: 1200));
          }
        },
        streams: const <String>['Dart', 'GC', 'Embedder'],
        reportKey: 'trace_${c.name}',
      );
    });
  }
}
