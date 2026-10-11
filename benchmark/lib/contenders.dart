// The four ways of animating N cards between a grid and a list that the
// benchmark compares. Every contender draws the same cards: a rounded
// rectangle (radius 4) in one of seven colours, with its index as text when
// there are at most 1,000 cards.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/components.dart';
import 'package:flame/effects.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:morphos_ui/morphos_ui.dart';

/// Width of the benchmark area in logical pixels.
const double kWidth = 400;

/// Cards show text only up to this count (text dominates beyond it).
const int kTextLimit = 1000;

/// Which implementation to run.
enum Contender {
  /// morphos_ui, default shapes paint mode.
  morphos,

  /// morphos_ui, batched drawVertices paint mode.
  morphosVertices,

  /// Stack of AnimatedPositioned + DecoratedBox + Text.
  widgets,

  /// Hand-written CustomPainter with the same spring physics as morphos_ui.
  painter,

  /// Flame components animated with Flame effects.
  flame,
}

/// Grid (or list) cell rectangles for [n] cards.
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

/// Total content height for [n] cards.
double contentHeight(int n, bool grid) {
  final List<Rect> r = cells(n, grid);
  return r.isEmpty ? 1 : r.last.bottom + 4;
}

/// Card colour [i].
Color cardColor(int i) => Color(0xFF3D5AFE + (i % 7) * 0x1100);

const TextStyle _textStyle = TextStyle(fontSize: 9, color: Colors.white);

/// Hosts one contender and toggles it between grid and list.
class Bench extends StatefulWidget {
  /// Creates the bench.
  const Bench({super.key, required this.contender, required this.count});

  /// Implementation under test.
  final Contender contender;

  /// Number of cards.
  final int count;

  @override
  State<Bench> createState() => BenchState();
}

/// State of [Bench]; [toggle] switches layouts.
class BenchState extends State<Bench> {
  bool _grid = true;
  int _nudge = 0;
  MorphFieldSpec? _spec;
  bool? _specGrid;

  /// Switches between grid and list.
  void toggle() => setState(() => _grid = !_grid);

  /// Moves card 0 a little (alternating right and back), leaving every other
  /// card where it is: the "one thing changed in a big field" case.
  void nudgeOne() => setState(() => _nudge++);

  /// Horizontal offset of card 0 for the current nudge count.
  double get _nudgeDx => _nudge.isOdd ? 30 : 0;

  MorphFieldSpec _morphSpec(int n) {
    // Rebuild the whole spec only when the layout changes; a nudge replaces
    // one node with withNode, as an app editing one card would.
    if (_spec == null || _specGrid != _grid) {
      final List<Rect> r = cells(n, _grid);
      _spec = MorphFieldSpec(
        designSize: Size(kWidth, contentHeight(n, _grid)),
        nodes: <MorphNodeSpec>[
          for (int i = 0; i < n; i++)
            MorphNodeSpec(
              id: i,
              size: r[i].size,
              position:
                  r[i].topLeft + (i == 0 ? Offset(_nudgeDx, 0) : Offset.zero),
              cornerRadius: 4,
              color: cardColor(i),
              text: n <= kTextLimit ? '$i' : null,
              textStyle: _textStyle,
            ),
        ],
      );
      _specGrid = _grid;
    }
    final MorphNodeSpec first = _spec!.nodes[0];
    final Offset want = cells(1, _grid)[0].topLeft + Offset(_nudgeDx, 0);
    if (first.position != want) {
      _spec = _spec!.withNode(first.copyWith(position: want));
    }
    return _spec!;
  }

  @override
  Widget build(BuildContext context) {
    final int n = widget.count;
    switch (widget.contender) {
      case Contender.morphos:
      case Contender.morphosVertices:
        return MorphOSField(
          paintMode: widget.contender == Contender.morphos
              ? MorphPaintMode.shapes
              : MorphPaintMode.vertices,
          fit: MorphFit.fitWidth,
          enableScroll: true,
          spec: _morphSpec(n),
        );
      case Contender.widgets:
        final List<Rect> r = cells(n, _grid);
        return SingleChildScrollView(
          child: SizedBox(
            width: kWidth,
            height: contentHeight(n, _grid),
            child: Stack(
              children: <Widget>[
                for (int i = 0; i < n; i++)
                  AnimatedPositioned(
                    key: ValueKey<int>(i),
                    duration: const Duration(milliseconds: 700),
                    curve: Curves.easeOutBack,
                    left: r[i].left + (i == 0 ? _nudgeDx : 0),
                    top: r[i].top,
                    width: r[i].width,
                    height: r[i].height,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: cardColor(i),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: n <= kTextLimit
                          ? Center(child: Text('$i', style: _textStyle))
                          : null,
                    ),
                  ),
              ],
            ),
          ),
        );
      case Contender.painter:
        return SpringPainterBench(count: n, grid: _grid, nudgeDx: _nudgeDx);
      case Contender.flame:
        return FlameBench(count: n, grid: _grid, nudgeDx: _nudgeDx);
    }
  }
}

// ---------------------------------------------------------------- painter

/// Hand-written alternative: one CustomPainter, the same spring as
/// morphos_ui (k 170, mass 1, damping ratio 0.8, fixed 1/240 s steps),
/// repainting through a listenable without rebuilding widgets.
class SpringPainterBench extends StatefulWidget {
  /// Creates the painter bench.
  const SpringPainterBench({
    super.key,
    required this.count,
    required this.grid,
    this.nudgeDx = 0,
  });

  /// Extra x offset for card 0.
  final double nudgeDx;

  /// Number of cards.
  final int count;

  /// Grid or list.
  final bool grid;

  @override
  State<SpringPainterBench> createState() => _SpringPainterBenchState();
}

class _SpringPainterBenchState extends State<SpringPainterBench>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _Repaint _repaint = _Repaint();
  late Float64List _cur, _vel, _tgt; // x, y, w, h per card
  late final List<TextPainter?> _text;
  Duration _last = Duration.zero;
  double _acc = 0;

  static const double _k = 170;
  static final double _c = 2 * 0.8 * math.sqrt(170);
  static const double _h = 1 / 240;

  @override
  void initState() {
    super.initState();
    final int n = widget.count;
    _cur = Float64List(n * 4);
    _vel = Float64List(n * 4);
    _tgt = Float64List(n * 4);
    _setTargets(widget.grid);
    _cur.setAll(0, _tgt);
    _text = <TextPainter?>[
      for (int i = 0; i < n; i++)
        n <= kTextLimit
            ? (TextPainter(
                text: TextSpan(text: '$i', style: _textStyle),
                textDirection: TextDirection.ltr,
              )..layout())
            : null,
    ];
  }

  void _setTargets(bool grid) {
    final List<Rect> r = cells(widget.count, grid);
    for (int i = 0; i < r.length; i++) {
      _tgt[i * 4] = r[i].left + (i == 0 ? widget.nudgeDx : 0);
      _tgt[i * 4 + 1] = r[i].top;
      _tgt[i * 4 + 2] = r[i].width;
      _tgt[i * 4 + 3] = r[i].height;
    }
  }

  @override
  void didUpdateWidget(SpringPainterBench old) {
    super.didUpdateWidget(old);
    if (old.grid != widget.grid || old.nudgeDx != widget.nudgeDx) {
      _setTargets(widget.grid);
      if (!_ticker.isActive) {
        _last = Duration.zero;
        _ticker.start();
      }
    }
  }

  void _tick(Duration elapsed) {
    final double dt = math.min(1 / 30, (elapsed - _last).inMicroseconds / 1e6);
    _last = elapsed;
    _acc += dt;
    while (_acc >= _h) {
      for (int i = 0; i < _cur.length; i++) {
        final double v =
            _vel[i] + (-_k * (_cur[i] - _tgt[i]) - _c * _vel[i]) * _h;
        _vel[i] = v;
        _cur[i] += v * _h;
      }
      _acc -= _h;
    }
    bool moving = false;
    for (int i = 0; i < _cur.length; i++) {
      if ((_cur[i] - _tgt[i]).abs() > 0.01 || _vel[i].abs() > 0.05) {
        moving = true;
        break;
      }
    }
    if (!moving) {
      _cur.setAll(0, _tgt);
      _vel.fillRange(0, _vel.length, 0);
      _ticker.stop();
    }
    _repaint.ping();
  }

  @override
  void dispose() {
    _ticker.dispose();
    for (final TextPainter? t in _text) {
      t?.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: CustomPaint(
        size: Size(
          kWidth,
          math.max(
            contentHeight(widget.count, true),
            contentHeight(widget.count, false),
          ),
        ),
        painter: _CardsPainter(_cur, _text, _repaint),
      ),
    );
  }
}

class _Repaint extends ChangeNotifier {
  void ping() => notifyListeners();
}

class _CardsPainter extends CustomPainter {
  _CardsPainter(this.cur, this.text, Listenable repaint)
    : super(repaint: repaint);

  final Float64List cur;
  final List<TextPainter?> text;
  final Paint _paint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < text.length; i++) {
      final double x = cur[i * 4], y = cur[i * 4 + 1];
      final double w = cur[i * 4 + 2], h = cur[i * 4 + 3];
      _paint.color = cardColor(i);
      canvas.drawRRect(
        RRect.fromLTRBR(x, y, x + w, y + h, const Radius.circular(4)),
        _paint,
      );
      final TextPainter? t = text[i];
      if (t != null) {
        t.paint(canvas, Offset(x + (w - t.width) / 2, y + (h - t.height) / 2));
      }
    }
  }

  @override
  bool shouldRepaint(_CardsPainter old) => false;
}

// ------------------------------------------------------------------ flame

/// Flame alternative: one component per card, moved and resized with
/// Flame's own effects (700 ms, easeOutBack, like the widget version).
class FlameBench extends StatefulWidget {
  /// Creates the Flame bench.
  const FlameBench({
    super.key,
    required this.count,
    required this.grid,
    this.nudgeDx = 0,
  });

  /// Extra x offset for card 0.
  final double nudgeDx;

  /// Number of cards.
  final int count;

  /// Grid or list.
  final bool grid;

  @override
  State<FlameBench> createState() => _FlameBenchState();
}

class _FlameBenchState extends State<FlameBench> {
  late final _CardsGame _game = _CardsGame(widget.count, widget.grid);

  @override
  void didUpdateWidget(FlameBench old) {
    super.didUpdateWidget(old);
    if (old.grid != widget.grid) {
      _game.layoutCards(widget.grid, widget.nudgeDx);
    } else if (old.nudgeDx != widget.nudgeDx) {
      _game.nudgeFirst(widget.grid, widget.nudgeDx);
    }
  }

  @override
  Widget build(BuildContext context) => GameWidget<_CardsGame>(game: _game);
}

class _CardsGame extends FlameGame {
  _CardsGame(this.count, this.grid);

  final int count;
  final bool grid;
  final List<_CardComponent> _cards = <_CardComponent>[];

  @override
  Color backgroundColor() => const Color(0x00000000);

  @override
  Future<void> onLoad() async {
    final List<Rect> r = cells(count, grid);
    for (int i = 0; i < count; i++) {
      final _CardComponent c = _CardComponent(i, count <= kTextLimit)
        ..position = Vector2(r[i].left, r[i].top)
        ..size = Vector2(r[i].width, r[i].height);
      _cards.add(c);
    }
    await addAll(_cards);
  }

  void nudgeFirst(bool grid, double dx) {
    if (_cards.isEmpty) return;
    final Rect r = cells(1, grid)[0];
    final _CardComponent c = _cards[0];
    c.removeAll(c.children.whereType<Effect>());
    c.add(
      MoveToEffect(
        Vector2(r.left + dx, r.top),
        EffectController(duration: 0.7, curve: Curves.easeOutBack),
      ),
    );
  }

  void layoutCards(bool grid, double dx) {
    final List<Rect> r = cells(count, grid);
    for (int i = 0; i < _cards.length; i++) {
      final _CardComponent c = _cards[i];
      c.removeAll(c.children.whereType<Effect>());
      c.add(
        MoveToEffect(
          Vector2(r[i].left + (i == 0 ? dx : 0), r[i].top),
          EffectController(duration: 0.7, curve: Curves.easeOutBack),
        ),
      );
      c.add(
        SizeEffect.to(
          Vector2(r[i].width, r[i].height),
          EffectController(duration: 0.7, curve: Curves.easeOutBack),
        ),
      );
    }
  }
}

class _CardComponent extends PositionComponent {
  _CardComponent(int index, bool withText)
    : _paint = Paint()..color = cardColor(index),
      _text = withText
          ? (TextPainter(
              text: TextSpan(text: '$index', style: _textStyle),
              textDirection: TextDirection.ltr,
            )..layout())
          : null;

  final Paint _paint;
  final TextPainter? _text;

  @override
  void render(Canvas canvas) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(size.toRect(), const Radius.circular(4)),
      _paint,
    );
    final TextPainter? t = _text;
    if (t != null) {
      t.paint(canvas, Offset((size.x - t.width) / 2, (size.y - t.height) / 2));
    }
  }

  @override
  void onRemove() {
    _text?.dispose();
    super.onRemove();
  }
}
