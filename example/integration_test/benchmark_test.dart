// Frame-time benchmark: MorphOS-UI vs an equivalent widget tree.
//
// Both sides animate the same N cards between a grid and a list four times.
// The widget side is a Stack of AnimatedPositioned + DecoratedBox + Text, the
// usual way to build this. Run in profile mode on a real device:
//
//   flutter drive --profile -d <device> \
//     --driver=test_driver/perf_driver.dart \
//     --target=integration_test/benchmark_test.dart
//
// Results land in build/morphos_benchmark.json.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:morphos_ui/morphos_ui.dart';

const List<int> kCounts = <int>[100, 1000, 5000];
const double kWidth = 400;

/// Grid (or list) cell rectangles for [n] cards in a [kWidth]-wide area.
List<Rect> cells(int n, bool grid) {
  final int columns = grid ? math.max(2, (kWidth / 40).floor()) : 1;
  const double gap = 4;
  final double w = (kWidth - 8 - gap * (columns - 1)) / columns;
  final double h = grid ? w : 18;
  return <Rect>[
    for (int i = 0; i < n; i++)
      Rect.fromLTWH(
        4 + (i % columns) * (w + gap),
        4 + (i ~/ columns) * (h + gap),
        w,
        h,
      ),
  ];
}

class Bench extends StatefulWidget {
  const Bench({super.key, required this.morph, required this.count});
  final bool morph;
  final int count;
  @override
  State<Bench> createState() => BenchState();
}

class BenchState extends State<Bench> {
  bool grid = true;
  void toggle() => setState(() => grid = !grid);

  @override
  Widget build(BuildContext context) {
    final List<Rect> r = cells(widget.count, grid);
    final double height = r.isEmpty ? 1 : r.last.bottom + 4;
    if (widget.morph) {
      return MorphOSField(
        fit: MorphFit.fitWidth,
        enableScroll: true,
        spec: MorphFieldSpec(
          designSize: Size(kWidth, height),
          nodes: <MorphNodeSpec>[
            for (int i = 0; i < r.length; i++)
              MorphNodeSpec(
                id: i,
                size: r[i].size,
                position: r[i].topLeft,
                cornerRadius: 4,
                color: Color(0xFF3D5AFE + (i % 7) * 0x1100),
                text: widget.count <= 1000 ? '$i' : null,
                textStyle: const TextStyle(fontSize: 9, color: Colors.white),
              ),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      child: SizedBox(
        width: kWidth,
        height: height,
        child: Stack(
          children: <Widget>[
            for (int i = 0; i < r.length; i++)
              AnimatedPositioned(
                key: ValueKey<int>(i),
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutBack,
                left: r[i].left,
                top: r[i].top,
                width: r[i].width,
                height: r[i].height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0xFF3D5AFE + (i % 7) * 0x1100),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: widget.count <= 1000
                      ? Center(
                          child: Text(
                            '$i',
                            style: const TextStyle(
                              fontSize: 9,
                              color: Colors.white,
                            ),
                          ),
                        )
                      : null,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  for (final int n in kCounts) {
    for (final bool morph in <bool>[true, false]) {
      final String key = '${morph ? 'morphos' : 'widgets'}_$n';
      testWidgets(key, (WidgetTester tester) async {
        final GlobalKey<BenchState> bench = GlobalKey<BenchState>();
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: kWidth,
                  child: Bench(key: bench, morph: morph, count: n),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await binding.watchPerformance(() async {
          for (int round = 0; round < 4; round++) {
            bench.currentState!.toggle();
            await tester.pumpAndSettle(const Duration(milliseconds: 16));
          }
        }, reportKey: key);
      });
    }
  }
}
