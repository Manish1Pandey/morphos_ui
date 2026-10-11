import 'package:flutter/material.dart';

import 'contenders.dart';

void main() => runApp(const MaterialApp(home: _Picker()));

/// Lets you watch each contender by hand: pick one, pick a size, tap Morph.
class _Picker extends StatefulWidget {
  const _Picker();

  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  Contender _c = Contender.morphos;
  int _n = 1000;
  // A fresh key per selection so state never carries over between benches.
  GlobalKey<BenchState> _bench = GlobalKey<BenchState>();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('${_c.name} · $_n cards'),
      actions: <Widget>[
        DropdownButton<Contender>(
          value: _c,
          items: <DropdownMenuItem<Contender>>[
            for (final Contender c in Contender.values)
              DropdownMenuItem<Contender>(value: c, child: Text(c.name)),
          ],
          onChanged: (Contender? c) => setState(() {
            _c = c!;
            _bench = GlobalKey<BenchState>();
          }),
        ),
        DropdownButton<int>(
          value: _n,
          items: <DropdownMenuItem<int>>[
            for (final int n in <int>[100, 1000, 5000])
              DropdownMenuItem<int>(value: n, child: Text('$n')),
          ],
          onChanged: (int? n) => setState(() {
            _n = n!;
            _bench = GlobalKey<BenchState>();
          }),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => _bench.currentState?.toggle(),
      label: const Text('Morph'),
    ),
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: kWidth,
        child: Bench(key: _bench, contender: _c, count: _n),
      ),
    ),
  );
}
