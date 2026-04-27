class RollingMedian {
  final int window;
  final List<double> _buf = <double>[];

  RollingMedian({required this.window}) : assert(window >= 3 && window.isOdd);

  double add(double v) {
    _buf.add(v);
    if (_buf.length > window) _buf.removeAt(0);

    final sorted = List<double>.from(_buf)..sort();
    final mid = sorted.length ~/ 2;
    return sorted[mid];
  }

  void clear() => _buf.clear();
}
