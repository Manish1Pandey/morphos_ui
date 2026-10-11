// Deterministic record/replay of solver commands.
//
// The solver integrates with a fixed step, so the same command sequence
// always yields bit-identical buffers. A recorder captures that sequence from
// a live field; replaying it into a fresh solver reproduces the exact state,
// which makes animation tests exact instead of tolerance-based.

import 'dart:ui' show Offset;

import 'morphos_solver.dart';
import 'morphos_spec.dart';

/// One recorded solver command.
sealed class MorphCommand {
  const MorphCommand();

  /// Re-executes the command on [solver].
  void applyTo(MorphFieldSolver solver);
}

/// A recorded `applySpec`.
final class MorphApplySpecCommand extends MorphCommand {
  /// Creates the command.
  const MorphApplySpecCommand(
    this.spec,
    this.stagger,
    this.animateEntryExit,
    this.dark, {
    this.mirror = false,
  });

  /// Applied spec.
  final MorphFieldSpec spec;

  /// Stagger used.
  final MorphStagger stagger;

  /// Whether entry/exit animated.
  final bool animateEntryExit;

  /// Whether dark colours were used.
  final bool dark;

  /// Whether the layout was mirrored for right-to-left.
  final bool mirror;

  @override
  void applyTo(MorphFieldSolver solver) => solver.applySpec(
    spec,
    stagger: stagger,
    animateEntryExit: animateEntryExit,
    brightnessDark: dark,
    mirror: mirror,
  );
}

/// A recorded `step`.
final class MorphStepCommand extends MorphCommand {
  /// Creates the command.
  const MorphStepCommand(this.dt);

  /// Seconds advanced.
  final double dt;

  @override
  void applyTo(MorphFieldSolver solver) => solver.step(dt);
}

/// A recorded `beginDrag`.
final class MorphBeginDragCommand extends MorphCommand {
  /// Creates the command.
  const MorphBeginDragCommand(this.id);

  /// Dragged node.
  final Object id;

  @override
  void applyTo(MorphFieldSolver solver) => solver.beginDrag(id);
}

/// A recorded `dragBy`.
final class MorphDragByCommand extends MorphCommand {
  /// Creates the command.
  const MorphDragByCommand(this.id, this.delta);

  /// Dragged node.
  final Object id;

  /// Design-space delta.
  final Offset delta;

  @override
  void applyTo(MorphFieldSolver solver) => solver.dragBy(id, delta);
}

/// A recorded `endDrag`.
final class MorphEndDragCommand extends MorphCommand {
  /// Creates the command.
  const MorphEndDragCommand(this.id, this.velocity);

  /// Released node.
  final Object id;

  /// Release velocity, design units per second.
  final Offset velocity;

  @override
  void applyTo(MorphFieldSolver solver) => solver.endDrag(id, velocity);
}

/// A recorded reduced-motion switch.
final class MorphReduceMotionCommand extends MorphCommand {
  /// Creates the command.
  const MorphReduceMotionCommand(this.value);

  /// New value.
  final bool value;

  @override
  void applyTo(MorphFieldSolver solver) => solver.reduceMotion = value;
}

/// Records every solver command of a field (attach via
/// `MorphOSField.recorder` or [MorphFieldSolver.observer]) and replays them.
final class MorphRecorder implements MorphSolverObserver {
  /// Creates an empty recorder.
  MorphRecorder();

  final List<MorphCommand> _commands = <MorphCommand>[];

  /// Recorded commands in order.
  List<MorphCommand> get commands => List<MorphCommand>.unmodifiable(_commands);

  /// Whether recording is on.
  bool recording = true;

  /// Clears the log.
  void clear() => _commands.clear();

  void _add(MorphCommand c) {
    if (recording) _commands.add(c);
  }

  @override
  void onApplySpec(
    MorphFieldSpec spec,
    MorphStagger stagger, {
    required bool animateEntryExit,
    required bool brightnessDark,
    required bool mirror,
  }) => _add(
    MorphApplySpecCommand(
      spec,
      stagger,
      animateEntryExit,
      brightnessDark,
      mirror: mirror,
    ),
  );

  @override
  void onStep(double dt) => _add(MorphStepCommand(dt));

  @override
  void onBeginDrag(Object id) => _add(MorphBeginDragCommand(id));

  @override
  void onDragBy(Object id, Offset delta) => _add(MorphDragByCommand(id, delta));

  @override
  void onEndDrag(Object id, Offset velocity) =>
      _add(MorphEndDragCommand(id, velocity));

  @override
  void onReduceMotion(bool value) => _add(MorphReduceMotionCommand(value));

  /// Replays the log into a fresh solver and returns it.
  MorphFieldSolver replay() {
    final MorphFieldSolver solver = MorphFieldSolver();
    for (final MorphCommand c in _commands) {
      c.applyTo(solver);
    }
    return solver;
  }
}
