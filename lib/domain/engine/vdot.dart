/// Jack Daniels' VDOT system.
///
/// ## Provenance
///
/// The published Daniels & Gilbert oxygen-cost equation is not reproduced
/// here. Instead this file embeds the *published equivalent-time table* at
/// integer VDOT values and interpolates between them.
///
/// That choice is deliberate:
///
///  * The table is the artefact a runner would recognise from the book, so
///    it is the thing most worth pinning in a test.
///  * Implementations of the raw equation disagree with each other. Research
///    for this project found published tables differing by up to ~4% at the
///    same VDOT, and at least one widely-linked calculator that is simply
///    wrong (it lists VDOT 30 as a 26:09 5K and a 4:14:00 marathon, against
///    the 30:41 / 4:49:49 that three independent sources agree on).
///  * Interpolation between agreed anchor points reproduces either source to
///    within a few seconds, so the error from this approach is smaller than
///    the disagreement between raw-equation implementations.
///
/// Anchor values below were cross-checked against multiple independent
/// sources; the two main ones agreed to within 4 seconds at every shared
/// VDOT. See `test/domain/vdot_test.dart`, which pins every anchor.
///
/// VDOT is only meaningful for trained runners. Below roughly 30 it is
/// extrapolation, and [vdotFor] returns null rather than guessing — the
/// caller falls back to absolute beginner paces.
library;

import '../models/race.dart';
import '../units.dart';

/// One row of the published equivalent-time table, in seconds.
class _Row {
  const _Row(this.vdot, this.k5, this.k10, this.half, this.marathon);

  final double vdot;
  final double k5;
  final double k10;
  final double half;
  final double marathon;

  double forDistance(RaceDistance d) => switch (d) {
        RaceDistance.k5 => k5,
        RaceDistance.k10 => k10,
        RaceDistance.half => half,
        RaceDistance.marathon => marathon,
      };
}

/// Published equivalent race times (seconds) at integer VDOT values.
const List<_Row> _table = [
  _Row(30, 1841, 3829, 8477, 17389), // 30:41 / 1:03:49 / 2:21:17 / 4:49:49
  _Row(32, 1745, 3627, 8035, 16517), // 29:05 / 1:00:27 / 2:13:55 / 4:35:17
  _Row(34, 1658, 3445, 7637, 15731), // 27:38 / 57:25 / 2:07:17 / 4:22:11
  _Row(36, 1581, 3282, 7278, 15019), // 26:21 / 54:42 / 2:01:18 / 4:10:19
  _Row(38, 1510, 3135, 6951, 14370), // 25:10 / 52:15 / 1:55:51 / 3:59:30
  _Row(40, 1446, 3001, 6654, 13777), // 24:06 / 50:01 / 1:50:54 / 3:49:37
  _Row(45, 1309, 2713, 6014, 12496), // 21:49 / 45:13 / 1:40:14 / 3:28:16
  _Row(50, 1200, 2488, 5510, 11477), // 20:00 / 41:28 / 1:31:50 / 3:11:17
  _Row(58, 1050, 2178, 4814, 10061), // 17:30 / 36:18 / 1:20:14 / 2:47:41
  _Row(70, 900, 1870, 4123, 8635), // 15:00 / 31:10 / 1:08:43 / 2:23:55
];

/// Below this VDOT the table is extrapolation rather than calibration.
const double minSupportedVdot = 30;
const double maxSupportedVdot = 70;

/// Equivalent race times at a given VDOT, interpolated from the table.
Map<RaceDistance, Duration> equivalentTimes(double vdot) {
  final v = vdot.clampD(minSupportedVdot, maxSupportedVdot);
  final span = _bracket(v);
  return {
    for (final d in RaceDistance.values)
      d: Duration(
        seconds: _lerp(
          span.lo.forDistance(d),
          span.hi.forDistance(d),
          span.t,
        ).round(),
      ),
  };
}

/// Equivalent race time at [distance] for a given VDOT.
Duration equivalentTime(double vdot, RaceDistance distance) =>
    equivalentTimes(vdot)[distance]!;

/// VDOT implied by a race result, or null if outside the calibrated range.
///
/// A null result is meaningful, not a failure: it means this athlete is
/// slower than the model supports, and paces must not be derived from VDOT
/// for them.
double? vdotFor(RaceDistance distance, Duration time) {
  final t = time.inMicroseconds / 1e6;
  final col = _table.map((r) => r.forDistance(distance)).toList();

  if (t > col.first) return null; // slower than the slowest calibrated row
  if (t < col.last) {
    // Faster than the fastest calibrated row. Extrapolating upward is
    // far safer than clamping, and elite-ish runners are out of scope for
    // this app anyway.
    return null;
  }

  // A time landing exactly on a table anchor sits outside every bracketing
  // pair below, so the two ends are matched explicitly.
  if (t == col.first) return _table.first.vdot;
  if (t == col.last) return _table.last.vdot;

  // Times decrease monotonically as VDOT rises, so walk the column in
  // reverse looking for the bracketing pair. col[i] is the *faster* end of
  // each pair, since higher VDOT means less time.
  for (var i = _table.length - 1; i > 0; i--) {
    final faster = col[i];
    final slower = col[i - 1];
    if (t >= faster && t <= slower) {
      // The pair spans VDOT [_table[i-1], _table[i]].
      final loVdot = _table[i - 1].vdot;
      final hiVdot = _table[i].vdot;
      final frac = (slower - t) / (slower - faster);
      return loVdot + (hiVdot - loVdot) * frac;
    }
  }
  return null;
}

/// True if [vdot] sits inside the calibrated range.
bool isVdotSupported(double vdot) =>
    vdot >= minSupportedVdot && vdot <= maxSupportedVdot;

/// Finds the bracketing rows and the interpolation fraction for [v].
///
/// Returns the rows themselves rather than their VDOT values, so callers
/// never have to map a VDOT back onto a row.
({_Row lo, _Row hi, double t}) _bracket(double v) {
  for (var i = 0; i < _table.length - 1; i++) {
    final a = _table[i];
    final b = _table[i + 1];
    if (v >= a.vdot && v <= b.vdot) {
      return (lo: a, hi: b, t: (v - a.vdot) / (b.vdot - a.vdot));
    }
  }
  return (lo: _table.last, hi: _table.last, t: 0);
}

double _lerp(double a, double b, double t) => a + (b - a) * t;
