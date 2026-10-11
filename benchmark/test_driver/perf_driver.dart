import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// Writes build/compare.json and prints one row per contender and size.
Future<void> main() => integrationDriver(
  responseDataCallback: (Map<String, dynamic>? data) async {
    if (data == null) return;
    File('build/compare.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
    String f(Object? v) => ((v as num?) ?? 0).toStringAsFixed(2).padLeft(6);
    stdout.writeln(
      'key                     UI avg   p90  worst | raster avg  p90 | missed',
    );
    for (final String key in data.keys.toList()..sort()) {
      final Map<String, dynamic> a = (data[key] as Map<dynamic, dynamic>)
          .cast<String, dynamic>();
      stdout.writeln(
        '${key.padRight(22)} ${f(a['average_frame_build_time_millis'])} '
        '${f(a['90th_percentile_frame_build_time_millis'])} '
        '${f(a['worst_frame_build_time_millis'])} | '
        '${f(a['average_frame_rasterizer_time_millis'])} '
        '${f(a['90th_percentile_frame_rasterizer_time_millis'])} | '
        '${a['missed_frame_build_budget_count']}/${a['frame_count']}',
      );
    }
  },
);
