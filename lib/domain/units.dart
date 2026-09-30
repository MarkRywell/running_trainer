/// Unit handling and formatting for the domain layer.
///
/// Everything is stored in SI (metres, [Duration]). Pace is canonically
/// expressed in whole seconds per kilometre and converted only at the
/// display edge.
library;

/// A running pace, canonically stored as whole seconds per kilometre.
class Pace implements Comparable<Pace> {
  const Pace(this.secPerKm);

  /// Builds a pace from a duration over a distance.
  factory Pace.fromDuration(Duration duration, double metres) {
    if (metres <= 0) {
      throw ArgumentError.value(metres, 'metres', 'must be positive');
    }
    return Pace((duration.inMicroseconds / 1e6 / (metres / 1000)).round());
  }

  final int secPerKm;

  /// Pace in seconds per mile.
  double get secPerMile => secPerKm * 1.609344;

  /// Duration needed to cover [metres] at this pace.
  Duration overDistance(double metres) =>
      Duration(milliseconds: ((metres / 1000) * secPerKm * 1000).round());

  Pace operator *(double factor) =>
      Pace((secPerKm * factor).round());

  Pace operator /(double divisor) =>
      Pace((secPerKm / divisor).round());

  /// e.g. `5:24` for a 5:24/km pace.
  String format() {
    final m = secPerKm ~/ 60;
    final s = secPerKm % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// A slower pace. [seconds] more seconds per kilometre.
  Pace plusSeconds(int seconds) => Pace(secPerKm + seconds);

  /// A faster pace. [seconds] fewer seconds per kilometre.
  Pace minusSeconds(int seconds) => Pace(secPerKm - seconds);

  /// Slower zones have larger secPerKm, so natural ordering is reversed.
  @override
  int compareTo(Pace other) => other.secPerKm.compareTo(secPerKm);

  @override
  bool operator ==(Object other) =>
      other is Pace && other.secPerKm == secPerKm;

  @override
  int get hashCode => secPerKm.hashCode;

  @override
  String toString() => 'Pace($secPerKm s/km)';
}

/// Formats a duration as `h:mm:ss` when it has hours, else `m:ss`.
String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) return '$h:${_twoDigits(m)}:${_twoDigits(s)}';
  return '$m:${_twoDigits(s)}';
}

String _twoDigits(int n) => n.toString().padLeft(2, '0');

/// Formats a duration as a time *input*, which omits a leading zero hour.
///
/// Distinct from [formatDuration], which is for display: a runner types `1:45:00`
/// for a half marathon, not `01:45:00`.
String formatTimeInput(Duration d) {
  final h = d.inHours;
  if (h > 0) {
    return '$h:${_twoDigits(d.inMinutes.remainder(60))}:'
        '${_twoDigits(d.inSeconds.remainder(60))}';
  }
  return '${d.inMinutes.remainder(60)}:${_twoDigits(d.inSeconds.remainder(60))}';
}

/// Parses `h:mm:ss` or `mm:ss`, returning null for anything unparseable.
///
/// Null rather than a throw or a zero, because every caller wants "not supplied
/// yet" — a half-typed finish time must read as absent, not as a 0:00 race.
Duration? parseTimeInput(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  final parts = <int>[];
  for (final piece in s.split(':')) {
    final v = int.tryParse(piece.trim());
    if (v == null) return null;
    parts.add(v);
  }
  if (parts.length == 3) {
    return Duration(hours: parts[0], minutes: parts[1], seconds: parts[2]);
  }
  if (parts.length == 2) {
    return Duration(minutes: parts[0], seconds: parts[1]);
  }
  return null;
}

String formatDate(DateTime d) => '${d.day}/${d.month}/${d.year}';

/// Formats a distance in km, trimming a trailing `.0`.
String formatKm(double km) {
  if (km == km.roundToDouble()) return '${km.round()}';
  return km.toStringAsFixed(1);
}

extension DoubleClamp on double {
  /// `num.clamp` returns `num`, which forces a cast at every call site.
  /// This keeps distance arithmetic in `double` end to end.
  double clampD(double lo, double hi) => this < lo ? lo : (this > hi ? hi : this);
}

extension IntClamp on int {
  int clampI(int lo, int hi) => this < lo ? lo : (this > hi ? hi : this);
}

