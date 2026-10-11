import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:morphos_ui/morphos_ui.dart';

void main() => runApp(const MorphDemoApp());

/// Demo app: one MorphOSField that morphs between a grid and a list,
/// ripples from the tapped card, carries flicked cards' momentum, shows
/// generated images from one atlas, and scales up to 5,000 nodes.
class MorphDemoApp extends StatelessWidget {
  /// Creates the app.
  const MorphDemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MorphOS-UI',
    theme: ThemeData(
      colorSchemeSeed: const Color(0xFF3D5AFE),
      useMaterial3: true,
    ),
    darkTheme: ThemeData(
      colorSchemeSeed: const Color(0xFF3D5AFE),
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: const DemoPage(),
  );
}

/// The demo screen.
class DemoPage extends StatefulWidget {
  /// Creates the screen.
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  static const List<int> _counts = <int>[24, 200, 1000, 5000];
  static const List<Color> _palette = <Color>[
    Color(0xFF3D5AFE),
    Color(0xFF00BFA5),
    Color(0xFFFF6D00),
    Color(0xFFD500F9),
    Color(0xFF2962FF),
    Color(0xFFC51162),
  ];

  bool _grid = true;
  int _countIndex = 0;
  Object? _expanded;
  Offset _rippleOrigin = Offset.zero;
  bool _perf = true;
  bool _sheen = false;
  Map<String, ImageProvider> _images = const <String, ImageProvider>{};
  String _status = 'Tap a card. Drag the round ones and flick them.';

  MorphFieldSpec? _lastSpec;
  final MorphController _controller = MorphController();
  bool _scrolled = false;

  int get _count => _counts[_countIndex];

  @override
  void initState() {
    super.initState();
    _makeImages();
    _controller.addListener(() {
      final bool scrolled = _controller.scrollOffset > 200;
      if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Renders three gradient tiles at runtime and hands them to the field as
  /// PNG bytes, so the demo needs no asset files.
  Future<void> _makeImages() async {
    final Map<String, ImageProvider> out = <String, ImageProvider>{};
    for (int k = 0; k < 3; k++) {
      final ui.PictureRecorder rec = ui.PictureRecorder();
      final Canvas c = Canvas(rec);
      const Rect r = Rect.fromLTWH(0, 0, 128, 128);
      c.drawRect(
        r,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset.zero,
            const Offset(128, 128),
            <Color>[_palette[k], _palette[(k + 3) % _palette.length]],
          ),
      );
      // A soft diagonal sheen; no small shapes that could read as glitches.
      c.drawRect(
        r,
        Paint()
          ..shader = ui.Gradient.linear(
            const Offset(0, 128),
            const Offset(128, 0),
            <Color>[
              const Color(0x00FFFFFF),
              const Color(0x33FFFFFF),
              const Color(0x00FFFFFF),
            ],
            <double>[0.35, 0.5, 0.65],
          ),
      );
      final ui.Picture pic = rec.endRecording();
      final ui.Image img = await pic.toImage(128, 128);
      pic.dispose();
      final ByteData? png = await img.toByteData(
        format: ui.ImageByteFormat.png,
      );
      img.dispose();
      if (png != null) out['tile$k'] = MemoryImage(png.buffer.asUint8List());
    }
    if (mounted) setState(() => _images = out);
  }

  MorphFieldSpec _spec(double width) {
    final bool small = _count > 200;
    final List<MorphNodeSpec> nodes = <MorphNodeSpec>[
      for (int i = 0; i < _count; i++)
        MorphNodeSpec(
          id: i,
          size: Size.zero,
          color: _palette[i % _palette.length],
          darkColor: _palette[i % _palette.length].withValues(alpha: 0.85),
          cornerRadius: i % 7 == 3 ? 999 : (small ? 3 : 14),
          rotation: _expanded == i ? 0.06 : 0,
          zIndex: _expanded == i ? 1 : 0,
          borderWidth: _expanded == i ? 3 : 0,
          borderColor: const Color(0xFFFFFFFF),
          text: small ? null : (i % 5 == 4 ? 'Card $i\nimage' : 'Card $i'),
          maxLines: 2,
          imageKey: !small && i % 5 == 4 ? 'tile${i % 3}' : null,
          draggable: i % 7 == 3,
          semanticLabel: 'Card $i',
          elasticity: 180,
          dampingRatio: i % 7 == 3 ? 0.45 : 0.8,
        ),
    ];
    final int columns = _grid
        ? math.max(2, (width / (small ? 28 : 120)).floor())
        : 1;
    final MorphFieldSpec base = MorphFieldSpec.grid(
      width: width,
      columns: columns,
      gap: small ? 4 : 12,
      itemHeight: _grid ? null : (small ? 14 : 56),
      nodes: nodes,
    );
    final Object? e = _expanded;
    if (e == null) return base;
    // Grow the expanded card in place by 20% around its centre.
    return MorphFieldSpec(
      designSize: base.designSize,
      nodes: <MorphNodeSpec>[
        for (final MorphNodeSpec n in base.nodes)
          n.id == e
              ? n.copyWith(
                  size: n.size * 1.2,
                  position:
                      n.position -
                      Offset(n.size.width * 0.1, n.size.height * 0.1),
                )
              : n,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: _scrolled
          ? FloatingActionButton.small(
              tooltip: 'Back to top',
              onPressed: () => _controller.scrollToNode(0),
              child: const Icon(Icons.arrow_upward),
            )
          : null,
      appBar: AppBar(
        title: const Text('MorphOS-UI'),
        actions: <Widget>[
          IconButton(
            tooltip: _grid ? 'Show as list' : 'Show as grid',
            icon: Icon(_grid ? Icons.view_list : Icons.grid_view),
            onPressed: () => setState(() {
              _grid = !_grid;
              _rippleOrigin = Offset.zero;
            }),
          ),
          IconButton(
            tooltip: 'Performance overlay',
            isSelected: _perf,
            icon: const Icon(Icons.speed),
            onPressed: () => setState(() => _perf = !_perf),
          ),
          IconButton(
            tooltip: 'Sheen effect',
            isSelected: _sheen,
            icon: const Icon(Icons.auto_awesome),
            onPressed: () => setState(() => _sheen = !_sheen),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: <Widget>[
                const Text('Nodes'),
                Expanded(
                  child: Slider(
                    value: _countIndex.toDouble(),
                    max: (_counts.length - 1).toDouble(),
                    divisions: _counts.length - 1,
                    label: '$_count',
                    onChanged: (double v) => setState(() {
                      _countIndex = v.round();
                      _expanded = null;
                    }),
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text('$_count', textAlign: TextAlign.end),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_status, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) => MorphOSField(
                spec: _lastSpec = _spec(c.maxWidth),
                fit: MorphFit.fitWidth,
                enableScroll: true,
                controller: _controller,
                images: _images,
                showPerfOverlay: _perf,
                effect: _sheen ? MorphEffect.sheen : MorphEffect.none,
                effectIntensity: 0.8,
                stagger: MorphStagger.fromPoint(
                  _rippleOrigin,
                  perHundredUnits: const Duration(milliseconds: 25),
                  max: const Duration(milliseconds: 450),
                ),
                onNodeTap: (Object id, int index) => setState(() {
                  final MorphFieldSpec? last = _lastSpec;
                  if (last != null) {
                    _rippleOrigin = last.nodes[index].centerIn(last.designSize);
                  }
                  _expanded = _expanded == id ? null : id;
                  _status = 'Tapped card $id';
                }),
                onNodeDragEnd: (Object id, Offset at, Offset v) => setState(
                  () => _status =
                      'Flicked card $id at ${v.distance.toStringAsFixed(0)} units/s',
                ),
                onAtlasError: (String key, Object error, StackTrace? stack) =>
                    setState(() => _status = 'Image $key failed: $error'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
