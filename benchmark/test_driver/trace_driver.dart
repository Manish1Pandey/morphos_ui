import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// Saves each recorded timeline to `build/trace_NAME.json`.
Future<void> main() => integrationDriver(
  responseDataCallback: (Map<String, dynamic>? data) async {
    if (data == null) return;
    for (final MapEntry<String, dynamic> e in data.entries) {
      File('build/${e.key}.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(e.value));
    }
  },
);
