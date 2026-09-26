/// The autosave plumbing behind the wizard.
///
/// A draft is created at step 1 and every field the operator touches is written straight back, so
/// a dropped 4G connection or a locked phone never costs a half-filled specification. Two things
/// make that safe rather than chatty:
///
///  * **Coalescing per field.** Typing "Solitaire Crown" is fourteen keystrokes and one write.
///    Each field owns a key; a newer edit to the same key cancels the pending one.
///  * **Serialising across fields.** Writes run one after another, so an upsert of
///    `product_specs` cannot overtake the one before it and resurrect a value the operator
///    already changed.
///
/// [SaveQueue.flush] exists for the moment the operator presses Continue: every pending edit is
/// fired immediately and awaited, so a step is never left with a debounce still in the air.
library;

import 'dart:async';

/// How long to sit on an edit before writing it.
abstract final class SaveDelay {
  /// A discrete choice — a tile, a chip, a toggle. There is no second keystroke coming.
  static const immediate = Duration.zero;

  /// Text and numbers being typed.
  static const typing = Duration(milliseconds: 700);

  /// A slider or stepper being dragged.
  static const dragging = Duration(milliseconds: 350);
}

final class SaveQueue {
  final Map<String, Timer> _timers = <String, Timer>{};
  final Map<String, Future<void> Function()> _pending = <String, Future<void> Function()>{};

  /// The tail of the serialised chain. Always non-null so `then` has something to hang off.
  Future<void> _chain = Future<void>.value();

  bool _closed = false;

  bool get hasPending => _timers.isNotEmpty;

  /// Queue [task] under [key], replacing anything already waiting under the same key.
  void schedule(String key, Duration delay, Future<void> Function() task) {
    if (_closed) return;
    _timers.remove(key)?.cancel();
    _pending[key] = task;
    if (delay <= Duration.zero) {
      _fire(key);
      return;
    }
    _timers[key] = Timer(delay, () => _fire(key));
  }

  void _fire(String key) {
    _timers.remove(key);
    final task = _pending.remove(key);
    if (task == null || _closed) return;
    // Failures are reported by the task itself, into the save badge. Swallowing here keeps one
    // failed write from poisoning every write queued behind it.
    _chain = _chain.then((_) => task()).catchError((Object _) {});
  }

  void _fireAll() {
    for (final key in _timers.keys.toList(growable: false)) {
      _timers.remove(key)?.cancel();
      _fire(key);
    }
  }

  /// Write everything still waiting, and wait for it. Called before every step change and before
  /// commit, because "Continue" must mean the step is on the server.
  Future<void> flush() async {
    // A task can schedule another (a purity reconcile follows a base-metal change), so settle in
    // rounds rather than once. The bound stops a pathological loop from hanging the button.
    for (var round = 0; round < 8; round++) {
      _fireAll();
      final chain = _chain;
      await chain;
      if (_timers.isEmpty && identical(chain, _chain)) return;
    }
  }

  void dispose() {
    _closed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _pending.clear();
  }
}
