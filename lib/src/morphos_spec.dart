// Module 1: the topological field blueprint.
//
// A field is a flat list of nodes. Every node lives in a fixed-stride slot of
// a few contiguous typed-data buffers, so the solver, painter and hit tester
// walk plain memory instead of an object tree.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// How a node's image fills the node.
enum MorphImageFit {
  /// Keep the image's proportions and scale it to cover the whole node,
  /// cropping what overflows (like `BoxFit.cover`).
  cover,

  /// Stretch the image to exactly the node's size (like `BoxFit.fill`).
  fill,
}

/// Vertical placement of a node's text inside the node rectangle.
enum MorphTextVerticalAlign {
  /// Text starts at the top padding edge.
  top,

  /// Text block is centred vertically.
  center,

  /// Text ends at the bottom padding edge.
  bottom,

  /// The first line's alphabetic baseline sits on the node's vertical centre.
  firstBaseline,
}

/// Immutable description of one node in a [MorphFieldSpec].
///
/// Placement works like [Alignment] over the field's design size: the node's
/// centre is `anchor * (designSize - size) + size / 2 + position`. An anchor of
/// `(0, 0)` puts the node's top-left corner at the design origin, `(1, 1)` puts
/// its bottom-right corner at the far design corner, and [position] is an
/// extra offset in design units.
///
/// Motion is a damped spring: [elasticity] is the stiffness `k`, [mass] is
/// `m`, and [dampingRatio] is `ζ` (1 is critical, below 1 overshoots).
@immutable
class MorphNodeSpec {
  /// Creates a node description. Values are validated when the node is placed
  /// in a [MorphFieldSpec]; see [validate].
  const MorphNodeSpec({
    required this.id,
    required this.size,
    this.anchor = Offset.zero,
    this.position = Offset.zero,
    this.elasticity = 170,
    this.mass = 1,
    this.dampingRatio = 0.8,
    this.color = const Color(0xFF3D5AFE),
    this.darkColor,
    this.cornerRadius = 0,
    this.opacity = 1,
    this.rotation = 0,
    this.borderWidth = 0,
    this.borderColor = const Color(0x00000000),
    this.zIndex = 0,
    this.text,
    this.textStyle,
    this.textAlign = TextAlign.center,
    this.textVerticalAlign = MorphTextVerticalAlign.center,
    this.maxLines,
    this.ellipsis = '…',
    this.textPadding = 8,
    this.imageKey,
    this.imageTint = const Color(0xFFFFFFFF),
    this.imageFit = MorphImageFit.cover,
    this.semanticLabel,
    this.interactive = true,
    this.draggable = false,
  });

  /// Stable identity used to match nodes across spec updates. Must be unique
  /// within a field and implement `==`/`hashCode`.
  final Object id;

  /// Node size in design units.
  final Size size;

  /// Alignment-style anchor within the design size, usually in `[0, 1]`.
  final Offset anchor;

  /// Extra offset in design units, added after anchoring.
  final Offset position;

  /// Spring stiffness `k` (N/m in design units). Higher is snappier.
  final double elasticity;

  /// Spring mass `m`. Higher is heavier and slower.
  final double mass;

  /// Damping ratio `ζ`. 1 settles without overshoot; below 1 bounces.
  final double dampingRatio;

  /// Fill colour.
  final Color color;

  /// Fill colour used when the platform brightness is dark. Falls back to
  /// [color].
  final Color? darkColor;

  /// Corner radius in design units, clamped to half the shorter side.
  final double cornerRadius;

  /// Opacity in `[0, 1]`, applied to fill, border, image and text.
  final double opacity;

  /// Clockwise rotation in radians around the node centre.
  final double rotation;

  /// Border width in design units, drawn inside the node edge.
  final double borderWidth;

  /// Border colour.
  final Color borderColor;

  /// Paint order. Higher values draw on top; ties keep spec order.
  final int zIndex;

  /// Optional text drawn inside the node.
  final String? text;

  /// Style for [text]. Defaults to 14px white.
  final TextStyle? textStyle;

  /// Horizontal alignment of [text].
  final TextAlign textAlign;

  /// Vertical alignment of [text].
  final MorphTextVerticalAlign textVerticalAlign;

  /// Maximum number of text lines; `null` means unlimited (clipped to node).
  final int? maxLines;

  /// Ellipsis appended when [maxLines] truncates the text.
  final String? ellipsis;

  /// Inner padding between the node edge and its text, in design units.
  final double textPadding;

  /// Key of an image in the field's image atlas. When set and present, the
  /// node is textured with that image, tinted by [imageTint].
  final String? imageKey;

  /// Multiplier applied to the image texels.
  final Color imageTint;

  /// How the image fills the node. Defaults to [MorphImageFit.cover], so
  /// images keep their proportions in any node shape.
  final MorphImageFit imageFit;

  /// Accessibility label. Falls back to [text].
  final String? semanticLabel;

  /// Whether the node receives taps, hover and keyboard focus.
  final bool interactive;

  /// Whether the node can be dragged. A dragged node follows the pointer and
  /// springs back to its target (with fling momentum) on release unless the
  /// app moves it by supplying a new spec.
  final bool draggable;

  /// Maximum angular frequency `sqrt(k/m)` the fixed 1/240 s solver step keeps
  /// stable. Faster springs are rejected by [validate].
  static const double maxAngularFrequency = 220;

  /// The node's resolved centre in design space for [designSize].
  Offset centerIn(Size designSize) => Offset(
    anchor.dx * (designSize.width - size.width) + size.width / 2 + position.dx,
    anchor.dy * (designSize.height - size.height) +
        size.height / 2 +
        position.dy,
  );

  /// Checks every numeric property and throws [ArgumentError] naming the first
  /// invalid one.
  void validate() {
    void finite(double v, String name) {
      if (!v.isFinite) {
        throw ArgumentError.value(v, name, 'must be finite (node $id)');
      }
    }

    finite(size.width, 'size.width');
    finite(size.height, 'size.height');
    if (size.width < 0 || size.height < 0) {
      throw ArgumentError.value(
        size,
        'size',
        'must not be negative (node $id)',
      );
    }
    finite(anchor.dx, 'anchor.dx');
    finite(anchor.dy, 'anchor.dy');
    finite(position.dx, 'position.dx');
    finite(position.dy, 'position.dy');
    finite(elasticity, 'elasticity');
    finite(mass, 'mass');
    finite(dampingRatio, 'dampingRatio');
    if (mass <= 0) {
      throw ArgumentError.value(mass, 'mass', 'must be > 0 (node $id)');
    }
    if (elasticity <= 0) {
      throw ArgumentError.value(
        elasticity,
        'elasticity',
        'must be > 0 (node $id)',
      );
    }
    if (dampingRatio <= 0) {
      throw ArgumentError.value(
        dampingRatio,
        'dampingRatio',
        'must be > 0 (node $id)',
      );
    }
    // Compare squares so the common (valid) path needs no square root.
    final double omega2 = elasticity / mass;
    const double limit2 = maxAngularFrequency * maxAngularFrequency;
    if (omega2 > limit2 || omega2 * dampingRatio * dampingRatio > limit2) {
      final double omega = math.sqrt(omega2);
      throw ArgumentError(
        'Spring for node $id is too stiff for the 1/240 s solver step: '
        'sqrt(elasticity / mass) = ${omega.toStringAsFixed(1)} and '
        'sqrt(elasticity / mass) * dampingRatio must both be <= $maxAngularFrequency.',
      );
    }
    finite(cornerRadius, 'cornerRadius');
    if (cornerRadius < 0) {
      throw ArgumentError.value(
        cornerRadius,
        'cornerRadius',
        'must not be negative (node $id)',
      );
    }
    finite(opacity, 'opacity');
    if (opacity < 0 || opacity > 1) {
      throw ArgumentError.value(
        opacity,
        'opacity',
        'must be in [0, 1] (node $id)',
      );
    }
    finite(rotation, 'rotation');
    finite(borderWidth, 'borderWidth');
    if (borderWidth < 0) {
      throw ArgumentError.value(
        borderWidth,
        'borderWidth',
        'must not be negative (node $id)',
      );
    }
    finite(textPadding, 'textPadding');
    if (textPadding < 0) {
      throw ArgumentError.value(
        textPadding,
        'textPadding',
        'must not be negative (node $id)',
      );
    }
    if (maxLines != null && maxLines! < 1) {
      throw ArgumentError.value(
        maxLines,
        'maxLines',
        'must be >= 1 (node $id)',
      );
    }
  }

  /// Returns a copy with the given fields replaced.
  MorphNodeSpec copyWith({
    Object? id,
    Size? size,
    Offset? anchor,
    Offset? position,
    double? elasticity,
    double? mass,
    double? dampingRatio,
    Color? color,
    Color? darkColor,
    double? cornerRadius,
    double? opacity,
    double? rotation,
    double? borderWidth,
    Color? borderColor,
    int? zIndex,
    String? text,
    TextStyle? textStyle,
    TextAlign? textAlign,
    MorphTextVerticalAlign? textVerticalAlign,
    int? maxLines,
    String? ellipsis,
    double? textPadding,
    String? imageKey,
    Color? imageTint,
    MorphImageFit? imageFit,
    String? semanticLabel,
    bool? interactive,
    bool? draggable,
  }) {
    return MorphNodeSpec(
      id: id ?? this.id,
      size: size ?? this.size,
      anchor: anchor ?? this.anchor,
      position: position ?? this.position,
      elasticity: elasticity ?? this.elasticity,
      mass: mass ?? this.mass,
      dampingRatio: dampingRatio ?? this.dampingRatio,
      color: color ?? this.color,
      darkColor: darkColor ?? this.darkColor,
      cornerRadius: cornerRadius ?? this.cornerRadius,
      opacity: opacity ?? this.opacity,
      rotation: rotation ?? this.rotation,
      borderWidth: borderWidth ?? this.borderWidth,
      borderColor: borderColor ?? this.borderColor,
      zIndex: zIndex ?? this.zIndex,
      text: text ?? this.text,
      textStyle: textStyle ?? this.textStyle,
      textAlign: textAlign ?? this.textAlign,
      textVerticalAlign: textVerticalAlign ?? this.textVerticalAlign,
      maxLines: maxLines ?? this.maxLines,
      ellipsis: ellipsis ?? this.ellipsis,
      textPadding: textPadding ?? this.textPadding,
      imageKey: imageKey ?? this.imageKey,
      imageTint: imageTint ?? this.imageTint,
      imageFit: imageFit ?? this.imageFit,
      semanticLabel: semanticLabel ?? this.semanticLabel,
      interactive: interactive ?? this.interactive,
      draggable: draggable ?? this.draggable,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MorphNodeSpec &&
        other.id == id &&
        other.size == size &&
        other.anchor == anchor &&
        other.position == position &&
        other.elasticity == elasticity &&
        other.mass == mass &&
        other.dampingRatio == dampingRatio &&
        other.color == color &&
        other.darkColor == darkColor &&
        other.cornerRadius == cornerRadius &&
        other.opacity == opacity &&
        other.rotation == rotation &&
        other.borderWidth == borderWidth &&
        other.borderColor == borderColor &&
        other.zIndex == zIndex &&
        other.text == text &&
        other.textStyle == textStyle &&
        other.textAlign == textAlign &&
        other.textVerticalAlign == textVerticalAlign &&
        other.maxLines == maxLines &&
        other.ellipsis == ellipsis &&
        other.textPadding == textPadding &&
        other.imageKey == imageKey &&
        other.imageTint == imageTint &&
        other.imageFit == imageFit &&
        other.semanticLabel == semanticLabel &&
        other.interactive == interactive &&
        other.draggable == draggable;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
    id,
    size,
    anchor,
    position,
    elasticity,
    mass,
    dampingRatio,
    color,
    darkColor,
    cornerRadius,
    opacity,
    rotation,
    borderWidth,
    borderColor,
    zIndex,
    text,
    textStyle,
    textAlign,
    textVerticalAlign,
    maxLines,
    ellipsis,
    textPadding,
    imageKey,
    imageTint,
    imageFit,
    semanticLabel,
    interactive,
    draggable,
  ]);

  @override
  String toString() => 'MorphNodeSpec($id, $size @ anchor $anchor + $position)';
}

/// An immutable, validated field: a design coordinate space plus its nodes.
@immutable
class MorphFieldSpec {
  /// Creates a field and validates every node and id uniqueness.
  ///
  /// Throws [ArgumentError] on an empty or non-finite [designSize], an invalid
  /// node, or a duplicate id.
  MorphFieldSpec({required this.designSize, required List<MorphNodeSpec> nodes})
    : nodes = List<MorphNodeSpec>.unmodifiable(nodes) {
    if (!designSize.width.isFinite ||
        !designSize.height.isFinite ||
        designSize.width <= 0 ||
        designSize.height <= 0) {
      throw ArgumentError.value(
        designSize,
        'designSize',
        'must be finite and > 0',
      );
    }
    final Set<Object> seen = <Object>{};
    for (final MorphNodeSpec node in this.nodes) {
      node.validate();
      if (!seen.add(node.id)) {
        throw ArgumentError.value(node.id, 'nodes', 'duplicate node id');
      }
    }
  }

  // Already-validated nodes (used by [withNodes]); no per-node checks.
  const MorphFieldSpec._trusted(this.designSize, this.nodes);

  /// Returns a copy with [node] replacing the node that has the same id.
  ///
  /// Only [node] is validated, and every other node is shared with this spec,
  /// so applying the result only rewrites that one node. This is the cheap
  /// way to change one card in a big field.
  ///
  /// Throws [ArgumentError] if no node has that id, or if [node] is invalid.
  MorphFieldSpec withNode(MorphNodeSpec node) =>
      withNodes(<MorphNodeSpec>[node]);

  /// Returns a copy with each of [replacements] replacing the node that has
  /// the same id. See [withNode].
  MorphFieldSpec withNodes(Iterable<MorphNodeSpec> replacements) {
    final Map<Object, MorphNodeSpec> byId = <Object, MorphNodeSpec>{};
    for (final MorphNodeSpec node in replacements) {
      node.validate();
      if (byId.containsKey(node.id)) {
        throw ArgumentError.value(node.id, 'replacements', 'duplicate node id');
      }
      byId[node.id] = node;
    }
    if (byId.isEmpty) return this;
    int found = 0;
    final List<MorphNodeSpec> next = List<MorphNodeSpec>.of(nodes);
    for (int i = 0; i < next.length && found < byId.length; i++) {
      final MorphNodeSpec? replacement = byId[next[i].id];
      if (replacement != null) {
        next[i] = replacement;
        found++;
      }
    }
    if (found != byId.length) {
      final Set<Object> present = <Object>{
        for (final MorphNodeSpec n in nodes) n.id,
      };
      final Object missing = byId.keys.firstWhere(
        (Object id) => !present.contains(id),
      );
      throw ArgumentError.value(
        missing,
        'replacements',
        'no node with this id',
      );
    }
    return MorphFieldSpec._trusted(
      designSize,
      List<MorphNodeSpec>.unmodifiable(next),
    );
  }

  /// Lays [nodes] out as a grid [columns] wide inside a field [width] design
  /// units wide. Each node keeps its styling; its size, anchor and position are
  /// replaced. Row height is [itemHeight], or the cell width when omitted. The
  /// design height grows to fit every row (at least [minHeight]).
  factory MorphFieldSpec.grid({
    required double width,
    required int columns,
    required List<MorphNodeSpec> nodes,
    double gap = 12,
    EdgeInsets padding = const EdgeInsets.all(16),
    double? itemHeight,
    double minHeight = 1,
  }) {
    if (columns < 1) {
      throw ArgumentError.value(columns, 'columns', 'must be >= 1');
    }
    if (!width.isFinite || width <= 0) {
      throw ArgumentError.value(width, 'width', 'must be finite and > 0');
    }
    if (!gap.isFinite || gap < 0) {
      throw ArgumentError.value(gap, 'gap', 'must be finite and >= 0');
    }
    final double cellWidth =
        (width - padding.horizontal - gap * (columns - 1)) / columns;
    if (cellWidth <= 0) {
      throw ArgumentError(
        'Grid of $columns columns does not fit in width $width.',
      );
    }
    final double cellHeight = itemHeight ?? cellWidth;
    if (!cellHeight.isFinite || cellHeight <= 0) {
      throw ArgumentError.value(
        itemHeight,
        'itemHeight',
        'must be finite and > 0',
      );
    }
    final int rows = (nodes.length + columns - 1) ~/ columns;
    final double height = math.max(
      minHeight,
      padding.vertical + rows * cellHeight + math.max(0, rows - 1) * gap,
    );
    final List<MorphNodeSpec> placed = <MorphNodeSpec>[
      for (int i = 0; i < nodes.length; i++)
        nodes[i].copyWith(
          size: Size(cellWidth, cellHeight),
          anchor: Offset.zero,
          position: Offset(
            padding.left + (i % columns) * (cellWidth + gap),
            padding.top + (i ~/ columns) * (cellHeight + gap),
          ),
        ),
    ];
    return MorphFieldSpec(designSize: Size(width, height), nodes: placed);
  }

  /// Lays [nodes] out as a single vertical list of [itemHeight]-tall rows.
  factory MorphFieldSpec.list({
    required double width,
    required double itemHeight,
    required List<MorphNodeSpec> nodes,
    double gap = 8,
    EdgeInsets padding = const EdgeInsets.all(16),
    double minHeight = 1,
  }) => MorphFieldSpec.grid(
    width: width,
    columns: 1,
    nodes: nodes,
    gap: gap,
    padding: padding,
    itemHeight: itemHeight,
    minHeight: minHeight,
  );

  /// Stacks [nodes] around the centre of [designSize], each shifted by
  /// [step] from the previous one, later nodes on top. Node sizes are kept.
  factory MorphFieldSpec.stack({
    required Size designSize,
    required List<MorphNodeSpec> nodes,
    Offset step = const Offset(0, 10),
  }) {
    final double mid = (nodes.length - 1) / 2;
    final List<MorphNodeSpec> placed = <MorphNodeSpec>[
      for (int i = 0; i < nodes.length; i++)
        nodes[i].copyWith(
          anchor: const Offset(0.5, 0.5),
          position: step * (i - mid),
          zIndex: i,
        ),
    ];
    return MorphFieldSpec(designSize: designSize, nodes: placed);
  }

  /// The logical coordinate space that nodes are positioned in.
  final Size designSize;

  /// Nodes in spec order (the default paint order).
  final List<MorphNodeSpec> nodes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MorphFieldSpec &&
          other.designSize == designSize &&
          other.nodes.length == nodes.length &&
          listEquals(other.nodes, nodes);

  @override
  int get hashCode => Object.hash(designSize, Object.hashAll(nodes));

  @override
  String toString() =>
      'MorphFieldSpec(${nodes.length} nodes, design $designSize)';
}

/// Field offsets of the stride-12 layout slot.
///
/// Slot `i` starts at `i * 12`, computed as `(i << 3) + (i << 2)`.
/// Positions are node centres in design space.
abstract final class MorphLayout {
  /// Floats per node.
  static const int stride = 12;

  /// Anchor x (alignment fraction).
  static const int anchorX = 0;

  /// Anchor y (alignment fraction).
  static const int anchorY = 1;

  /// Extra offset x in design units.
  static const int posX = 2;

  /// Extra offset y in design units.
  static const int posY = 3;

  /// Spring stiffness `k`.
  static const int elasticity = 4;

  /// Spring mass `m`.
  static const int mass = 5;

  /// Animated centre x.
  static const int currentX = 6;

  /// Animated centre y.
  static const int currentY = 7;

  /// Target centre x.
  static const int targetX = 8;

  /// Target centre y.
  static const int targetY = 9;

  /// Animated width.
  static const int width = 10;

  /// Animated height.
  static const int height = 11;

  /// Start of slot [i].
  @pragma('vm:prefer-inline')
  static int base(int i) => (i << 3) + (i << 2);
}

/// Field offsets of the stride-24 auxiliary slot that holds everything the
/// stride-12 layout has no room for: velocities, size/presence targets,
/// visuals and stagger state.
abstract final class MorphAux {
  /// Floats per node.
  static const int stride = 24;

  /// Velocity x.
  static const int velX = 0;

  /// Velocity y.
  static const int velY = 1;

  /// Target width.
  static const int targetW = 2;

  /// Target height.
  static const int targetH = 3;

  /// Width velocity.
  static const int velW = 4;

  /// Height velocity.
  static const int velH = 5;

  /// Presence (0 = gone/scaled away, 1 = fully present).
  static const int presence = 6;

  /// Presence velocity.
  static const int velPresence = 7;

  /// Presence target (1 = entering/present, 0 = exiting).
  static const int presenceTarget = 8;

  /// Precomputed damping coefficient `c = 2ζ·sqrt(k·m)`.
  static const int damping = 9;

  /// Corner radius.
  static const int cornerRadius = 10;

  /// Opacity.
  static const int opacity = 11;

  /// Rotation in radians.
  static const int rotation = 12;

  /// Border width.
  static const int borderWidth = 13;

  /// Remaining stagger delay in seconds.
  static const int delay = 14;

  /// Paint order key.
  static const int zIndex = 15;

  /// Target x used while [delay] is running.
  static const int prevTargetX = 16;

  /// Target y used while [delay] is running.
  static const int prevTargetY = 17;

  /// Target width used while [delay] is running.
  static const int prevTargetW = 18;

  /// Target height used while [delay] is running.
  static const int prevTargetH = 19;

  /// Presence target used while [delay] is running.
  static const int prevPresenceTarget = 20;

  /// Bit flags, see [flagInteractive] and friends.
  static const int flags = 21;

  /// Image atlas slot, or -1.
  static const int atlasSlot = 22;

  /// Text padding.
  static const int textPadding = 23;

  /// Node accepts taps, hover and focus.
  static const int flagInteractive = 1;

  /// Node can be dragged.
  static const int flagDraggable = 2;

  /// Node is currently held by a drag.
  static const int flagDragging = 4;

  /// Node has text.
  static const int flagHasText = 8;

  /// Start of slot [i].
  @pragma('vm:prefer-inline')
  static int base(int i) => (i << 4) + (i << 3);
}

/// Contiguous storage for every node slot of a field.
///
/// Buffers grow (by doubling) only when a spec with more nodes is applied,
/// never during ticks or paints.
final class MorphFieldStore {
  /// Creates a store with room for [initialCapacity] nodes.
  MorphFieldStore([int initialCapacity = 16])
    : _capacity = math.max(1, initialCapacity) {
    _allocate(_capacity);
  }

  int _capacity;

  /// Number of live slots.
  int length = 0;

  /// Stride-12 layout buffer (see [MorphLayout]).
  late Float32List layout;

  /// Stride-24 auxiliary buffer (see [MorphAux]).
  late Float32List aux;

  /// Fill colour per slot (ARGB).
  late Int32List fillColors;

  /// Border colour per slot (ARGB).
  late Int32List borderColors;

  /// Image tint per slot (ARGB).
  late Int32List tintColors;

  /// Node id per slot.
  final List<Object?> ids = <Object?>[];

  /// Source spec per slot (text, style, labels).
  final List<MorphNodeSpec?> specs = <MorphNodeSpec?>[];

  /// Slots available without growing.
  int get capacity => _capacity;

  void _allocate(int cap) {
    layout = Float32List(cap * MorphLayout.stride);
    aux = Float32List(cap * MorphAux.stride);
    fillColors = Int32List(cap);
    borderColors = Int32List(cap);
    tintColors = Int32List(cap);
    ids.length = cap;
    specs.length = cap;
  }

  /// Grows every buffer to hold at least [nodes] slots, keeping contents.
  void ensureCapacity(int nodes) {
    if (nodes <= _capacity) return;
    int cap = _capacity;
    while (cap < nodes) {
      cap *= 2;
    }
    final Float32List oldLayout = layout;
    final Float32List oldAux = aux;
    final Int32List oldFill = fillColors;
    final Int32List oldBorder = borderColors;
    final Int32List oldTint = tintColors;
    _allocate(cap);
    layout.setRange(0, oldLayout.length, oldLayout);
    aux.setRange(0, oldAux.length, oldAux);
    fillColors.setRange(0, oldFill.length, oldFill);
    borderColors.setRange(0, oldBorder.length, oldBorder);
    tintColors.setRange(0, oldTint.length, oldTint);
    _capacity = cap;
  }

  /// Reallocates smaller buffers when fewer than a quarter of the slots are
  /// in use (called after spec changes, never per frame).
  void shrinkToFit() {
    if (length * 4 >= _capacity || _capacity <= 64) return;
    int cap = 16;
    while (cap < length * 2) {
      cap *= 2;
    }
    final Float32List oldLayout = layout;
    final Float32List oldAux = aux;
    final Int32List oldFill = fillColors;
    final Int32List oldBorder = borderColors;
    final Int32List oldTint = tintColors;
    final List<Object?> oldIds = List<Object?>.of(ids.take(length));
    final List<MorphNodeSpec?> oldSpecs = List<MorphNodeSpec?>.of(
      specs.take(length),
    );
    _allocate(cap);
    layout.setRange(0, length * MorphLayout.stride, oldLayout);
    aux.setRange(0, length * MorphAux.stride, oldAux);
    fillColors.setRange(0, length, oldFill);
    borderColors.setRange(0, length, oldBorder);
    tintColors.setRange(0, length, oldTint);
    for (int i = 0; i < length; i++) {
      ids[i] = oldIds[i];
      specs[i] = oldSpecs[i];
    }
    for (int i = length; i < cap; i++) {
      ids[i] = null;
      specs[i] = null;
    }
    _capacity = cap;
  }

  /// Copies [other]'s live slots into this store (growing if needed).
  void copyFrom(MorphFieldStore other) {
    ensureCapacity(other.length);
    final int n = other.length;
    layout.setRange(0, n * MorphLayout.stride, other.layout);
    aux.setRange(0, n * MorphAux.stride, other.aux);
    fillColors.setRange(0, n, other.fillColors);
    borderColors.setRange(0, n, other.borderColors);
    tintColors.setRange(0, n, other.tintColors);
    for (int i = 0; i < n; i++) {
      ids[i] = other.ids[i];
      specs[i] = other.specs[i];
    }
    length = n;
  }

  /// Copies slot [from] of [source] into slot [to] of this store.
  void copySlotFrom(MorphFieldStore source, int from, int to) {
    final int lf = MorphLayout.base(from), lt = MorphLayout.base(to);
    layout.setRange(lt, lt + MorphLayout.stride, source.layout, lf);
    final int af = MorphAux.base(from), at = MorphAux.base(to);
    aux.setRange(at, at + MorphAux.stride, source.aux, af);
    fillColors[to] = source.fillColors[from];
    borderColors[to] = source.borderColors[from];
    tintColors[to] = source.tintColors[from];
    ids[to] = source.ids[from];
    specs[to] = source.specs[from];
  }

  /// Clears id/spec references past [length] so dropped nodes can be
  /// garbage-collected.
  void releaseTail() {
    for (int i = length; i < _capacity; i++) {
      ids[i] = null;
      specs[i] = null;
    }
  }

  /// Animated centre of slot [i] in design space.
  Offset currentCenter(int i) {
    final int b = MorphLayout.base(i);
    return Offset(
      layout[b + MorphLayout.currentX],
      layout[b + MorphLayout.currentY],
    );
  }

  /// Target centre of slot [i] in design space.
  Offset targetCenter(int i) {
    final int b = MorphLayout.base(i);
    return Offset(
      layout[b + MorphLayout.targetX],
      layout[b + MorphLayout.targetY],
    );
  }

  /// Animated size of slot [i] in design units.
  Size currentSize(int i) {
    final int b = MorphLayout.base(i);
    return Size(layout[b + MorphLayout.width], layout[b + MorphLayout.height]);
  }

  /// Whether slot [i] has [flag] (a [MorphAux] flag bit) set.
  @pragma('vm:prefer-inline')
  bool hasFlag(int i, int flag) =>
      (aux[MorphAux.base(i) + MorphAux.flags].toInt() & flag) != 0;

  /// Sets or clears [flag] on slot [i].
  void setFlag(int i, int flag, bool on) {
    final int a = MorphAux.base(i) + MorphAux.flags;
    final int v = aux[a].toInt();
    aux[a] = (on ? (v | flag) : (v & ~flag)).toDouble();
  }

  /// FNV-1a checksum over the live layout and aux bytes. Two stores that went
  /// through the same commands produce the same value.
  int checksum() {
    int h = 0x811c9dc5;
    void mix(Float32List list, int count) {
      final Uint8List bytes = list.buffer.asUint8List(
        list.offsetInBytes,
        count * 4,
      );
      for (int i = 0; i < bytes.length; i++) {
        h ^= bytes[i];
        h = (h * 0x01000193) & 0xffffffff;
      }
    }

    mix(layout, length * MorphLayout.stride);
    mix(aux, length * MorphAux.stride);
    return h;
  }
}
