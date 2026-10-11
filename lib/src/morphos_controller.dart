// Programmatic control of a MorphOSField: scrolling, queries and settle
// notifications. Built only on Flutter's own ChangeNotifier, so it works the
// same with setState, Provider, Riverpod, Bloc, GetX or anything else.

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// What a field render object exposes to a [MorphController].
abstract interface class MorphControllerHost {
  /// Current scroll offset in local pixels.
  double get controllerScrollOffset;

  /// Largest scroll offset.
  double get controllerMaxScrollOffset;

  /// Whether nodes or scrolling are still moving.
  bool get controllerIsAnimating;

  /// Jumps the scroll offset (clamped).
  void controllerJumpTo(double offset);

  /// Springs the scroll offset to [offset]; completes when it arrives.
  Future<void> controllerAnimateTo(double offset);

  /// Scroll offset that places node [id] at [alignment] in the viewport, or
  /// null if the node is not in the field.
  double? controllerOffsetForNode(Object id, double alignment);

  /// Node rectangle at rest, in the field's local coordinates.
  Rect? controllerNodeRect(Object id);

  /// Id of the top-most interactive node at [local], or null.
  Object? controllerNodeAt(Offset local);

  /// Completes the next time everything is at rest (immediately if already
  /// at rest).
  Future<void> controllerWhenSettled();
}

/// Drives and queries a `MorphOSField` from code.
///
/// ```dart
/// final controller = MorphController();
/// MorphOSField(spec: spec, controller: controller, enableScroll: true);
/// await controller.scrollToNode(42, alignment: 0.5);
/// ```
///
/// Listeners are notified when the scroll offset changes and when the field
/// comes to rest. A controller can be attached to one field at a time.
class MorphController extends ChangeNotifier {
  /// Creates a detached controller.
  MorphController();

  MorphControllerHost? _host;

  /// Whether a field is using this controller.
  bool get isAttached => _host != null;

  /// Connects a field. Called by the field; apps do not call this.
  void attach(MorphControllerHost host) {
    assert(
      _host == null || identical(_host, host),
      'A MorphController can only be attached to one MorphOSField at a time.',
    );
    _host = host;
  }

  /// Disconnects [host] if it is the attached field. Called by the field.
  void detach(MorphControllerHost host) {
    if (identical(_host, host)) _host = null;
  }

  /// Notifies listeners. Called by the field on scroll and settle.
  void notifyFieldChanged() => notifyListeners();

  MorphControllerHost get _attached {
    final MorphControllerHost? h = _host;
    if (h == null) {
      throw StateError('MorphController is not attached to a MorphOSField.');
    }
    return h;
  }

  /// Current scroll offset in local pixels (0 when detached).
  double get scrollOffset => _host?.controllerScrollOffset ?? 0;

  /// Largest scroll offset (0 when detached or not scrollable).
  double get maxScrollOffset => _host?.controllerMaxScrollOffset ?? 0;

  /// Whether nodes or the scroll position are still moving.
  bool get isAnimating => _host?.controllerIsAnimating ?? false;

  /// Moves the scroll offset immediately (clamped to the valid range).
  void jumpTo(double offset) => _attached.controllerJumpTo(offset);

  /// Springs the scroll offset to [offset]; completes on arrival (or when
  /// interrupted by a user drag or by the field going away).
  Future<void> animateTo(double offset) =>
      _attached.controllerAnimateTo(offset);

  /// Scrolls so node [id] sits at [alignment] in the viewport: 0 puts it at
  /// the start edge, 0.5 in the middle, 1 at the end edge. Returns false if
  /// the node is not in the field.
  Future<bool> scrollToNode(
    Object id, {
    double alignment = 0,
    bool animate = true,
  }) async {
    final MorphControllerHost h = _attached;
    final double? target = h.controllerOffsetForNode(id, alignment);
    if (target == null) return false;
    if (animate) {
      await h.controllerAnimateTo(target);
    } else {
      h.controllerJumpTo(target);
    }
    return true;
  }

  /// Where node [id] will be at rest, in the field's local coordinates
  /// (includes the current scroll offset), or null if it is not in the field.
  Rect? nodeRect(Object id) => _host?.controllerNodeRect(id);

  /// Id of the top-most interactive node under [localPosition], or null.
  Object? nodeAt(Offset localPosition) =>
      _host?.controllerNodeAt(localPosition);

  /// Completes when nodes and scrolling are at rest.
  Future<void> whenSettled() =>
      _host?.controllerWhenSettled() ?? Future<void>.value();
}
