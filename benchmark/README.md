# morphos_ui benchmark

Compares MorphOS-UI (both paint modes) with a hand-written `CustomPainter`,
[Flame](https://pub.dev/packages/flame) and a plain widget tree, all running
the same workload: N cards morphing between a grid and a list. This app is
not part of the published package.

Run everything in **profile mode** on a real device, with the app window in
front. macOS throttles a covered window to about 10 fps, which ruins the
numbers. Discard any run where a contender reports far fewer frames than the
others.

| What | Command |
|---|---|
| Frame times, all contenders, 100 / 1,000 / 5,000 cards | `flutter drive --profile -d <device> --driver=test_driver/perf_driver.dart --target=integration_test/compare_test.dart` (results in `build/compare.json`) |
| Scaling: 20,000 / 50,000 / 100,000 cards, one card changing and all cards morphing | `flutter drive --profile -d <device> --driver=test_driver/perf_driver.dart --target=integration_test/scale_test.dart` |
| Timeline traces with GC events, MorphOS-UI vs painter at 5,000 cards | `flutter drive --profile -d <device> --driver=test_driver/trace_driver.dart --target=integration_test/trace_test.dart` (writes `build/trace_morphos.json` and `build/trace_painter.json`, which open in Perfetto) |
| Cost of one layout change at 5,000 cards (build, validate, compare, apply) | `flutter drive --profile -d <device> --driver=test_driver/perf_driver.dart --target=integration_test/spec_cost_test.dart` |
| Watch them by hand | `flutter run --profile -d <device>` |

Notes on the method:

- Each morph is measured over a fixed 1.2 s window. Flame's game loop never
  stops, so waiting until everything settles would never end.
- The integration-test harness renders every vsync, so idle cost can't be
  measured here. MorphOS-UI's "no frames when idle" behaviour is covered by
  the package's own tests instead.
