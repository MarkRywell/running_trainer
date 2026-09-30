/// Phase 8, part two: per-session logging and the proposals it feeds.
///
/// The interesting property throughout is that per-session detail **narrows** what
/// the app is willing to conclude. A week-level difficulty of 7 could mean the
/// tempo was too much or the long run was too much, and the only available answer
/// was to flatten the whole block. With per-session records those become two
/// different problems, and only one of them should stop prescribing quality work.
library;

import 'package:ai_running_trainer/domain/coaching.dart';
import 'package:ai_running_trainer/domain/engine/fitness.dart';
import 'package:ai_running_trainer/domain/engine/validation.dart';
import 'package:ai_running_trainer/domain/engine/volume.dart';
import 'package:ai_running_trainer/domain/models/goal.dart';
import 'package:ai_running_trainer/domain/models/plan.dart';
import 'package:ai_running_trainer/domain/models/plan_directive.dart';
import 'package:ai_running_trainer/domain/models/profile.dart';
import 'package:ai_running_trainer/domain/models/race.dart';
import 'package:ai_running_trainer/domain/models/week_log.dart';
import 'package:ai_running_trainer/domain/plan/generate.dart';
import 'package:ai_running_trainer/domain/progress.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fixtures.dart';

const _runner = RunnerProfile(
  name: 'Sam',
  age: 34,
  gender: Gender.preferNotToSay,
  monthsRunning: 36,
  daysPerWeek: 4,
  estimatedWeeklyKm: 45,
);

GoalRace _goal() => GoalRace(
      distance: RaceDistance.marathon,
      date: testToday.add(const Duration(days: 18 * 7)),
      finishTimeGoal: const Duration(hours: 3, minutes: 30),
      daysPerWeek: 4,
    );

List<RaceResult> _races() => [
      RaceResult(
        distance: RaceDistance.k10,
        time: const Duration(minutes: 44),
        date: testToday.subtract(const Duration(days: 25)),
      ),
    ];

TrainingPlan _plan({PlanDirective directive = const PlanDirective()}) =>
    generate(
      profile: _runner,
      races: _races(),
      goal: _goal(),
      startDate: testToday,
      directive: directive,
    );

/// The weekday a prescribed session of [type] sits on in week [i], or null.
int? _dayOf(PlanWeek week, WorkoutType type) {
  for (final w in week.workouts) {
    if (w.type == type && w.weekday != null) return w.weekday;
  }
  return null;
}

void main() {
  group('SessionLog', () {
    test('round-trips through JSON', () {
      const original = SessionLog(
        dayOfWeek: 3,
        felt: SessionFelt.hard,
        actualKm: 12.5,
      );
      final restored = SessionLog.fromJson(original.toJson());
      expect(restored.dayOfWeek, 3);
      expect(restored.felt, SessionFelt.hard);
      expect(restored.actualKm, 12.5);
    });

    test('an absent effort is absent, not "easy"', () {
      final restored = SessionLog.fromJson(const SessionLog(dayOfWeek: 1).toJson());
      expect(restored.felt, isNull);
      expect(restored.feltHard, isFalse);
      expect(restored.hasData, isFalse);
    });

    test('an unreadable effort reads as right rather than crashing', () {
      final restored = SessionLog.fromJson({'day': 2, 'felt': 'exhausted'});
      expect(restored.felt, SessionFelt.right);
    });

    test('only a hard session counts as hard', () {
      expect(const SessionLog(dayOfWeek: 1, felt: SessionFelt.easy).feltHard,
          isFalse);
      expect(const SessionLog(dayOfWeek: 1, felt: SessionFelt.right).feltHard,
          isFalse);
      expect(const SessionLog(dayOfWeek: 1, felt: SessionFelt.hard).feltHard,
          isTrue);
    });
  });

  group('a week cannot grow without bound', () {
    test('the stored list is trimmed to seven', () {
      final tooMany = [
        for (var day = 1; day <= 12; day++)
          SessionLog(dayOfWeek: day <= 7 ? day : 1, felt: SessionFelt.easy),
      ];
      final restored = WeekLog.fromJson({
        'completed': true,
        'sessions': [for (final s in tooMany) s.toJson()],
      });
      expect(restored.sessions.length, lessThanOrEqualTo(maxSessionsPerWeek));
    });

    test('a session outside the week is discarded on read', () {
      final restored = WeekLog.fromJson({
        'completed': true,
        'sessions': [
          {'day': 3, 'felt': 'easy'},
          {'day': 9, 'felt': 'hard'},
          {'day': 0, 'felt': 'hard'},
        ],
      });
      expect(restored.sessions.map((s) => s.dayOfWeek), [3]);
    });

    test('one unreadable session does not lose the rest of the week', () {
      final restored = WeekLog.fromJson({
        'completed': true,
        'sessions': [
          {'day': 1, 'felt': 'easy'},
          'not-an-object',
          {'day': 5, 'felt': 'hard'},
        ],
      });
      expect(restored.sessions.length, 2);
      expect(restored.hardSessionCount, 1);
    });
  });

  group('weekday stamping', () {
    test('every session carries a day', () {
      final plan = _plan();
      for (final week in plan.weeks) {
        for (final w in week.workouts) {
          expect(w.weekday, isNotNull, reason: '${w.title} has no day');
          expect(w.weekday, inInclusiveRange(1, 7));
        }
      }
    });

    test('the days are distinct within a week', () {
      // Two sessions claiming the same day would make a session log ambiguous.
      for (final week in _plan().weeks) {
        final days = week.workouts.map((w) => w.weekday).toSet();
        expect(days.length, week.workouts.length,
            reason: 'week ${week.weekNumber} repeats a day');
      }
    });

    test('a capped long run keeps its day', () {
      // `enforceSafety` rebuilds the workout. If it dropped the day, a session
      // log would silently stop matching the long run — the exact signal this
      // feature exists to produce.
      final capped = enforceSafety(PlanWeek(
        weekNumber: 1,
        startDate: testToday,
        phase: PlanPhase.base,
        targetVolumeKm: 30,
        workouts: [
          const Workout(
            title: 'Long run',
            type: WorkoutType.long,
            zone: IntensityZone.easy,
            description: 'x',
            distanceKm: 25,
            weekday: 6,
          ),
          const Workout(
            title: 'Easy',
            type: WorkoutType.easy,
            zone: IntensityZone.easy,
            description: 'x',
            distanceKm: 8,
            weekday: 1,
          ),
        ],
      ));
      expect(capped.longRun!.distanceKm, lessThan(25));
      expect(capped.longRun!.weekday, 6, reason: 'the day must survive the cap');
    });

    test('a race week still places the race on a day', () {
      for (final week in _plan().weeks) {
        if (week.phase != PlanPhase.raceWeek) continue;
        for (final w in week.workouts) {
          if (w.type == WorkoutType.race) {
            expect(w.weekday, isNotNull);
            return;
          }
        }
      }
      fail('no race week found');
    });
  });

  group('per-session signals', () {
    /// A plan plus logs marking the session of [type] hard in each of [weeks].
    ({TrainingPlan plan, PlanProgress progress}) withHardSessions({
      required WorkoutType type,
      required List<int> weeks,
      SessionFelt felt = SessionFelt.hard,
    }) {
      final plan = _plan();
      final logs = <String, WeekLog>{};
      for (final i in weeks) {
        final week = plan.weeks[i];
        final day = _dayOf(week, type);
        if (day == null) continue;
        logs[weekKey(week.startDate)] = WeekLog(
          completed: true,
          sessions: [SessionLog(dayOfWeek: day, felt: felt)],
        );
      }
      return (
        plan: plan,
        progress: PlanProgress(plan: plan, weekLogs: logs),
      );
    }

    test('nothing recorded reads as unknown, not zero', () {
      final progress = PlanProgress(plan: _plan(), weekLogs: const {});
      expect(progress.observedIntensityShare, isNull);
      expect(progress.hardQualitySessionsRecorded, 0);
    });

    test('hard quality sessions are counted individually', () {
      final r = withHardSessions(
        type: WorkoutType.tempo,
        weeks: [0, 1, 2],
      );
      expect(r.progress.hardQualitySessionsRecorded, 3);
      expect(r.progress.hardQualityWeeks, [0, 1, 2]);
    });

    test('a hard easy-day session is not counted as a quality problem', () {
      // This is the whole point: same effort rating, opposite diagnosis.
      final quality = withHardSessions(
        type: WorkoutType.tempo,
        weeks: [0, 1, 2, 3, 4],
      );
      final easy = withHardSessions(
        type: WorkoutType.easy,
        weeks: [0, 1, 2, 3, 4],
      );
      expect(quality.progress.hardQualitySessionsRecorded, greaterThanOrEqualTo(3));
      expect(easy.progress.hardQualitySessionsRecorded, 0);
      expect(easy.progress.hardEasySessionsRecorded, greaterThan(0));
    });

    test('an unrecorded session is not counted as an easy one', () {
      final r = withHardSessions(
        type: WorkoutType.tempo,
        weeks: [0, 1, 2],
      );
      // One recorded hard session, one recorded nothing.
      final plan = r.plan;
      final logs = <String, WeekLog>{
        weekKey(plan.weeks[0].startDate): const WeekLog(
          completed: true,
          sessions: [SessionLog(dayOfWeek: 2)],
        ),
      };
      final progress = PlanProgress(plan: plan, weekLogs: logs);
      expect(progress.sessionsWithEffort, 0);
      expect(progress.observedIntensityShare, isNull);
    });
  });

  group('observed intensity', () {
    test('the pure function agrees with PlanProgress', () {
      final plan = _plan();
      final logs = <String, WeekLog>{
        for (var i = 0; i < 4; i++)
          weekKey(plan.weeks[i].startDate): WeekLog(
            completed: true,
            sessions: const [
              SessionLog(dayOfWeek: 2, felt: SessionFelt.hard),
              SessionLog(dayOfWeek: 4, felt: SessionFelt.easy),
            ],
          ),
      };
      final progress = PlanProgress(plan: plan, weekLogs: logs);
      final share = observedIntensity(
        weekLogs: logs,
        weekCount: plan.weekCount,
        weekStartFor: (i) => plan.weeks[i].startDate,
      );
      expect(share, progress.observedIntensityShare);
      expect(share, closeTo(0.5, 0.001));
    });

    test('a consistently hard runner is flagged', () {
      final plan = _plan();
      final logs = <String, WeekLog>{};
      for (var i = 0; i < 6; i++) {
        final week = plan.weeks[i];
        logs[weekKey(week.startDate)] = WeekLog(
          completed: true,
          sessions: [
            for (final w in week.workouts.where((w) => w.type != WorkoutType.rest))
              SessionLog(dayOfWeek: w.weekday!, felt: SessionFelt.hard),
          ],
        );
      }
      final flags = validate(
        profile: _runner,
        fitness: assessFitnessFor(plan),
        goal: _goal(),
        today: testToday,
        weekLogs: logs,
        weekCount: plan.weekCount,
        weekStartFor: (i) => plan.weeks[i].startDate,
      );
      expect(
        flags.any((f) => f.title.contains('harder than planned')),
        isTrue,
        reason: 'running every session hard is the 80/20 failure: '
            '${flags.map((f) => f.title)}',
      );
    });

    test('a small sample is not enough to accuse anyone', () {
      // Four hard sessions might be one weekend.
      final plan = _plan();
      final logs = <String, WeekLog>{
        weekKey(plan.weeks[0].startDate): const WeekLog(
          completed: true,
          sessions: [
            SessionLog(dayOfWeek: 1, felt: SessionFelt.hard),
            SessionLog(dayOfWeek: 3, felt: SessionFelt.hard),
          ],
        ),
      };
      final flags = validate(
        profile: _runner,
        fitness: assessFitnessFor(plan),
        goal: _goal(),
        today: testToday,
        weekLogs: logs,
        weekCount: plan.weekCount,
        weekStartFor: (i) => plan.weeks[i].startDate,
      );
      expect(flags.any((f) => f.title.contains('harder than planned')), isFalse);
    });
  });

  group('the drop-quality proposal', () {
    TrainingPlan planWithLogs(Map<String, WeekLog> logs) =>
        generate(
          profile: _runner,
          races: _races(),
          goal: _goal(),
          startDate: testToday,
          weekLogs: logs,
        );

    Map<String, WeekLog> hardQualityLogs(TrainingPlan plan, List<int> weeks) => {
          for (final i in weeks)
            weekKey(plan.weeks[i].startDate): () {
              final day = _dayOf(plan.weeks[i], WorkoutType.tempo) ??
                  _dayOf(plan.weeks[i], WorkoutType.intervals);
              return WeekLog(
                completed: true,
                sessions: [
                  SessionLog(dayOfWeek: day ?? 2, felt: SessionFelt.hard),
                ],
              );
            }(),
        };

    test('three hard quality sessions are enough', () {
      final base = _plan();
      final logs = hardQualityLogs(base, [0, 1, 2]);
      final progress = PlanProgress(
        plan: planWithLogs(logs),
        weekLogs: logs,
      );
      final ids = propose(progress).map((p) => p.id).toList();
      expect(ids, contains('drop-quality'));
    });

    test('two are not', () {
      // A single hard tempo is a bad day, not a miscalibration.
      final base = _plan();
      final logs = hardQualityLogs(base, [0, 1]);
      final progress = PlanProgress(
        plan: planWithLogs(logs),
        weekLogs: logs,
      );
      expect(propose(progress).map((p) => p.id), isNot(contains('drop-quality')));
    });

    test('hard long runs do not trigger it', () {
      // A hard long run is a volume problem, and cap-volume already answers it.
      final base = _plan();
      final logs = {
        for (final i in [0, 1, 2, 3, 4])
          weekKey(base.weeks[i].startDate): () {
            final day = _dayOf(base.weeks[i], WorkoutType.long) ?? 6;
            return WeekLog(
              completed: true,
              sessions: [
                SessionLog(dayOfWeek: day, felt: SessionFelt.hard),
              ],
            );
          }(),
      };
      final progress = PlanProgress(
        plan: planWithLogs(logs),
        weekLogs: logs,
      );
      expect(propose(progress).map((p) => p.id), isNot(contains('drop-quality')));
    });

    test('the directive removes quality work and keeps the volume', () {
      final with_ = _plan();
      final without =
          _plan(directive: const PlanDirective(suppressQuality: true));

      // The goal race itself is not something a directive may remove, so this is
      // about tempo and interval work only.
      bool hasTraining(PlanWeek w) =>
          w.workouts.any((s) => isQualityType(s.type) && s.type != WorkoutType.race);

      expect(without.weeks.any(hasTraining), isFalse,
          reason: 'no hard training sessions should remain');
      expect(with_.weeks.any(hasTraining), isTrue);

      // What must hold: the hard work is what disappears. Total mileage may move
      // a couple of percent either way, because the unsuppressed week loses
      // volume to the cap that keeps the quality session shorter than the long
      // run, and redistributing it onto easy days recovers some of that. The
      // safety property is that everything the week gains is easy.
      for (var i = 0; i < with_.weeks.length; i++) {
        if (with_.weeks[i].phase == PlanPhase.raceWeek) continue;
        final before = with_.weeks[i];
        final after = without.weeks[i];

        expect(after.hardVolumeKm, 0,
            reason: 'week ${before.weekNumber} still prescribes hard running');
        // Cutbacks and taper weeks carry no quality work by design, so there is
        // nothing for the directive to remove from them and nothing to assert.
        if (before.isCutback ||
            before.phase == PlanPhase.taper ||
            before.phase == PlanPhase.raceWeek) {
          continue;
        }
        expect(before.hardVolumeKm, greaterThan(0),
            reason: 'week ${before.weekNumber} had no hard work to remove');

        final drift = (after.targetVolumeKm - before.targetVolumeKm) /
            before.targetVolumeKm;
        expect(
          drift.abs(),
          lessThan(0.10),
          reason: 'week ${before.weekNumber} moved ${(drift * 100).round()}%',
        );
      }
    });

    test('suppressing quality can only make a week easier', () {
      // The invariant that makes this directive safe to offer: it moves the 80/20
      // split one way only, so it can never make a plan too hard.
      final with_ = _plan();
      final without =
          _plan(directive: const PlanDirective(suppressQuality: true));
      for (var i = 0; i < with_.weeks.length; i++) {
        if (with_.weeks[i].phase == PlanPhase.raceWeek) continue;
        expect(
          without.weeks[i].easyFraction,
          greaterThanOrEqualTo(with_.weeks[i].easyFraction - 0.001),
          reason: 'week ${with_.weeks[i].weekNumber} got harder',
        );
        expect(satisfiesEasyRule(without.weeks[i]), isTrue);
      }
    });

    test('the proposal is never applied without agreement', () {
      // The core constraint of the whole coaching layer.
      final base = _plan();
      final logs = hardQualityLogs(base, [0, 1, 2]);
      final progress = PlanProgress(plan: planWithLogs(logs), weekLogs: logs);
      final proposal = propose(progress).firstWhere((p) => p.id == 'drop-quality');
      expect(proposal.directive.suppressQuality, isTrue);
      // It exists to be accepted; `generate` with no directive is untouched.
      expect(_plan().weeks.any((w) => w.qualityCount > 0), isTrue);
    });
  });

  group('the directive survives storage', () {
    test('suppressQuality round-trips', () {
      const original = PlanDirective(suppressQuality: true, capVolume: true);
      final restored = PlanDirective.fromJson(original.toJson());
      expect(restored.suppressQuality, isTrue);
      expect(restored.capVolume, isTrue);
      expect(restored.isNotEmpty, isTrue);
    });

    test('an old stored directive reads as not suppressing', () {
      final restored = PlanDirective.fromJson({
        'capVolume': true,
        'targetDaysPerWeek': 3,
      });
      expect(restored.suppressQuality, isFalse);
    });

    test('it appears in the human-readable summary', () {
      expect(
        const PlanDirective(suppressQuality: true).summary.join(),
        contains('hard sessions'),
      );
    });
  });
}

/// The fitness assessment a generated plan was built from, for re-validating.
FitnessAssessment assessFitnessFor(TrainingPlan plan) =>
    assessFitness(_races(), testToday);
