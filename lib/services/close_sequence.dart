/// Releases resources in order, retaining the failed step for an explicit retry.
/// Successful steps must never run again after their resources have been closed.
class CloseSequence {
  CloseSequence(List<Future<void> Function()> steps)
    : _steps = List.unmodifiable(steps);

  final List<Future<void> Function()> _steps;
  int _next = 0;
  Future<void>? _running;

  Future<void> run() => _running ??= _run().whenComplete(() {
    _running = null;
  });

  Future<void> _run() async {
    while (_next < _steps.length) {
      await _steps[_next]();
      _next++;
    }
  }
}
