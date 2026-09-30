/// Riegel's Running Formula (1977) — cross-distance time prediction.
///
/// T2 = T1 * (D2 / D1) ^ 1.06
///
/// The exponent is the published value and is uncontroversial. The formula is
/// invertible, so it also works backwards: given a marathon, infer the 10K.
library;

import 'dart:math' as math;

import '../models/race.dart';

/// Riegel's published fatigue exponent.
const double riegelExponent = 1.06;

/// Correction applied when extrapolating to a *longer* distance than the
/// anchor race.
///
/// Riegel is empirically optimistic here. Predicting a marathon from a 10K
/// tends to land 1–3 minutes too fast for a large share of runners, which
/// matters directly for this app: an optimistic prediction becomes a training
/// plan that is quietly too hard.
///
/// The correction scales with how far we are extrapolating, so a 10K → half
/// conversion (adjacent distances) is left alone while a 5K → marathon
/// conversion gets the full correction. Extending in the *shorter* direction
/// is left alone entirely, since Riegel is pessimistic there and that errs
/// safe.
///
/// This is a heuristic, not a published constant, and is deliberately exposed
/// as one so it can be tuned against real feedback. It is pinned by
/// `test/domain/riiegel_test.dart` so it cannot drift silently.
const double conservativeMarginSlope = 0.0047;

/// Below this distance ratio, no margin is applied.
const double noMarginRatio = 1.25;

/// Predicts the time to cover [target] given [anchor] at [time].
///
/// Applies the conservative margin to stretch-out predictions.
Duration predict({
  required RaceDistance anchor,
  required Duration time,
  required RaceDistance target,
  bool conservative = true,
}) {
  final raw = rawPrediction(
    anchorMetres: anchor.metres,
    anchorSeconds: time.inMicroseconds / 1e6,
    targetMetres: target.metres,
  );
  if (!conservative) return Duration(seconds: raw.round());
  final corrected = raw * conservativeMargin(anchor.metres, target.metres);
  return Duration(seconds: corrected.round());
}

/// Convenience wrapper taking a [RaceResult] as the anchor.
Duration predictFrom(
  RaceResult anchor, {
  required RaceDistance target,
  bool conservative = true,
}) =>
    predict(
      anchor: anchor.distance,
      time: anchor.time,
      target: target,
      conservative: conservative,
    );

/// The Riegel equation itself, exposed for tests and for callers that want
/// the uncorrected number.
double rawPrediction({
  required double anchorMetres,
  required double anchorSeconds,
  required double targetMetres,
}) {
  final ratio = targetMetres / anchorMetres;
  return anchorSeconds * math.pow(ratio, riegelExponent).toDouble();
}

/// The multiplicative slowdown applied when projecting from [fromMetres] to
/// [toMetres]. Returns 1.0 for shorter projections and near-neighbour
/// distances.
double conservativeMargin(double fromMetres, double toMetres) {
  final ratio = toMetres / fromMetres;
  if (ratio <= noMarginRatio) return 1.0;
  return 1 + conservativeMarginSlope * (ratio - 1);
}
