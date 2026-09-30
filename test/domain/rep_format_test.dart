/// Rep formats, and the two ways the app used to make them unreachable.
///
/// Every assertion here is about output the runner reads. A rep format that is
/// merely *representable* — a field on the model, a function that solves one —
/// is not the same as a plan that contains it, and the two failures below were
/// both invisible to the whole suite: the plans generated, every volume
/// invariant passed, and the runner was simply handed twelve tempos.
library;

import 'package:ai_running_trainer/domain/engine/fitness.dart';
import 'package:ai_running_trainer/domain/engine/validation.dart';
import 'package:ai_running_trainer/domain/engine/vdot.dart';
import 'package:ai_running_trainer/domain/engine/volume.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/plan_directive.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/plan/beginner_plan.dart';
import 'package:ai_running_trainer/domain/plan/generate.dart';
import 'package:ai_running_trainer/domain/plan/race_plan.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

/// The reported case: 45 km a week, four days, no race on the calendar.
RunnerProfile _noGoalRunner({double km = 45, int days = 4}) =>
    RunnerProfile(
      name: 'Sam',
      age: 34,
      gender: Gender.preferNotToSay,
      monthsRunning: 36,
      daysPerWeek: days,
      estimatedWeeklyKm: km,
    );

List<RaceResult> _races() => [raceK10(const Duration(minutes: 45))];

TrainingPlan _noGoalPlan({double km = 45, int days = 4}) => generate(
      profile: _noGoalRunner(km: km, days: days),
      races: _races(),
      goal: null,
      startDate: testToday,
    );

Iterable<Workout> _sets(TrainingPlan p) => p.weeks
    .expand((w) => w.workouts)
    .where((w) => w.type == WorkoutType.intervals);

/// The paces a trained 45 km runner trains on: a 45-minute 10K.
final _paces = derivePaces(
  fitness: assessFitness([raceK10(const Duration(minutes: 45))], testToday),
  goal: null,
  beginner: false,
);

void main() {
  group('a runner with no goal race still gets rep work', () {
    // The original report: 45 km a week, four days, nothing to race, and the
    // only hard running in twelve weeks was a threshold block. A flat
    // `List.filled(12, PlanPhase.base)` made that structural — no goal race was
    // not a reason to stop doing repetition work, only a reason not to
    // periodise toward a finish line.
    final plan = _noGoalPlan();

    test('the block contains repetition sessions', () {
      expect(_sets(plan), isNotEmpty,
          reason: 'a trained runner with no goal is not a beginner');
    });

    test('and more than one of them', () {
      expect(_sets(plan).length, greaterThanOrEqualTo(2));
    });

    test('and more than one rep distance, so the work is not repetitive', () {
      final distances = _sets(plan).map((w) => w.repDistanceM).toSet();
      expect(distances.length, greaterThanOrEqualTo(2),
          reason: 'got $distances');
    });

    test('the block is not twelve identical weeks', () {
      final descriptions =
          plan.weeks.expand((w) => w.workouts).map((w) => w.title).toSet();
      expect(descriptions.length, greaterThanOrEqualTo(3));
    });

    test('every set carries its structure on the workout itself', () {
      for (final w in _sets(plan)) {
        expect(w.reps, isNotNull, reason: w.title);
        expect(w.repDistanceM, isNotNull, reason: w.title);
        expect(w.repRecovery, isNotNull, reason: w.title);
      }
    });
  });

  group('the hard fraction is derived, not assumed', () {
    // 0.32 was a single flat constant applied to every interval session. It is
    // roughly right for one specific format — 3 min on / 3 min jog — and wrong
    // by a wide margin for everything else. Reading a 400m set as 32% hard made
    // `hardVolumeKm`, and therefore the 80/20 check, a fiction.
    final paces = _paces;

    test('a 400m set with 90s recovery is far harder than 0.32 says', () {
      final fraction = hardFractionForReps(
        reps: 10,
        repDistanceM: 400,
        repWork: null,
        recovery: const Duration(seconds: 90),
        repPaceSecondsPerKm: paces.interval.secPerKm.toDouble(),
        easyPaceSecondsPerKm: paces.easy.secPerKm.toDouble(),
      );
      // The content of the assertion is the gap from the old constant, not the
      // absolute value: at 90s recovery a short-rep set spends most of its
      // distance above easy pace, and 0.32 understated that by roughly a third.
      expect(fraction, greaterThan(intervalHardFraction * 1.25));
      expect(fraction, isNot(closeTo(intervalHardFraction, 0.05)));
    });

    test('a long set is harder still than a short one', () {
      double fraction(int m, int reps) => hardFractionForReps(
            reps: reps,
            repDistanceM: m,
            repWork: null,
            recovery: const Duration(seconds: 90),
            repPaceSecondsPerKm: paces.forZone(m > 1000
                    ? IntensityZone.threshold
                    : IntensityZone.interval)
                .secPerKm
                .toDouble(),
            easyPaceSecondsPerKm: paces.easy.secPerKm.toDouble(),
          );

      expect(fraction(2000, 3), greaterThan(fraction(400, 10)));
    });

    test('every generated set reports the derived value', () {
      for (final plan in [
        _noGoalPlan(),
        _noGoalPlan(km: 70, days: 5),
        _withGoal(),
      ]) {
        for (final w in _sets(plan)) {
          final expected = hardFractionForReps(
            reps: w.reps!,
            repDistanceM: w.repDistanceM,
            repWork: null,
            recovery: w.repRecovery!,
            repPaceSecondsPerKm:
                paces.forZone(w.repZone!).secPerKm.toDouble(),
            easyPaceSecondsPerKm: paces.easy.secPerKm.toDouble(),
          );
          expect(w.hardFractionOfDistance, closeTo(expected, 0.01),
              reason: '${w.title} in week ${w.title}');
        }
      }
    });
  });

  group('a solved set fits the week it was prescribed for', () {
    final paces = _paces;

    test('the rep count is what the room allows, not a constant', () {
      // Fixing the count would mean the session's distance had to come from
      // somewhere else, and then the week would stop adding up.
      final big = solveSet(
        RepFormat(
          distanceM: 400,
          recovery: const Duration(seconds: 90),
          zone: IntensityZone.interval,
        ),
        9,
        paces,
      )!;
      final small = solveSet(
        RepFormat(
          distanceM: 400,
          recovery: const Duration(seconds: 90),
          zone: IntensityZone.interval,
        ),
        5,
        paces,
      )!;
      expect(big.reps, greaterThan(small.reps));
      expect(big.distanceKm, lessThanOrEqualTo(9));
      expect(small.distanceKm, lessThanOrEqualTo(5));
    });

    test('a set that cannot reach three reps is not prescribed at all', () {
      final solved = solveSet(
        RepFormat(
          distanceM: 2000,
          recovery: const Duration(seconds: 180),
          zone: IntensityZone.threshold,
        ),
        1.0,
        paces,
      );
      expect(solved, isNull);
    });

    test('a week too small for a 400m set gets a shorter one, not a cut one',
        () {
      final solved = solveFormatSet(6, paces);
      expect(solved, isNotNull);
      expect(solved!.reps, greaterThanOrEqualTo(3),
          reason: 'a truncated set is not a set');
    });

    test('the 400m set is gated on a week big enough to absorb it', () {
      // Sharpest session the app can hand out, so it is gated the same way
      // `longRunShare` is day-aware: against the smallest week that can hold it.
      expect(solveFormatSet(9, paces)!.format.distanceM, 400);
      expect(
        solveFormatSet(9, paces, from: 1)!.format.distanceM,
        isNot(400),
        reason: 'a runner below the volume floor must not get 400m reps',
      );
    });

    test('no generated plan prescribes 400m reps below the volume floor', () {
      for (final w in _noGoalPlan(km: 25).weeks) {
        for (final s in w.workouts) {
          if (s.type != WorkoutType.intervals) continue;
          expect(
            s.repDistanceM == 400 && w.targetVolumeKm < minVolumeForSharpReps,
            isFalse,
            reason: 'week ${w.weekNumber} prescribed 400m reps at '
                '${w.targetVolumeKm.toStringAsFixed(1)} km',
          );
        }
      }
    });
  });

  group('rep structure survives the safety pass', () {
    // `enforceSafety` and `attachWeekdays` both rebuild a `Workout`. When
    // `_withWeekday` was a hand-written copy of the field list it dropped every
    // field added afterwards, and a session titled "800 m reps" was rendered
    // with no reps on it. The title still looked right, so nothing reported it.
    test('a set keeps its reps after enforcement', () {
      for (final plan in [_noGoalPlan(), _withGoal()]) {
        for (final week in plan.weeks) {
          for (final w in week.workouts) {
            if (w.type != WorkoutType.intervals) continue;
            expect(w.reps, isNotNull, reason: 'week ${week.weekNumber}');
            expect(w.repDistanceM, isNotNull, reason: 'week ${week.weekNumber}');
            expect(w.repRecovery, isNotNull, reason: 'week ${week.weekNumber}');
          }
        }
      }
    });

    test('withWeekday carries every field', () {
      const w = Workout(
        title: '800 m reps',
        type: WorkoutType.intervals,
        zone: IntensityZone.interval,
        description: '',
        reps: 8,
        repDistanceM: 800,
        repRecovery: Duration(seconds: 90),
        repZone: IntensityZone.interval,
      );
      final moved = w.withWeekday(3);
      expect(moved.reps, 8);
      expect(moved.repDistanceM, 800);
      expect(moved.repRecovery, const Duration(seconds: 90));
      expect(moved.repZone, IntensityZone.interval);
      expect(moved.weekday, 3);
    });
  });

  group('a week has exactly as many quality sessions as it budgets for', () {
    // The failure this pins: `qualitySessionsFor` returned 2 for a four-day
    // specific week and the placement guard could not fire below five days —
    // index 3 is the long run on `[1,3,5,7]`. The second session fell through
    // to the easy branch. The week still summed to its target, so every
    // invariant passed and the runner got one tempo and one easy run where the
    // arithmetic had budgeted two hard sessions.
    //
    // A base block is one quality session a week at any day count, which is a
    // design choice rather than an accident: there is no peak to prepare for, so
    // a second hard day would be hard work with nothing behind it.
    // A cutback does not empty specific or peak. `allocatePhases` splits by
    // percentage and `isCutbackWeek` then lands wherever it lands, so a 2-week
    // specific phase could hand its only rep week to a cutback and leave the
    // phase meant to prepare an athlete for their race containing nothing but
    // tempos. Base is deliberately exempt — dropping a deload's tempo is the
    // point of a deload.
    int expected(PlanWeek w, {required bool goalBlock}) {
      if (w.phase == PlanPhase.baseBlock) return 0;
      // The race is flagged as quality: it is the hardest thing in that week by
      // a wide margin, and a session log that treated it as an easy day would
      // misreport the week entirely.
      if (w.phase == PlanPhase.raceWeek) return 1;
      // A cutback is a deload in every phase — 100% easy, to absorb the weeks
      // before it.
      if (w.isCutback) return 0;
      if (!goalBlock) return 1;
      return qualitySessionsFor(w.phase, w.runCount);
    }

    for (final days in [3, 4, 5, 6]) {
      test('at $days days a week', () {
        final plans = <TrainingPlan, bool>{
          _noGoalPlan(days: days): false,
          generate(
            profile: _noGoalRunner(days: days),
            races: _races(),
            goal: goal(RaceDistance.k10,
                finishTime: const Duration(minutes: 45), inWeeks: 16),
            startDate: testToday,
          ): true,
        };
        plans.forEach((plan, isGoalBlock) {
          for (final w in plan.weeks) {
            // The taper keeps one hard session in its final week, and one in
            // each earlier week of a long race's taper.
            if (w.phase == PlanPhase.taper) {
              expect(w.qualityCount, inInclusiveRange(1, 2),
                  reason: 'week ${w.weekNumber}');
              continue;
            }
            expect(w.qualityCount, expected(w, goalBlock: isGoalBlock),
                reason: 'week ${w.weekNumber} (${w.phase.name}, '
                    '${w.runCount} days, goal=$isGoalBlock)');
          }
        });
      });
    }

    test('and no more than one rep set in a week', () {
      // Two sets pushed `easyFraction` to 0.75 against a 0.77 floor. A
      // double-quality week is tempo plus set.
      for (final plan in [
        _noGoalPlan(days: 5),
        _noGoalPlan(days: 6),
        _withGoal(),
      ]) {
        for (final w in plan.weeks) {
          final sets =
              w.workouts.where((s) => s.type == WorkoutType.intervals).length;
          expect(sets, lessThanOrEqualTo(1),
              reason: 'week ${w.weekNumber} has $sets sets');
        }
      }
    });
  });

  group('a rep count is a training decision, not a budget fill', () {
    // It used to be "the largest set that fits 22% of the week's volume", so a
    // 54.7 km week produced nine 800m reps because 22% of it happened to be
    // 12 km. Nothing in that arithmetic represented a decision about how many
    // reps to run. A runner read 9 x 800 and reasonably felt it was too much.
    test('no format exceeds its ceiling, however big the week', () {
      for (final weeklyKm in [45.0, 60.0, 90.0, 120.0]) {
        final plan = _withGoal(weeklyKm: weeklyKm);
        for (final w in plan.weeks) {
          for (final s in w.workouts) {
            if (s.type != WorkoutType.intervals) continue;
            expect(s.reps, lessThanOrEqualTo(maxRepsFor(s.repDistanceM!)),
                reason: 'week total ${w.targetVolumeKm.toStringAsFixed(1)}km: '
                    '${s.reps} x ${s.repDistanceM}m');
          }
        }
      }
    });

    test('a small week cannot buy more reps than a large one', () {
      int countFor(double km) {
        final set = _withGoal(weeklyKm: km)
            .weeks
            .expand((w) => w.workouts)
            .firstWhere((w) => w.type == WorkoutType.intervals);
        return set.reps!;
      }

      // Volume may only ever *shorten* a set, never extend one.
      expect(countFor(120), greaterThanOrEqualTo(countFor(45)));
    });

    test('the ceilings are the ones a coach would recognise', () {
      expect(maxRepsFor(400), 12);
      expect(maxRepsFor(800), 6);
      expect(maxRepsFor(1000), 5);
      expect(maxRepsFor(2000), 3);
    });
  });

  group('race-specific work is threshold work', () {
    // The zone was baked into the rep format, so a 10K athlete's race-specific
    // phase prescribed 800m at interval pace — faster than both their threshold
    // and their goal pace. That is 5K-effort work in the phase meant to prepare
    // them for a 10K, and it left peak as the only place with anything sharper.
    test('a specific-phase set runs at threshold', () {
      final plan = _withGoal();
      final sets = plan.weeks
          .where((w) => w.phase == PlanPhase.specific)
          .expand((w) => w.workouts)
          .where((w) => w.type == WorkoutType.intervals);
      expect(sets, isNotEmpty);
      for (final s in sets) {
        expect(s.repZone, IntensityZone.threshold,
            reason: '${s.title} in the race-specific phase');
      }
      final paces = plan.paces;
      final first = sets.first;
      final actual = _secondsPerKmIn(first.description);
      expect(actual, isNotNull, reason: first.description);
      expect(actual, closeTo(paces.threshold.secPerKm.toDouble(), 1),
          reason: first.description);
    });

    test('a peak set is allowed to be fast', () {
      final paces = _withGoal().paces;
      expect(
        paces.interval.secPerKm,
        lessThan(paces.threshold.secPerKm),
        reason: 'if interval is not faster than threshold, "peak is sharper" '
            'is a claim with nothing behind it',
      );
      expect(repZoneForPhase(PlanPhase.peak), IntensityZone.interval);
      expect(repZoneForPhase(PlanPhase.specific), IntensityZone.threshold);
      expect(repZoneForPhase(PlanPhase.base), IntensityZone.threshold);
    });

    test('a stretch goal cannot buy faster *training* paces', () {
      // Every zone is anchored on fitness rather than the goal, so a stretch
      // goal must not raise the intensity of a Tuesday session above what the
      // athlete has demonstrated — the `zone_anchor_regression_test` rule. The
      // set ladder must not be a way around it.
      //
      // The taper's race-pace session is the one documented exception and is
      // excluded: rehearsing the race pace is that session's whole purpose.
      // (Whether it is faster than threshold is not asserted here — a 1:35 half
      // is *slower* than this athlete's threshold pace, and a 10K goal is not.
      // `taper_methodology_test` owns the taper pace.)
      final athlete = _withGoal(
          goalTime: const Duration(hours: 1, minutes: 35, seconds: 0));
      final paces = athlete.paces;

      final training = athlete.weeks
          .where((w) => w.phase != PlanPhase.taper)
          .expand((w) => w.workouts)
          .where((w) => w.type == WorkoutType.intervals);
      expect(training, isNotEmpty);
      for (final w in training) {
        expect(_secondsPerKmIn(w.description),
            greaterThanOrEqualTo(paces.interval.secPerKm - 1.0),
            reason: '${w.title} (${w.repZone?.name}, '
                '${w.reps}x${w.repDistanceM}m): ${w.description}');
      }
    });
  });

  group('the goal-pace block in a long run is hard running', () {
    // It reported `hardFractionOfDistance: 0`, so `hardVolumeKm` — and therefore
    // the 80/20 invariant the whole plan is built to satisfy — was computed on a
    // plan that hid its own race-specific work.
    test('a specific-phase long run counts its goal-pace block', () {
      final longs = _withGoal()
          .weeks
          .where((w) => w.phase == PlanPhase.specific)
          .map((w) => w.longRun)
          .whereType<Workout>();
      expect(longs, isNotEmpty);
      for (final l in longs) {
        expect(l.hardFractionOfDistance, closeTo(0.33, 0.01),
            reason: 'a third of a specific long run is at marathon pace');
        expect(l.hardFractionOfDistance * l.distanceKm, greaterThan(3.0));
      }
    });

    test('a base long run is genuinely all easy', () {
      for (final l in _withGoal()
          .weeks
          .where((w) => w.phase == PlanPhase.base)
          .map((w) => w.longRun)
          .whereType<Workout>()) {
        expect(l.hardFractionOfDistance, 0);
      }
    });

    test('and it is re-derived when the long run is trimmed', () {
      // The block is a share of the run, so a capped run has a smaller block.
      // Carrying the old fraction would overstate hard distance on exactly the
      // weeks that were trimmed.
      expect(longRunHardFraction(PlanPhase.specific, 20), closeTo(0.33, 0.01));
      expect(longRunHardFraction(PlanPhase.peak, 20), closeTo(0.25, 0.01));
      // A peak long run too short for 5 km of MP + goal pace cannot claim it all.
      expect(longRunHardFraction(PlanPhase.peak, 3), 1.0);
      expect(longRunHardFraction(PlanPhase.specific, 0), 0);
    });
  });

  group('the frequency hint, and what it deliberately does not say', () {
    // A runner on three days gets one hard session. For a VDOT 38 that is a
    // complete and sustainable arrangement — and the runner it came from said so.
    // Above roughly VDOT 45 it starts leaving something on the table, and the app
    // knows both numbers and was saying nothing.
    PlanFlag? hintOf(TrainingPlan plan) {
      for (final f in plan.flags) {
        if (f.title.contains('hard session a week is what')) return f;
      }
      return null;
    }

    TrainingPlan atVdot(double vdot, int days) => generate(
          profile: _noGoalRunner(days: days),
          races: [
            RaceResult(
              distance: RaceDistance.k10,
              time: equivalentTime(vdot, RaceDistance.k10),
              date: testToday,
            ),
          ],
          goal: null,
          startDate: testToday,
        );

    test('it fires for a fast runner on three days', () {
      final plan = atVdot(50, 3);
      final hint = hintOf(plan);
      expect(hint, isNotNull, reason: 'no hint for a VDOT 50 runner on 3 days');
      expect(hint!.severity, FlagSeverity.info,
          reason: 'this is a trade-off to be aware of, not an error');
      expect(hint.detail, contains('coherent way to train'),
          reason: 'it must not tell a sound arrangement it is wrong');
      expect(hint.detail, contains('fourth day'));
    });

    test('it does not fire for a moderate runner on three days', () {
      // The case that produced the rule. VDOT 38, three days, one speed session
      // a week — flagged, this would be nagging about a legitimate setup.
      expect(hintOf(atVdot(38, 3)), isNull);
    });

    test('it fires exactly when fitness and frequency disagree', () {
      // The rule itself, asserted over a range rather than at three points, so a
      // change to either side of it has to be deliberate.
      for (final vdot in [30.0, 38.0, 42.0, 45.0, 48.0, 52.0]) {
        for (final days in [3, 4, 5, 6]) {
          final shouldFire =
              days <= 3 && vdot >= minimumVdotsForTwoSessions;
          expect(hintOf(atVdot(vdot, days)) != null, shouldFire,
              reason: 'VDOT $vdot on $days days');
        }
      }
    });

    test('it does not fire at four days, whatever the fitness', () {
      expect(hintOf(atVdot(52, 4)), isNull);
    });

    test('it does not fire for a fast runner on five days', () {
      expect(hintOf(atVdot(52, 5)), isNull);
    });

    test('and it never changes the plan', () {
      // A flag must not be able to make a week harder or softer. The two athletes
      // differ in fitness so their *distances* legitimately differ; what must not
      // differ is the shape of the week.
      final fast = atVdot(50, 3);
      final moderate = atVdot(38, 3);
      expect(fast.weeks.map((w) => w.qualityCount).toList(),
          moderate.weeks.map((w) => w.qualityCount).toList());
      expect(fast.weeks.map((w) => w.runCount).toList(),
          moderate.weeks.map((w) => w.runCount).toList());
      expect(fast.weeks.map((w) => w.phase).toList(),
          moderate.weeks.map((w) => w.phase).toList());
    });

    test('a runner with no race data gets no hint, because there is no VDOT', () {
      final plan = generate(
        profile: _noGoalRunner(days: 3),
        races: const [],
        goal: null,
        startDate: testToday,
      );
      expect(hintOf(plan), isNull);
    });
  });

  group('drop-quality has two shapes, and the right one is structural', () {
    // With two quality sessions, removing them is proportionate: the runner
    // still has a week of running, it is simply an easy one. With one — which is
    // every week at three and four days, and every base week at any day count —
    // removal is all-or-nothing on a single session and the proposal offers no
    // middle option at all.
    test('a one-session week is shortened, not deleted', () {
      final with_ = _withGoal();
      final without = generate(
        profile: _noGoalRunner(),
        races: _races(),
        goal: goal(RaceDistance.half,
            finishTime: const Duration(hours: 1, minutes: 50),
            inWeeks: 16,
            daysPerWeek: 4),
        directive: const PlanDirective(suppressQuality: true),
        startDate: testToday,
      );
      for (var i = 0; i < with_.weeks.length; i++) {
        final before = with_.weeks[i];
        if (before.isCutback ||
            before.phase == PlanPhase.taper ||
            before.phase == PlanPhase.raceWeek) {
          continue;
        }
        final after = without.weeks[i];
        expect(after.qualityCount, greaterThan(0),
            reason: 'week ${before.weekNumber} lost its session entirely');
        expect(after.hardVolumeKm, lessThan(before.hardVolumeKm),
            reason: 'week ${before.weekNumber} did not get easier');
        // Not a token: cutting to 60% must leave real work behind.
        expect(after.hardVolumeKm, greaterThan(before.hardVolumeKm * 0.4),
            reason: 'week ${before.weekNumber} was cut to a stub');
      }
    });

    test('a two-session week is cleared out', () {
      final with_ = generate(
        profile: _noGoalRunner(days: 5),
        races: _races(),
        goal: goal(RaceDistance.half,
            finishTime: const Duration(hours: 1, minutes: 50),
            inWeeks: 16,
            daysPerWeek: 5),
        startDate: testToday,
      );
      final without = generate(
        profile: _noGoalRunner(days: 5),
        races: _races(),
        goal: goal(RaceDistance.half,
            finishTime: const Duration(hours: 1, minutes: 50),
            inWeeks: 16,
            daysPerWeek: 5),
        directive: const PlanDirective(suppressQuality: true),
        startDate: testToday,
      );
      final two = with_.weeks.where((w) => w.qualityCount == 2).toList();
      expect(two, isNotEmpty);
      for (final before in two) {
        if (before.phase == PlanPhase.taper) continue;
        expect(without.weeks[before.weekNumber - 1].hardVolumeKm, 0,
            reason: 'week ${before.weekNumber} kept hard running');
      }
    });

    test('the taper is exempt either way', () {
      final without = generate(
        profile: _noGoalRunner(days: 4),
        races: _races(),
        goal: goal(RaceDistance.marathon,
            finishTime: const Duration(hours: 3, minutes: 20),
            inWeeks: 16,
            daysPerWeek: 4),
        directive: const PlanDirective(suppressQuality: true),
        startDate: testToday,
      );
      expect(
        without.weeks
            .where((w) => w.phase == PlanPhase.taper)
            .any((w) => w.hardVolumeKm > 0),
        isTrue,
        reason: 'the taper keeps its hard work by design',
      );
    });

    test('a cutback is 100% easy even with the directive on', () {
      final without = generate(
        profile: _noGoalRunner(days: 4),
        races: _races(),
        goal: goal(RaceDistance.half,
            finishTime: const Duration(hours: 1, minutes: 50),
            inWeeks: 16,
            daysPerWeek: 4),
        directive: const PlanDirective(suppressQuality: true),
        startDate: testToday,
      );
      for (final w in without.weeks.where((w) => w.isCutback)) {
        expect(w.hardVolumeKm, 0, reason: 'week ${w.weekNumber}');
      }
    });
  });

  group('a three-day plan reaches a set without being told to', () {
    // The premise for *not* changing the prescription at three days: the ladder
    // already gives a set in peak and alternates in specific, so a three-day
    // runner is not doing twelve tempos. A VDOT 38 runner managing one speed
    // session a week is the design working, not a gap in it.
    test('by the peak phase a three-day week contains a rep set', () {
      // Only the goal block has a peak — a base block has base and specific, and
      // inventing a peak for a runner with no race would imply a taper that never
      // comes. The base block still reaches a set, in its specific phase.
      final peakSets = generate(
        profile: _noGoalRunner(days: 3),
        races: _races(),
        goal: goal(RaceDistance.k10,
            finishTime: const Duration(minutes: 45),
            inWeeks: 16,
            daysPerWeek: 3),
        startDate: testToday,
      ).weeks
          .where((w) => w.phase == PlanPhase.peak)
          .expand((w) => w.workouts)
          .where((w) => w.type == WorkoutType.intervals);
      expect(peakSets, isNotEmpty, reason: 'a three-day peak has no set');
      expect(peakSets.first.repDistanceM, isNotNull);

      expect(_noGoalPlan(days: 3).weeks.expand((w) => w.workouts)
          .where((w) => w.type == WorkoutType.intervals), isNotEmpty,
          reason: 'a three-day base block never reaches a set');
    });
  });

  group('a cutback is a deload in every phase', () {
    // There was a period where specific and peak were exempted, so that a short
    // phase could not lose its only rep week to a cutback. That made cutbacks do
    // two contradictory things at once, and "keep the hard work" is not a
    // deload under any reading of the word.
    //
    // The risk it papered over is real — `allocatePhases` splits by percentage
    // and `isCutbackWeek` then lands wherever it lands, so a two-week specific
    // phase can hand its only rep week to a cutback. That is now visible rather
    // than hidden. The fix for it is to place the cutback, not to exempt a phase
    // from deloading.
    test('no cutback carries hard work', () {
      for (final plan in [
        _withGoal(),
        _noGoalPlan(),
        _noGoalPlan(days: 5),
        _noGoalPlan(days: 6),
      ]) {
        for (final w in plan.weeks.where((w) => w.isCutback)) {
          expect(w.qualityCount, 0,
              reason: 'cutback week ${w.weekNumber} (${w.phase.name}) kept '
                  'hard work');
          expect(w.hardVolumeKm, 0,
              reason: 'cutback week ${w.weekNumber} (${w.phase.name}) is not '
                  '100% easy');
        }
      }
    });

    test('every other build week still carries one', () {
      // The complement of the deload rule, and the property that was actually
      // wanted: the >=1 guarantee covers *common* weeks, and a cutback is not
      // one.
      for (final plan in [
        _withGoal(),
        _noGoalPlan(days: 5),
        _noGoalPlan(days: 6),
      ]) {
        for (final w in plan.weeks) {
          if (w.isCutback) continue;
          if (w.phase == PlanPhase.taper || w.phase == PlanPhase.raceWeek) {
            continue;
          }
          expect(w.qualityCount, greaterThan(0),
              reason: 'week ${w.weekNumber} (${w.phase.name}) has no hard work');
        }
      }
    });
  });

  group('the session card says what the session actually is', () {
    // Every quality session was described in minutes while being budgeted in
    // distance, so the easy legs inflated to fill and every card understated the
    // session by about twelve minutes. A runner told "10 min warm-up, 5 min cool
    // down" and then handed 27 minutes of easy has no way to know they are being
    // asked for more than the card says — and "it feels like too much" is not a
    // report anyone files. It just becomes a reason to stop running the session.
    test('no quality session describes its warm-up in minutes', () {
      for (final plan in [
        _withGoal(),
        _noGoalPlan(),
        _noGoalPlan(days: 5),
      ]) {
        for (final w in plan.weeks) {
          for (final s in w.workouts) {
            if (!s.isQuality || s.type == WorkoutType.race) continue;
            expect(s.description, isNot(contains('min warm-up')),
                reason: 'week ${w.weekNumber}: ${s.title}');
            expect(s.description, contains('Easy for'),
                reason: 'week ${w.weekNumber}: ${s.title}');
          }
        }
      }
    });

    test('the distances it names add up to the session', () {
      for (final plan in [_withGoal(), _noGoalPlan()]) {
        for (final w in plan.weeks) {
          for (final s in w.workouts) {
            if (!s.isQuality || s.type == WorkoutType.race) continue;
            final easyKm = s.distanceKm * (1 - s.hardFractionOfDistance);
            expect(
              s.description,
              contains(_formatDistance(easyKm / 2)),
              reason: 'week ${w.weekNumber}: ${s.title} prescribes '
                  '${easyKm.toStringAsFixed(2)} km of easy but its card does '
                  'not name half of it',
            );
          }
        }
      }
    });

    test('and the pace it shows is the pace its body names', () {
      // The card used to derive its number from the session's *zone*, which is a
      // five-rung classification of a continuum. Real prescriptions do not land
      // on the rungs: a 51:00 10K is 5:06/km, and the ladder had threshold at
      // 5:09 and interval at 4:53 — nothing at 5:06. So the card said one number
      // and the description said another, on the session where it matters most.
      for (final plan in [
        _withGoal(),
        _noGoalPlan(),
        _k10Goal(),
      ]) {
        for (final w in plan.weeks) {
          for (final s in w.workouts) {
            if (s.type == WorkoutType.rest) continue;
            final named = _secondsPerKmIn(s.description);
            if (named == null) continue;
            expect(
              s.displayPace(plan.paces).secPerKm,
              named,
              reason: 'week ${w.weekNumber}: ${s.title} shows '
                  '${s.displayPace(plan.paces).format()} and names '
                  '${named ~/ 60}:${(named % 60).toString().padLeft(2, '0')}',
            );
          }
        }
      }
    });

    test('a session prescribed off-ladder states its pace explicitly', () {
      // Scoped to the race-pace set and the race itself. A *mid-taper* tempo is
      // prescribed at threshold, which is on the ladder, so it correctly has no
      // explicit pace — the field is for the sessions zones cannot express.
      for (final plan in [_k10Goal(), _withGoal()]) {
        for (final w in plan.weeks) {
          for (final s in w.workouts) {
            if (!s.title.startsWith('Goal-pace')) continue;
            expect(s.prescribedPace, isNotNull,
                reason: 'week ${w.weekNumber}: ${s.title} has no explicit '
                    'pace, so its card falls back to a zone that does not '
                    'contain it');
            expect(s.repZone, s.zone,
                reason: 'the reps and the session should classify the same');
          }
        }
      }
    });

    test('the goal race shows the goal pace, not the marathon-pace number', () {
      final plan = _k10Goal(goalTime: const Duration(minutes: 51));
      final race = plan.weeks.last.workouts
          .firstWhere((s) => s.type == WorkoutType.race);
      expect(race.prescribedPace, isNotNull);
      expect(race.prescribedPace!.secPerKm, closeTo(306, 2),
          reason: '51:00 over 10 km is 5:06/km; the card used to show the '
              'marathon-pace equivalent, which is ~40 s/km slower');
      expect(race.displayPace(plan.paces).secPerKm, race.prescribedPace!.secPerKm);
    });

    test('a session at a zone still shows that zone pace', () {
      // The fallback must stay the common case, or every tempo and long run would
      // need an explicit pace and the field would be pointless.
      final plan = _withGoal();
      final tempo = plan.weeks
          .expand((w) => w.workouts)
          .firstWhere((s) => s.type == WorkoutType.tempo);
      expect(tempo.prescribedPace, isNull);
      expect(tempo.displayPace(plan.paces).secPerKm,
          plan.paces.threshold.secPerKm);
    });
  });

  group('every build week keeps its speed session', () {
    // The runner's own requirement, and the thing this round's changes could
    // most easily have cost: a three-day week is easy / speed / long, and the
    // speed session has to actually be there.
    test('no build week is left without one, at any day count', () {
      for (final days in [3, 4, 5, 6]) {
        for (final plan in [
          _noGoalPlan(days: days),
          // `daysPerWeek` on the *goal* is what sizes a race block; the profile
          // only sizes a base block. Passing the profile alone left this testing
          // four days in both arms.
          generate(
            profile: _noGoalRunner(days: days),
            races: _races(),
            goal: goal(RaceDistance.k10,
                finishTime: const Duration(minutes: 45),
                inWeeks: 16,
                daysPerWeek: days),
            startDate: testToday,
          ),
        ]) {
          for (final w in plan.weeks) {
            if (w.phase == PlanPhase.taper || w.phase == PlanPhase.raceWeek) {
              continue;
            }
            // A cutback is a deload, in every phase: 100% easy, to absorb the
            // weeks before it. "Keep the hard work" is not a deload. The
            // consequence is visible rather than papered over — on a short
            // block a cutback can land in the race-specific phase and leave it
            // without a rep week. The fix for that is to place the cutback, not
            // to exempt a phase from deloading.
            if (w.isCutback) continue;
            expect(w.qualityCount, greaterThan(0),
                reason: 'week ${w.weekNumber} (${w.phase.name}, '
                    'cutback=${w.isCutback}, $days days) has no speed work');
          }
        }
      }
    });

    test('and no session is budgeted without a day to place it', () {
      // `qualitySlots(2, 1)` used to return `[3]` for a week whose only
      // positions are 0 and 1: the session was built, subtracted from the easy
      // budget, and never written down. The slot list is now authoritative, so a
      // week cannot budget a session it has no day for.
      expect(qualitySlots(2, 1), isEmpty);
      for (final days in [3, 4, 5, 6]) {
        for (final count in [0, 1, 2]) {
          final slots = qualitySlots(days, count);
          for (final s in slots) {
            expect(s, lessThan(days), reason: '$days days');
          }
          expect(slots.toSet().length, slots.length, reason: '$days days');
          expect(slots, isNot(contains(0)), reason: '$days days');
          expect(slots, isNot(contains(days - 1)), reason: '$days days');
          expect(slots.length, lessThanOrEqualTo(count), reason: '$days days');
        }
      }
    });
  });

  group('a three-day week is easy, speed, long', () {
    // At three days the long run is Saturday and Sunday is already free, so a
    // Monday recovery day is absorbing nothing — and the card said exactly that,
    // on the wrong side of the long run. It also cost a third of the week's
    // runnable days spent *below* easy, the one pace that builds nothing.
    test('the pattern leaves a free day between the long run and the week', () {
      expect(longRunFollowsImmediately(weeklyDayPattern(3)), isFalse);
      for (final days in [4, 5, 6]) {
        expect(longRunFollowsImmediately(weeklyDayPattern(days)), isTrue,
            reason: '$days days');
      }
    });

    test('three days gives no recovery run', () {
      for (final plan in [
        _noGoalPlan(days: 3),
        generate(
          profile: _noGoalRunner(days: 3),
          races: _races(),
          goal: goal(RaceDistance.k10,
              finishTime: const Duration(minutes: 45),
              inWeeks: 16,
              daysPerWeek: 3),
          startDate: testToday,
        ),
      ]) {
        for (final w in plan.weeks) {
          for (final s in w.workouts) {
            expect(s.type, isNot(WorkoutType.recovery),
                reason: 'week ${w.weekNumber}: ${s.title}');
          }
        }
      }
    });

    test('four or more days still gets one, because there the long run is Sunday',
        () {
      for (final days in [4, 5, 6]) {
        final plan = _noGoalPlan(days: days);
        final recovery = plan.weeks
            .expand((w) => w.workouts)
            .where((w) => w.type == WorkoutType.recovery);
        expect(recovery, isNotEmpty, reason: '$days days lost its recovery day');
        // And the copy is true there: it really does follow the long run.
        expect(recovery.first.description, contains('Absorb the long run'));
      }
    });

    test('the swap is zone-only — no volume or 80/20 movement', () {
      for (final days in [3, 4, 5, 6]) {
        final plan = _noGoalPlan(days: days);
        for (final w in plan.weeks) {
          if (w.phase == PlanPhase.raceWeek) continue;
          // The week still adds up.
          expect(w.targetVolumeKm, closeTo(w.runVolumeKm, 0.01),
              reason: 'week ${w.weekNumber} at $days days');
          // And both zones count as easy, so the 80/20 split cannot have moved.
          for (final s in w.runs) {
            if (s.type == WorkoutType.easy || s.type == WorkoutType.recovery) {
              expect(s.zone.isEasy, isTrue, reason: '${s.title} at $days days');
            }
          }
        }
      }
    });

    test('the first day of a three-day week says why it is easy', () {
      final week = _noGoalPlan(days: 3).weeks.first;
      final first = week.workouts.firstWhere((w) => w.weekday == 1);
      expect(first.type, WorkoutType.easy);
      expect(first.description, contains('go slower'),
          reason: 'the safety valve has to be on the card, not just intended');
      expect(first.description, isNot(contains('Absorb the long run')));
    });
  });

  group('the set week does not depend on the block length', () {
    // The alternation used to be on the absolute plan week, so the number of
    // set sessions depended on where the base/specific boundary landed after
    // rounding. Change the block length by one and the count moved for no
    // reason the runner could see.
    int setWeeks(TrainingPlan p) => p.weeks
        .where((w) =>
            w.workouts.any((s) => s.type == WorkoutType.intervals))
        .length;

    test('a one-week difference in runway does not halve the set count', () {
      final a = generate(
        profile: _noGoalRunner(),
        races: _races(),
        goal: goal(RaceDistance.half,
            finishTime: const Duration(hours: 1, minutes: 50), inWeeks: 14),
        startDate: testToday,
      );
      final b = generate(
        profile: _noGoalRunner(),
        races: _races(),
        goal: goal(RaceDistance.half,
            finishTime: const Duration(hours: 1, minutes: 50), inWeeks: 15),
        startDate: testToday,
      );
      expect((setWeeks(a) - setWeeks(b)).abs(), lessThanOrEqualTo(1),
          reason: 'got ${setWeeks(a)} and ${setWeeks(b)}');
    });
  });
}

TrainingPlan _withGoal({
  double weeklyKm = 45,
  Duration goalTime = const Duration(hours: 1, minutes: 50),
}) =>
    generate(
      profile: _noGoalRunner(km: weeklyKm),
      races: _races(),
      goal: goal(RaceDistance.half, finishTime: goalTime, inWeeks: 16),
      startDate: testToday,
    );

/// A 10K block, where the goal pace is furthest from any zone on the ladder.
TrainingPlan _k10Goal({Duration goalTime = const Duration(minutes: 51)}) =>
    generate(
      profile: _noGoalRunner(),
      races: _races(),
      goal: goal(RaceDistance.k10, finishTime: goalTime, inWeeks: 16),
      startDate: testToday,
    );

/// The largest rep count this app will prescribe for a given rep distance.
///
/// Read out of the ladder rather than hardcoded in the test, so a change to the
/// ladder shows up here as a failure rather than as a silent drift.
int maxRepsFor(int distanceM) {
  final format = repFormatFor(distanceM);
  if (format == null) return fail('no $distanceM m rep format exists');
  return format.maxReps;
}

/// Seconds per km named in a session's description, or null if it names none.
int? _secondsPerKmIn(String description) {
  final match = RegExp(r'(\d+):(\d\d)/km').firstMatch(description);
  if (match == null) return null;
  return int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!);
}

/// A running distance as the session cards render it.
String _formatDistance(double km) {
  if (km < 1) return '${(km * 1000).round()} m';
  if (km < 10) return '${km.toStringAsFixed(1)} km';
  return '${km.round()} km';
}
