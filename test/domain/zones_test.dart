import 'package:ai_running_trainer/domain/engine/zones.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/units.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // VDOT 50 marathon-equivalent pace is 3:11:17 over 42.1975 km, which is
  // 7:50/mi. Everything below is derived from that single anchor, which is
  // what makes the per-mile to per-kilometre conversion easy to get wrong.
  const vdot50MarathonPaceKm = 292; // 4:52/km == 7:50/mi

  group('pace derivation from a marathon-equivalent anchor', () {
    final paces = pacesFromMarathonPace(const Pace(vdot50MarathonPaceKm));

    test('threshold matches the published VDOT 50 value', () {
      // Cross-checked against published Daniels pace tables: threshold at
      // VDOT 50 is 4:15-4:16/km. A wrong per-mile conversion moves this by
      // more than a minute, so this is the guard on the whole conversion.
      expect(paces.threshold.secPerKm, inInclusiveRange(253, 257));
      expect(paces.threshold.format(), anyOf('4:13', '4:14', '4:15', '4:16', '4:17'));
    });

    test('easy and recovery fall inside the published easy band', () {
      // Published easy band for VDOT 50 runs roughly 4:54 to 5:53/km.
      expect(paces.easy.secPerKm, inInclusiveRange(294, 353));
      expect(paces.recovery.secPerKm, inInclusiveRange(294, 355));
    });

    test('recovery is slower than easy', () {
      expect(paces.recovery.secPerKm, greaterThan(paces.easy.secPerKm));
    });

    test('the five zones are strictly ordered slowest to fastest', () {
      expect(paces.recovery.secPerKm, greaterThan(paces.easy.secPerKm));
      expect(paces.easy.secPerKm, greaterThan(paces.marathon.secPerKm));
      expect(paces.marathon.secPerKm, greaterThan(paces.threshold.secPerKm));
      expect(paces.threshold.secPerKm, greaterThan(paces.interval.secPerKm));
      expect(paces.interval.secPerKm, greaterThan(paces.repetition.secPerKm));
    });

    test('offsets are the documented per-mile values', () {
      const perMile = 1.609344;
      int expected(int secPerMile) => (secPerMile / perMile).round();
      expect(paces.marathon.secPerKm, vdot50MarathonPaceKm);
      expect(
        paces.easy.secPerKm - paces.marathon.secPerKm,
        expected(ZoneOffset.easy),
      );
      expect(
        paces.recovery.secPerKm - paces.marathon.secPerKm,
        expected(ZoneOffset.recovery),
      );
      expect(
        paces.marathon.secPerKm - paces.threshold.secPerKm,
        expected(-ZoneOffset.threshold),
      );
    });
  });

  group('ordering is preserved for any anchor', () {
    test('across a wide range of marathon-equivalent paces', () {
      for (var mp = 200; mp <= 400; mp += 10) {
        final p = pacesFromMarathonPace(Pace(mp));
        expect(p.recovery.secPerKm, greaterThan(p.easy.secPerKm), reason: '$mp');
        expect(p.easy.secPerKm, greaterThan(p.marathon.secPerKm), reason: '$mp');
        expect(
          p.marathon.secPerKm,
          greaterThan(p.threshold.secPerKm),
          reason: '$mp',
        );
        expect(
          p.threshold.secPerKm,
          greaterThan(p.interval.secPerKm),
          reason: '$mp',
        );
        expect(
          p.interval.secPerKm,
          greaterThan(p.repetition.secPerKm),
          reason: '$mp',
        );
      }
    });

    test('a faster anchor makes every zone faster', () {
      final slow = pacesFromMarathonPace(const Pace(320));
      final fast = pacesFromMarathonPace(const Pace(280));
      for (final z in IntensityZone.values) {
        expect(fast.forZone(z).secPerKm, lessThan(slow.forZone(z).secPerKm),
            reason: z.label);
      }
    });
  });

  group('zoneAnchorPace', () {
    test('ignores the goal race pace and uses current fitness', () {
      // Changed deliberately. The goal used to be the preferred anchor, which
      // meant a stretch goal pulled the whole ladder up: a runner with a 52:25
      // 10K targeting 49:00 got threshold 12 s/km faster than they can sustain,
      // and the gaps between zones collapsed. See zone_anchor_regression_test.
      final anchor = zoneAnchorPace(
        goalDistance: RaceDistance.marathon,
        goalFinishTime: const Duration(hours: 3, minutes: 30),
        equivalentMarathonTime: const Duration(hours: 4),
        anchorRaceDistance: RaceDistance.k10,
        anchorRaceTime: const Duration(minutes: 50),
      );
      // 4:00:00 over 42.1975 km — fitness, not the 3:30 goal.
      expect(anchor.secPerKm, closeTo(341, 1));
    });

    test('a non-marathon goal is ignored too', () {
      final anchor = zoneAnchorPace(
        goalDistance: RaceDistance.k10,
        goalFinishTime: const Duration(minutes: 40),
        equivalentMarathonTime: const Duration(hours: 4),
        anchorRaceDistance: null,
        anchorRaceTime: null,
      );
      expect(anchor.secPerKm, closeTo(341, 1));
    });

    test('falls back to the anchor race when no marathon equivalent exists', () {
      // A stale-only race set. Previously a goal covered for this; now it must
      // not, so the anchor race does.
      final anchor = zoneAnchorPace(
        goalDistance: RaceDistance.k10,
        goalFinishTime: const Duration(minutes: 40),
        equivalentMarathonTime: null,
        anchorRaceDistance: RaceDistance.k10,
        anchorRaceTime: const Duration(minutes: 50),
      );
      expect(anchor.secPerKm, closeTo(300, 1)); // 50:00 / 10 km
    });

    test('falls back to the equivalent marathon time without a goal', () {
      final anchor = zoneAnchorPace(
        goalDistance: null,
        goalFinishTime: null,
        equivalentMarathonTime: const Duration(hours: 3),
        anchorRaceDistance: RaceDistance.k10,
        anchorRaceTime: const Duration(minutes: 45),
      );
      // 3:00:00 over 42.1975 km.
      expect(anchor.secPerKm, closeTo(256, 1));
    });

    test('falls back to the anchor race when no marathon equivalent exists', () {
      final anchor = zoneAnchorPace(
        goalDistance: null,
        goalFinishTime: null,
        equivalentMarathonTime: null,
        anchorRaceDistance: RaceDistance.k5,
        anchorRaceTime: const Duration(minutes: 25),
      );
      expect(anchor.secPerKm, closeTo(300, 1));
    });

    test('throws when there is nothing to anchor on', () {
      expect(
        () => zoneAnchorPace(
          goalDistance: null,
          goalFinishTime: null,
          equivalentMarathonTime: null,
          anchorRaceDistance: null,
          anchorRaceTime: null,
        ),
        throwsStateError,
      );
    });
  });

  test('Pace converts a duration and distance consistently', () {
    const p = Pace(300);
    // 5:00/km over 10 km is 50 minutes.
    expect(p.overDistance(10000).inSeconds, 3000);
    expect(
      Pace.fromDuration(const Duration(minutes: 50), 10000),
      const Pace(300),
    );
    // 4:52/km formats as expected.
    expect(const Pace(292).format(), '4:52');
  });
}
