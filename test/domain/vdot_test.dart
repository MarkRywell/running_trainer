import 'package:ai_running_trainer/domain/engine/vdot.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shared duration formatter for the domain tests.
String hms(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

Duration parse(String s) {
  final parts = s.split(':').map(int.parse).toList();
  return parts.length == 3
      ? Duration(hours: parts[0], minutes: parts[1], seconds: parts[2])
      : Duration(minutes: parts[0], seconds: parts[1]);
}

void main() {
  group('published Daniels table', () {
    // These are the anchor rows. If someone changes the table without
    // re-checking the source, this is the test that fails.
    const anchors = <(double, String, String, String, String)>[
      (30, '30:41', '1:03:49', '2:21:17', '4:49:49'),
      (32, '29:05', '1:00:27', '2:13:55', '4:35:17'),
      (34, '27:38', '57:25', '2:07:17', '4:22:11'),
      (36, '26:21', '54:42', '2:01:18', '4:10:19'),
      (38, '25:10', '52:15', '1:55:51', '3:59:30'),
      (40, '24:06', '50:01', '1:50:54', '3:49:37'),
      (45, '21:49', '45:13', '1:40:14', '3:28:16'),
      (50, '20:00', '41:28', '1:31:50', '3:11:17'),
      (58, '17:30', '36:18', '1:20:14', '2:47:41'),
      (70, '15:00', '31:10', '1:08:43', '2:23:55'),
    ];

    for (final a in anchors) {
      test('VDOT ${a.$1} matches published equivalencies', () {
        final t = equivalentTimes(a.$1);
        expect(hms(t[RaceDistance.k5]!), a.$2, reason: '5K');
        expect(hms(t[RaceDistance.k10]!), a.$3, reason: '10K');
        expect(hms(t[RaceDistance.half]!), a.$4, reason: 'half');
        expect(hms(t[RaceDistance.marathon]!), a.$5, reason: 'marathon');
      });
    }
  });

  group('equivalentTimes', () {
    test('is monotonic: higher VDOT means faster times at every distance', () {
      for (var v = minSupportedVdot; v < maxSupportedVdot; v += 0.5) {
        final now = equivalentTimes(v);
        final faster = equivalentTimes(v + 0.5);
        for (final d in RaceDistance.values) {
          expect(
            faster[d]!,
            lessThan(now[d]!),
            reason: 'VDOT $v -> ${v + 0.5} at ${d.label}',
          );
        }
      }
    });

    test('interpolates between anchors rather than snapping', () {
      // VDOT 42 sits between the 40 and 45 rows. Higher VDOT is faster, so
      // its marathon time is between the two, closer to 40 than to 45.
      final t = equivalentTimes(42);
      final at40 = equivalentTimes(40)[RaceDistance.marathon]!;
      final at45 = equivalentTimes(45)[RaceDistance.marathon]!;
      expect(t[RaceDistance.marathon]!, lessThan(at40));
      expect(t[RaceDistance.marathon]!, greaterThan(at45));
      // Two-fifths of the way across a 40->45 gap.
      final fraction =
          (at40 - t[RaceDistance.marathon]!).inSeconds /
              (at40 - at45).inSeconds;
      expect(fraction, closeTo(0.4, 0.05));
    });

    test('clamps outside the tabulated range', () {
      expect(
        equivalentTimes(10)[RaceDistance.marathon],
        equivalentTimes(minSupportedVdot)[RaceDistance.marathon],
      );
      expect(
        equivalentTimes(120)[RaceDistance.marathon],
        equivalentTimes(maxSupportedVdot)[RaceDistance.marathon],
      );
    });
  });

  group('vdotFor', () {
    test('round-trips every anchor', () {
      for (var v = minSupportedVdot; v <= maxSupportedVdot; v += 1) {
        for (final d in RaceDistance.values) {
          final back = vdotFor(d, equivalentTime(v, d));
          expect(back, isNotNull, reason: 'VDOT $v at ${d.label}');
          expect(back!, closeTo(v, 0.15), reason: 'VDOT $v at ${d.label}');
        }
      }
    });

    test('returns null for a result slower than the model supports', () {
      // Well past the VDOT 30 end of the table.
      expect(vdotFor(RaceDistance.marathon, const Duration(hours: 6)), isNull);
      expect(vdotFor(RaceDistance.k5, const Duration(minutes: 45)), isNull);
    });

    test('returns null for a result faster than the table covers', () {
      expect(vdotFor(RaceDistance.marathon, const Duration(hours: 2)), isNull);
    });

    test('a slower time always means a lower VDOT', () {
      for (final d in RaceDistance.values) {
        double? previous;
        for (var m = 20; m <= 300; m += 5) {
          final v = vdotFor(d, Duration(minutes: m));
          if (v == null) continue;
          if (previous != null) {
            expect(v, lessThan(previous), reason: '$d ${m}m');
          }
          previous = v;
        }
      }
    });
  });

  group('isVdotSupported', () {
    test('bounds match the table', () {
      expect(isVdotSupported(29.9), isFalse);
      expect(isVdotSupported(30), isTrue);
      expect(isVdotSupported(50), isTrue);
      expect(isVdotSupported(70), isTrue);
      expect(isVdotSupported(70.1), isFalse);
    });
  });
}
