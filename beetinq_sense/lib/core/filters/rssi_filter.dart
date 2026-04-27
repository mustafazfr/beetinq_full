import 'package:simple_kalman/simple_kalman.dart';
import 'rolling_median.dart';

class RssiFilter {
  final RollingMedian median;
  SimpleKalman kalman;

  final double _kalmanQ;
  final double _kalmanErrorMeasure;
  final double _kalmanErrorEstimate;

  double? lastMedian;
  double? lastKalman;

  RssiFilter({
    required int medianWindow,
    required double kalmanQ,
    required double kalmanErrorMeasure,
    required double kalmanErrorEstimate,
  })  : median = RollingMedian(window: medianWindow),
        _kalmanQ = kalmanQ,
        _kalmanErrorMeasure = kalmanErrorMeasure,
        _kalmanErrorEstimate = kalmanErrorEstimate,
        kalman = SimpleKalman(
          errorMeasure: kalmanErrorMeasure,
          errorEstimate: kalmanErrorEstimate,
          q: kalmanQ,
        );

  double apply(double rawRssi) {
    final med = median.add(rawRssi);
    lastMedian = med;

    final k = kalman.filtered(med);
    lastKalman = k;

    return k;
  }

  void reset() {
    median.clear();
    lastMedian = null;
    lastKalman = null;
    // SimpleKalman does not expose a reset method — recreate the instance
    // to clear stale internal state (error estimate, last value).
    kalman = SimpleKalman(
      errorMeasure: _kalmanErrorMeasure,
      errorEstimate: _kalmanErrorEstimate,
      q: _kalmanQ,
    );
  }
}
