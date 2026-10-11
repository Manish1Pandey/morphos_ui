import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// Writes every benchmark's frame-time summary to build/morphos_benchmark.json
/// and prints a comparison table.
Future<void> main() => integrationDriver(
  responseDataCallback: (Map<String, dynamic>? data) async {
    if (data == null) return;
    final File out = File('build/morphos_benchmark.json')
      ..createSync(recursive: true);
    out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
    stdout.writeln(
      'key                build avg / p90 / worst ms   raster avg / p90 / worst ms   missed',
    );
    for (final String key in data.keys.toList()..sort()) {
      final Map<String, dynamic> m = (data[key] as Map<dynamic, dynamic>)
          .cast<String, dynamic>();
      String f(String k) => (m[k] as num? ?? 0).toStringAsFixed(2).padLeft(6);
      stdout.writeln(
        '${key.padRight(18)} ${f('average_frame_build_time_millis')} ${f('90th_percentile_frame_build_time_millis')} ${f('worst_frame_build_time_millis')}'
        '        ${f('average_frame_rasterizer_time_millis')} ${f('90th_percentile_frame_rasterizer_time_millis')} ${f('worst_frame_rasterizer_time_millis')}'
        '        ${m['missed_frame_build_budget_count']}/${m['frame_count']}',
      );
    }
  },
);
