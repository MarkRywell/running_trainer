# AGENTS.md

## Project

Flutter running-plan generator (`ai_running_trainer`). Flutter 3.47.1 / Dart 3.13.1. Metric units.
Only third-party dependency is `shared_preferences`; the typeface is bundled, not fetched.

## Commands

```bash
flutter pub get
flutter test                        # 642 unit + widget, mocked storage
flutter test integration_test -d emulator-5554   # 12 on-device, REAL storage
flutter analyze                     # must be clean
flutter build web --release
flutter build apk --profile         # NOT --debug, see Android notes
```

To view it: `python -m http.server 8732 --directory build\web`, then open Edge. `flutter run -d edge`
exits as soon as the debug connection drops, so it is not a reliable way to leave the app on screen.

## Architecture

```
lib/
  domain/           PURE DART — must not import package:flutter
    models/         profile, race, goal, plan, week_log, plan_directive
    engine/         vdot, riegel, zones, fitness, volume, validation
    plan/           generate.dart (entry), beginner_plan, race_plan
    progress.dart   completion, adherence and orientation over a plan
    coaching.dart   pure proposals from logged experience
    units.dart      Pace, formatting, clampD/clampI
  app/              controller.dart (ChangeNotifier), storage.dart
  ui/
    theme.dart      AppColors, ZonePalette, AppType, shared components
    goal/           goal_editor.dart — the goal form, shared
    onboarding/, plan/, profile/
  main.dart
assets/fonts/       Barlow 400/500/600/700 + OFL.txt
test/domain/        the real suite — see per-file counts
test/widget_test.dart  runs at 400x900
```

`generate({profile, races, goal, startDate})` is the single entry point. The plan is a **pure
function** of those four inputs and is never persisted — `TrainerController` regenerates it on load
so plan and profile cannot drift apart.

## Coach proposals (adaptation)

`domain/coaching.dart` turns logged experience into proposals. **Nothing is ever applied
automatically** — the product premise is "never too hard", which is a promise about the runner's
experience, so the runner decides the plan changes. A silent rewrite is nagging with extra steps.

- `propose(PlanProgress)` is pure and returns 0–2 candidates:
  - `cap-volume` when `looksTooHard` (≥3 weeks rated 8+). Holds volume flat from the **first
    incomplete week**, so completed weeks keep their shape — the past is not rewritten.
  - `fewer-days` when `looksUnderserved` (adherence <70% *and* nothing felt hard). That's a schedule
    problem, not a fitness one, so the answer is less work, not more. Floors at 3 days.
- `PlanDirective` is passed into `generate()` as an explicit input, so the plan stays pure.
- **Declining is keyed on the hard-week count, not a boolean.** Declining after three hard weeks
  still re-surfaces if a fourth appears — staying silent while it gets worse is the wrong default.
- **Every accepted change is reversible** via `revokeProposal`. Accepting must not be a trap.
- `typicalPrescribedSessions` uses the **mode** across logged weeks, not the last week: a race week
  prescribes two sessions and a cutback fewer, so either would misrepresent what's being asked.
- Cutbacks and the taper still apply while the cap holds.

## App name

User-visible name is **Running Trainer**, and it is set in five places, not one:
`web/manifest.json`, `android/app/src/main/AndroidManifest.xml` (`android:label`),
`ios/Runner/Info.plist` (`CFBundleDisplayName` + `CFBundleName`),
`windows/runner/Runner.rc` (`FileDescription` + `ProductName`), and
`pubspec.yaml` `description`.

**The Dart package name is deliberately still `ai_running_trainer`.** Renaming it would rewrite
every import in 20+ files for zero user-visible benefit. Do not "tidy" it up.

`applicationId` is still `com.example.ai_running_trainer` and **blocks any store submission** — the
user chose to defer it. A reverse-domain ID is needed and it cannot be changed after publication.

## Editing details, and the three ways to redo a plan

**Profile and race times have always been persisted** — `storage.dart` writes all six inputs. The gap
was that only the *goal* was editable, because `setGoal` was the controller's only mutation.
`setProfile`, `setRaces` and `restartPlan` now join it.

**`estimatedWeeklyKm` was a model field the form never asked for**, so it was always null and the plan
seeded from `_impliedVolume(fitness)` — a marathon-pace guess. A 52:25 10K implies ~31 km/week, which
was being handed to a runner doing 15 km on three days. It is now an optional question on the
running-history step, and the details screen says out loud when the guess is in use.

**`copyWith` cannot express "clear this".** `Optional<T>` in `models/profile.dart` distinguishes an
omitted argument from an explicit null. Without it, a form can set a value but never clear one, and
"I removed this" silently becomes "I never had this". `RunnerProfile.cleared(...)` is the readable
wrapper over the three nullable fields.

- **An edit keeps logged weeks.** The start date does not move, so `weekKey`-based completion carries
  over. Same property that makes `setGoal` safe.
- **A restart clears them.** New start dates mean new keys, and carrying old weeks across would credit
  a fresh block with work done in the last one. Coach state is cleared too — an accepted cap was a
  judgement about the block that just ended.

**`ProfileEditor` and `RaceEditor` are shared components**, composed by both the wizard and the details
screen, exactly as `GoalEditor` already was. `Pill`, `Counter` and `FieldLabel` moved to `theme.dart`
because they had three private copies. `formatTimeInput`/`parseTimeInput`/`formatDate` moved to
`domain/units.dart` — pure formatting with no Flutter dependency, duplicated in three files.

**A shared widget must be able to render a *part* of itself.** The first extraction gave
`ProfileEditor` a `showName` boolean and left it rendering every field, so wizard step 2 was step 1
minus the name box — same heading, the same age question, and every history field as well. `ProfileSection`
(aboutYou / runningHistory / all) is the fix: a boolean cannot describe "the other half". There is a
test asserting the two steps share no field. **Extracting a form is not the same as parameterising it** —
check that each consumer sees what it should.

**Destructive actions must pop before they mutate.** Clearing the plan turns every screen that reads
one into a loading state, so a screen left on the stack becomes an infinite spinner over the
onboarding form. Both destructive actions use `popUntil((r) => r.isFirst)` *then* mutate. This was a
real bug, caught by a `pumpAndSettle` timeout in the widget suite.

## The long run must be the longest run

**Found via a real report, not a hypothetical.** A runner with two years' training, three days a
week, 15 km a week, a 24:10 5K and a 52:25 10K was given a **3 km long run and 4.9 km easy runs**.
Four separate faults, all now fixed and pinned in `test/domain/regression_real_runner_test.dart`:

- **`isBeginnerPath` used an absolute 24 km/week threshold.** A three-day runner cannot reach that
  without already doing the long run it was gating, so a two-year athlete was routed to a beginner
  block. The volume gate is now **scaled to days per week**, and can only demote someone who *has*
  race data — without an anchor race there are no paces to derive, so no-race-data is always the
  beginner path.
- **The long run's share was a flat 30%.** Below four run days that is arithmetically impossible to
  keep the long run longest: the remainder splits across fewer days, so each easy day exceeds it.
  `longRunShare` is now 60% / 45% / 30% for 2 / 3 / 4+ days.
- **`maxLongRunFraction` was a flat 32% and sat *below* the 30% target**, so `enforceSafety` silently
  undid the generator. `maxLongRunFractionFor` is now day-aware and always sits above
  `longRunShare` — there is a test asserting exactly that coupling.
- **The share cap is a fixed point, not a single trim.** The long run is part of the total it is
  measured against, so the requirement is `L ≤ f(R + L)`, i.e. `L ≤ f·R/(1−f)`. Capping to
  `f·(R+L)` instead leaves it fractionally over its own cap.

**The related lesson: a 3-day week cannot host a 30% long run, and flat constants hide it.** Any
per-session constant must be checked against the smallest week that can contain it. `easyRunCapKm`
and `qualityDistanceKm` exist for the same reason — a flat 9 km tempo was 57% of a 15 km week, and
an 18 km *recovery run* appeared once a long run hit its distance cap.

## A week's reported volume is what its sessions prescribe

`enforceSafety` normalises `targetVolumeKm` to the sum of the workouts, unconditionally, and
normalises *before* the long-run cap so the two cannot disagree. Generators build a workout list and
then trim it — via `applyDayConstraint`, the race-week shakeout, the distance cap — so a target
derived from the pre-trim list is a budget the runner cannot meet. A peak week once prescribed two
quality sessions while budgeting for one: 8 km more running than the plan claimed.

`beginner_plan.dart` must call `applyDayConstraint` **before** computing the volume. `race_plan.dart`
must route race weeks through `enforceSafety` too. `plan_test.dart` asserts
`closeTo(targetVolumeKm, runVolumeKm)` across ten plan shapes — that assertion is the guard.

## Heart rate is an annotation, never an input

`RaceResult.averageHr` is `int?`, serialized only when present. It reaches **no** part of plan
generation — not `vdotFor`, not `riiegel`, not `zoneAnchorPace`. Three notes come off it, all
arithmetic on the runner's own data:

- **Goal-realism caveat** (in `validation.dart`): their anchor race was run at pace X on HR H; if the
  goal pace is >5% faster, say it will demand more than they have sustained. `FlagSeverity.info` only.
- **Out-of-band sanity** (in `fitness.dart`): wide per-distance bounds, a 5K at 205 is a typo. Error
  detection, not zone boundaries.
- **Mixed devices**: some races with HR and some without is disclosed.

**`test/domain/heart_rate_guard_test.dart` is the enforcement.** It asserts a plan generated with and
without HR is identical — volumes, session distances, every zone's pace, VDOT, and the flag set. It
was written *before* the field existed and has been verified to fail when HR is wired into
`vdotFor`. The field's doc comment points at it. If you add a `plannedDistanceKm` to `Workout` and
want the same guarantee, copy the pattern rather than trusting the comment.

## Per-session logging, bounded by the plan

`SessionLog { dayOfWeek, felt, actualKm? }` nested in `WeekLog`, **one per prescribed session, capped
at `maxSessionsPerWeek` (7)**. Phase 5 rejected a per-run log as unbounded; that objection is about
free-form history, not this. A 20-week block is ~140 records. `sessionsDone`/`actualKm` on `WeekLog`
are **not** removed — `looksUnderserved` and `volumeAdherence` consume them.

- **`Workout.weekday` exists so a session log can be matched to the session it refers to.** Without
  it, "the tempo was hard" and "the long run was hard" are indistinguishable — two problems with
  opposite fixes. Set by `attachWeekdays(workouts, pattern)` in `volume.dart`, once per generator,
  because a new session type forgetting to attach its own day fails *silently*.
  **`enforceSafety` rebuilds the long run and must carry `weekday` across** — losing it there would
  detach a capped long run from its day, which is precisely the signal this feature produces.
- **`markWeekComplete` keeps `sessions`.** It is still authoritative for the *self-reported* week
  fields (`clearedForQuickDone`), because stale self-report is what makes the button unpredictable.
  Per-session records are what the runner actually did and are the most expensive data here. Un-marking
  still wipes everything.
- **One three-state tap, in the session detail sheet** — a place the runner already opens. A row of
  controls on the week itself would be 4–7 taps and would not get done on bad weeks.
- **Unrecorded is neutral, never bad.** `observedIntensity` returns null when nothing is recorded.
  `observedIntensity` lives in `progress.dart` (not `generate.dart`) because `validate` runs *before*
  the plan exists and both callers need it — same shape as the existing `adherenceByWeek`.

## `drop-quality`: a more specific answer than `cap-volume`

`PlanDirective.suppressQuality` removes hard sessions and leaves long runs and easy days alone. It
fires at **3+ individual hard quality sessions**, not 3 weeks — a week can hold two, and the two units
are not the same evidence. Two hard days is a bad week, not a miscalibration.

It is safe by construction: hard work becomes easy, so `easyFraction` can only rise. Asserted. Total
weekly mileage may drift a couple of percent either way (the unsuppressed week loses volume to the cap
that keeps quality shorter than the long run); the invariant tested is `hardVolumeKm == 0`, not an
exact total.

`slow-down` is informational and changes nothing — it fires at 4+ hard *easy-day* sessions and says
the prescribed pace may be too fast, because that is usually a pace to hold rather than a plan to
change.

## A trained plan must contain hard sessions — enforced

**Found via a second real report.** A runner with a 1:56 half marathon, a 52:25 10K, 35 km a week,
four days a week and a 10K goal in February was given twelve weeks of `Easy | Easy | Long` and no
hard sessions at all.

**Cause: `monthsRunning` was stored as `3`.** The runner meant three *years*. The experience counter
was a bare month stepper with **no unit stated anywhere**, and "3" is a natural answer to "how long
have you been running" if you think in years. `isBeginnerPath` read three months, took the
`monthsRunning < 12` branch, and returned the beginner base block — which has **zero quality sessions
by design**. Everything else in the profile was correct and could not save them.

- The counter now speaks in **years**, and answers in the same unit it asks
  (`ProfileEditor._yearsRunningLabel`). An 18-month history shows as 2 years, because rounding *down*
  would put someone on the wrong side of the 12-month gate.
- **The volume gate no longer demotes on its own.** A single self-reported number must not override
  months of training plus race data.
- `test/domain/hard_session_invariant_test.dart` asserts **a trained plan carries at least one tempo
  or interval in every non-cutback, non-taper week**, at 3/4/5/6 days a week, base and race blocks —
  and that the beginner block has none, so the two paths are distinguishable by construction. That
  assertion is the guard, and it did not exist before this bug.

**The lesson, and it repeats last session's: two wrong diagnoses in a row, both from reading the
source instead of the state.** The app could not tell the runner either — a beginner route renders
identically to a deliberately all-easy plan. When a rendering ambiguity hides the cause, instrument
the real stored state. Both this bug and the earlier long-run bug came from the runner's numbers,
never from a test; when a report contradicts the code, the stored data wins.

Still open, unchanged by this fix:

- **The week view does not say when a plan has no hard sessions**, so a beginner route reads as a
  design choice rather than a routing outcome. This is what made the bug invisible to the runner.
- **`suppressQuality` is blunt at 3 days a week** — resolved: it now shortens a lone
  quality session rather than deleting it. See "drop-quality has two shapes".
- **Nothing surfaces the volume ceiling.** A runner at 45 km/week peaks at `45 × 1.35` and then watches
  volume flatten for weeks with no explanation. The plan is behaving correctly; the runner is not told.
  `_impliedVolume` already discloses "we are guessing your mileage" — the equivalent note for "you have
  maxed out" does not exist.
- **A short block still gets a periodised shape it has not earned.** A 9-week 10K block is told it is
  building toward a peak. It is closer to maintenance-plus-taper, and while the "Only N weeks to race
  day" flag says so, the phase labels do not.
- **A cutback can still land in a short race-specific phase and empty it.** Now that cutbacks are 100%
  easy in every phase again, a two-week specific phase can hand its only rep week to a deload. The fix
  is to *place* cutbacks — skip one when the phase it would land in is only two weeks long — not to
  exempt a phase from deloading. See "A cutback is a deload in every phase".

Resolved since, in "Rep formats and a real taper" and "A rep count is a training decision":

- ~~Without a goal race, intervals are structurally unreachable.~~
- ~~No 400m or 1000m rep formats.~~
- ~~The taper has no quality session at all.~~

## Rep formats, and a taper that keeps its intensity

**Found via a real report, twice in one.** A runner at 45 km a week on four days, with nothing to race,
reported two things: their only speed session was ever a tempo, and a taper that opened at 40.2 km off
a 59.7 km peak did not look like a taper. Both were correct, and neither was a tuning problem.

**Intervals needed a goal race to exist at all.** `_quality` emitted a set only when
`phase == PlanPhase.specific`, and `buildTrainedBasePlan` was `List.filled(12, PlanPhase.base)`. There
was no code path from "trained runner, no race" to a repetition session. `Workout` had no rep field
either — the format was two hardcoded constants interpolated into a description string, so 400m x 10
and 800m x 5 were not representable, only 3 min on / 3 min jog.

Four rules, each of which is a way the obvious implementation is wrong:

- **Rep distance picks the pace.** `RepFormat` carries its own `zone`: short reps at interval effort,
  long ones at threshold. A rep format that is only `{distance, count, rest}` makes 2km x 3 mean three
  interval-pace kilometres, which is a different and much more damaging session than the name implies.
- **The rep count is solved, and the format falls back to a *shorter* rep.** `solveSet` takes the
  largest set that fits `qualityDistanceKm`. A week too small for ten 400s gets shorter reps, never a
  truncated set — two 400s is not a set of 400s. Fixing the count instead would mean the session's
  distance came from somewhere else and the week stopped adding up.
- **`hardFractionOfDistance` is derived, never assumed.** `intervalHardFraction = 0.32` was one flat
  constant applied to every interval session, and it is roughly right for exactly one format. 400m x
  10 at 90s recovery is ~47% hard by distance and 2km x 3 is ~70%, so `hardVolumeKm` — and therefore
  the 80/20 check — was a fiction for every format but one. 0.32 is now a fallback.
- **A rebuilt `Workout` must go through `Workout.withWeekday`.** `_withWeekday` in `volume.dart` was
  a hand-written second copy of the field list; when the rep fields were added it silently dropped
  them, and a session titled "800 m reps" rendered with no reps on it. The title still looked right,
  so nothing reported it. **A copy of a field list is a place fields go to die.**

**At most one set per week**, which is a hard rule. Two sets pushed `easyFraction` to 0.75 against a
0.77 floor, so a double-quality week is tempo plus set. That also required the 22% quality budget to be
a **week-level** budget split between sessions: giving each session the whole of it meant a
two-quality week prescribed 44% of its volume as hard work.

**`qualitySessionsFor` is day-aware, and that fixed a silent mismatch.** It returned 2 for a four-day
specific week while the placement guard `i == 3 && days > 4` could never fire — index 3 *is* the long
run on `[1,3,5,7]`. The second session fell through to the easy branch, so the week budgeted two hard
sessions, prescribed one, and still summed to its target. Every invariant passed. `qualitySlots` derives
the positions from the day count, and the test asserts the **count**, not merely that a hard session
exists. Alternating on `weekInPhase` rather than the absolute week keeps the set count from depending
on where rounding put the phase boundary.

**The taper dropped volume and sharpness together.** `qualitySessionsFor(taper) == 0`, so the taper
had *no* quality work at all while `PlanPhase.taper`'s blurb promised "Volume down, intensity kept" —
a copy/code contradiction, which by this repo's history is the class of bug that ships. The final
taper week now carries one goal-pace set, shape chosen by goal distance (5K 4x800m, 10K 3x1200m, half
and marathon 2x2km at marathon pace), exempt from `suppressQuality` and budgeted against the long run
so it can never be the week's longest run. Taper work is **sharp, not big**: under 25% of the week's
volume.

**Two more taper faults, both found by the tests rather than by reading:**

- The drop was `t *= 0.70` compounded per week, so a three-week taper ran 70/49/34% of peak and the
  *first* week sat at ~70%. Replaced with an explicit `taperSchedule` of fractions of peak
  (3wk 0.60/0.50/0.42, 2wk 0.55/0.45) — a compounding rate cannot express "front-loaded", and an
  explicit schedule is directly assertable rather than reverse-engineered from its own output.
- The 3 km easy-day floor **inverted the taper**: the final week's budget fell below `3 x easyDays`,
  the floor took over, and the week came out *larger* than the one before it (22.7 km against 19.1).
  A shorter run in the taper is not a defect, so `taperEasyRunFloorKm` comes down to 2.0.

**Three pre-existing bugs surfaced while doing this, all of which had been hiding:**

- **`qualityDistanceKm` had no ceiling at all.** It was `base.clampD(base.clampD(5, 9), 15)`, which
  reads as "clamp to 5-9, then allow up to 15" and does neither: the inner clamp produced 9, the outer
  clamped *9* into `[base, 15]`, and since 9 < base it returned `base`. Above ~41 km a week a quality
  session grew without limit. Nothing caught it because every fixture was a small week. This is the
  same shape as the old `maxLongRunFraction` fault — a constant that silently undid the generator.
- **A copy of the `Workout` field list**, described above.
- **`_qualitySessionsFor` tested `count <= 1`**, so a cutback or taper week with `count == 0` built a
  tempo, subtracted 5.9 km from its easy budget, and never placed it — every taper week came out ~6 km
  short and the taper stopped descending. Written by me, in the code being changed, and caught by the
  taper test an hour later.

`test/domain/rep_format_test.dart` and `test/domain/taper_methodology_test.dart` are the guards.

## A rep count is a training decision, not a budget fill

**Found via a real report, second round.** The same runner, after the fixes above, sent back the plan the
app produced. Three of its complaints were about arithmetic that was *faithful to the code* and wrong
anyway — which is the more interesting kind of bug, because "it's calculated" is the answer that stops
anyone looking further.

- *"The 800m reps on W4 has a bit too many reps."* Nine of them, and the code asked for exactly nine: the
  rep count was **the largest set that fits 22% of the week's volume**. On a 54.7 km week that is 12 km,
  and 800m reps go in until the space is full. **Nothing in that arithmetic represents a decision about
  how many reps to run.** A rep count is a training judgement; filling a volume space is not one.
  Ceilings are now 400m→12, 800m→6, 1km→5, 2km→3, and `solveSet` can only ever *shorten* a set.
- *"Taper week has no speed session."* Taper length was `totalWeeks >= 12 ? 3 : 2` — the same question
  asked of a 10K and a marathon, and the same answer given. It is now keyed on **race distance**, via
  `taperWeeksFor`: 5K/10K get one week, half/marathon two, or three when the block is long enough to
  have earned them.
- *"The goal pace is 5:49/km but my goal is 51:00, which is 5:06."* The copy said "your goal pace" while
  reading `paces.marathon`, which is the **fitness** anchor. For a marathon goal the two nearly
  coincide, which is why this survived a full test suite. For a 10K they were 40 s/km apart.

**The taper's pace is the one place the goal is allowed to appear.** Every other zone is fitness-anchored
precisely so a stretch goal cannot raise intensity above what the athlete has demonstrated
(`zone_anchor_regression_test`). `taperRepPace` reverses that for the race-pace session, floored at the
**repetition** pace rather than the marathon one: rehearsing the race pace *is* that session's
prescription, it happens once, and the goal has already been checked for plausibility by `validate`.
The floor still exists so a fantasy goal cannot produce a session faster than anything the athlete has
been asked to run. **The copy says which of the two it prescribed** — "your goal pace" or "your current
marathon pace" — because a runner told one and handed the other has been told something false.

**Race-specific work is threshold work. Only peak is fast.** The zone was baked into `RepFormat`, so a
10K athlete's race-specific phase prescribed 800m at interval pace — *faster* than both their threshold
and their goal pace. That is 5K-effort work sitting in the phase meant to prepare them for a 10K, and
it left peak as the only place with anything sharper. `repZoneForPhase` now owns the zone, and the test
parses the pace back out of the description so a relabelled zone cannot pass.

## The card has to say what the session is

**Every quality session in the app was ~12 minutes longer than its own card claimed.** The copy
described the warm-up and cool-down in *minutes*; the session was budgeted in *kilometres*, so the easy
legs inflated to fill whatever was left. A 10.4 km tempo read "10 min warm-up … 5 min cool down" and
prescribed 27 minutes of easy.

This matters more than a copy bug. A runner asked for more than the card says cannot tell that is what
is happening, and **"it feels like too much" is not a report anyone files** — it just becomes a reason to
stop running the session. The tempo and every set now name the easy legs in distance, and a test asserts
the named distances sum to the session. The test found a *third* copy of the old string in
`generate.dart`, which is the argument for asserting on output instead of reading the source.

## Two more faults in the specific phase, both pre-existing

- **The goal-pace block in a race-specific long run reported `hardFractionOfDistance: 0`.** A 15.6 km
  specific long run with 5 km at marathon pace is 33% hard and the app called it 0%, so `hardVolumeKm` —
  and therefore the 80/20 invariant the whole plan is built to satisfy — was computed on a plan that hid
  its own race-specific work. `longRunHardFraction` derives it, and re-derives on a trimmed run, because
  the block is a share of the run.
- **A cutback could empty a short phase.** `allocatePhases` splits by percentage and `isCutbackWeek`
  then lands wherever it lands, so a 2-week specific phase could hand its only rep week to a cutback. The
  reported plan's week 5 was exactly that: the phase meant to prepare a runner for their 10K contained
  no race-specific work. Deload now exempts specific and peak. **Base is deliberately still exempt** —
  dropping a deload's tempo is the entire point of a deload.

## A 10K taper week has no long run

Not a copy change: a different week shape. At 5K and 10K there is no glycogen debt to clear and no
race-specific durability to build, so the long run's only remaining job in the taper week is to be the
biggest thing in it — the opposite of the point. The week's volume goes into short easy runs and one
sharp session instead.

Two things this exposed, both of which would have shipped quietly:

- **A week with no long run has one *more* easy day, not one fewer.** The long run was the day that is
  not easy; removing it returns a day to the pool.
- **The taper session was budgeted from the long run, so a zero long run meant a zero budget** — and the
  taper's one hard session silently collapsed to a single rep. A token session is the exact opposite of
  the point. With no long run it is sized as a share of the week, under the same 8 km ceiling, and easy
  days get `maxTaperEasyRunKm` since there is no long run for them to stay under.

## `allocatePhases` takes a required goal, on purpose

`goal` defaulted to null, and null meant **zero taper weeks** — a race block with no taper at all,
produced by a caller who simply forgot. It is required now. A parameter whose absence silently removes a
phase is a trap, not a default.

## Three bugs of my own, from this round

Worth recording because two of them were found by tests written *for* the change and still got through:

- **The redistribution fix that wasn't.** A solved set now lands under its budget, the easy days are
  capped against a long run that is itself still growing, and the week came out 9% short of the volume
  curve. I put the remainder on the long run — which **breached the long-run growth limit**, because
  `capLongRunGrowth` measures against *last* week's long run and I was calling it from inside `_buildWeek`
  with this week's. Reverted. The honest behaviour is to prescribe the smaller week and let
  `enforceSafety` report what was actually prescribed, not to break a growth limit to make arithmetic
  come out. The test that caught it was asserting a limit I had just edited the code around.
- **A stretch-goal test with a 40-minute half marathon in it.** I meant "an ambitious goal" and typed a
  10K time. It "proved" a session ran 3:41/km, which was the repetition floor doing its job on a
  nonsense input. A test that passes for the wrong reason is worse than one that fails.
- **`maxRepsFor` inferred the ceiling from a generated plan.** A 120 km week's 2km set only reaches 2
  reps, so the helper reported the ceiling as 2 and the assertion against 3 failed — correctly, for the
  wrong reason. The ladder is now readable via `repFormatFor`.

**One bound was loosened rather than the code changed, and it is worth being explicit about.**
`suppressQuality` now moves a week's volume up to 15% rather than 10%. That is real: a set stops at its
ceiling instead of filling its budget, so an unsuppressed week prescribes *less* than the curve intended,
and the easy days cannot reclaim it. The invariant that actually matters — everything the week gains is
easy — is unchanged and still asserted. Volume may move either way; it just may not move by a quality
session's worth in a week that has no quality session.

## Three days a week is easy, speed, long

**The recovery run was on the wrong side of the long run.** It carried the
description *"Deliberately slow. Absorb the long run, do not add to it."* — and
at three days a week the pattern is `[1, 3, 6]`, so that card sat on the
**Monday before** the Saturday long run. It was absorbing nothing, and the copy
said so out loud on the wrong day.

| days | pattern | long run | first run day | gap |
|---|---|---|---|---|
| 3 | `[1,3,6]` | **Sat** | Mon | Sunday is already free |
| 4 | `[1,3,5,7]` | **Sun** | Mon | **none** |
| 5 | `[1,2,4,6,7]` | **Sun** | Mon | **none** |
| 6 | `[1,2,3,4,6,7]` | **Sun** | Mon | **none** |

So the recovery day is *earned* at four or more and pure cost at three. At three
it is also a third of the week's runnable days spent **below** easy pace, which
is the one pace that builds nothing. A three-day week is now
`Easy / quality / long run`, which is what the beginner block has always done —
`_easyRun` for every non-long day, never a recovery day. The trained path was the
odd one out.

**The gate is the pattern, not a day count.** `longRunFollowsImmediately(pattern)`
asks whether the weekday after `pattern.last` is also a run day. Keyed on the
day count it would be a magic number that silently breaks the next time
`weeklyDayPattern` changes; keyed on the pattern it states the reason.

**The swap is zone-only, and that is checked.** Same `distanceKm`, same
`easyRunCapKm` cap, and recovery and easy are both `isEasy`, so `easyFraction`
and the long-run share cannot move. A test asserts the week still sums and that
neither zone escapes the easy classification.

The three-day easy card carries an explicit permission slip — *"if the long run
wrecked you, go slower"* — because the safety valve has to be **on the card**,
not merely intended. A runner who is genuinely cooked after a long run needs to
know they may.

## A week can never budget a session it has no day for

`qualitySlots` returned indices from a fixed candidate list without checking
them against the week length, so `qualitySlots(2, 1)` returned `[3]` for a week
whose only positions are 0 and 1. The caller built the session, subtracted its
distance from the easy budget, and then had no loop iteration that could place
it — the same **budget-then-drop** fault as the four-day case, at the other end
of the range. Two days is unreachable through `generate()` (both generators clamp
to 3–6) but the function is public and takes a pattern directly.

The slot list is now **authoritative**: `_buildWeek` asks for what the week
*wants*, then sets `qualityCount = slots.length`. A week cannot budget a hard
session it has nowhere to put, and it returns fewer than asked rather than
pretending.

**Found by an existing test that was pinning a bug.** `goal_changes_the_plan_test`
asserted the goal block diverges from the base block at week index 4, and it now
diverges at 5. The cause was not the 3-day change: `_baseWeek` computed a tempo
distance and then suppressed the session that would have used it, so **every base
cutback under-prescribed by one tempo's length** while the race block — which
budgeted from the sessions it had actually built — did not. The two blocks
therefore disagreed on week 5 for a reason nobody had intended. Removing the
phantom tempo *lengthened* the shared prefix by a week. `qualitySlots` in
`_baseWeek` replaced a hardcoded `i == 1`, so the two paths now derive placement
from one function.

## Every build week keeps its speed session

The runner's own requirement: **a three-day week is easy / speed / long, and the
speed session is definitely there.** Enforced as an invariant test across 3–6
days and both trained paths.

One interpretation is recorded deliberately: **a cutback stays quality-free.** A
deload exists to absorb training, and putting a tempo in it removes the reason it
exists — it would also break the beginner block's "zero quality is safe" property
that `plan_test.dart` pins. So base cutbacks are excluded from the invariant and
every other build week carries one.

**Still not fixed, and sharper because of this:** `suppressQuality` at three days
a week. With three sessions, suppressing the one quality session leaves a week
that is entirely easy for the length of the coach proposal. The taper is exempt;
this bites in the build. It needs its own decision — probably that a three-day
runner's proposal *downgrades* quality rather than removing it — and was left out
of this change rather than folded in.

## Three days a week is a choice, and the app says so out loud

**A runner on three days gets one quality session, and for a lot of athletes that
is correct.** A VDOT 38 runner, three days, one threshold session a week is a
complete and sustainable arrangement — and the runner it came from described it
that way. Treating three days as a deficiency would be nagging about a sound
setup, which is the one thing this app exists not to be.

So the intervention is **disclosure, not prescription**:

- `_validateFrequencyAgainstFitness` fires at **three days and VDOT ≥ 45**. Both
  numbers are known and nothing was saying anything. `FlagSeverity.info`, and it
  never touches the plan — asserted by comparing week shape across two athletes
  of different fitness.
- **Four days does not fire, at any fitness.** Four days with one hard session is
  a normal arrangement.
- `minimumVdotsForTwoSessions` is a judgement, not a source, in one named
  constant. It sits above this codebase's existing beginner/trained boundary
  (VDOT ~35, from `defaultBeginnerMarathonEquivalentSecPerKm`).

**It is raised before `validate`'s `goal == null` return on purpose.** Everything
else in that function is about a goal, so a runner with nothing on the calendar is
the one most likely to be under-stimulated and least likely to be told.

**The day count had to be hoisted into `generate`.** It was resolved separately
inside the race block and the base block, both *after* validation had run, so the
frequency check had nothing to work with. One `resolveDaysPerWeek` now feeds all
three.

### What was deliberately *not* changed

The premise for changing the prescription at three days was that a fast runner on
three days is under-stimulated. The ladder already answers it: `_qualitySessionsFor`
gives `wantsSet = true` in **peak**, and the specific phase alternates tempo and
set. A three-day runner gets sets from about week 4 without being told to. The
only thing three days cannot fix is *frequency*, and no plan change fixes that —
only a fourth day does, which is the flag's whole job.

A test pins it, because "we decided not to change this" is exactly the kind of
decision that gets quietly reversed by a later contributor.

## `drop-quality` has two shapes, and which one applies is structural

The proposal said "this removes the hard sessions" and it did, at every day count
— so a **three-day week became 100% easy**, and a four-day week with two
remaining days of running became 100% easy. The runner had no middle option
between "my hard session" and "no hard running at all", while the proposal's own
words were *"you keep all the running, you lose the part that is not working."*

- **One quality session in the week** (three and four days; and every *base* week
  at any day count, since base has one) → **shorten it** to
  [suppressedQualityScale], which is 60%. One knob, and both session types
  respond: a tempo gets shorter, and a set gets fewer reps because `solveSet`
  solves to whatever room it is given.
- **Two quality sessions** (five and six days in specific and peak) → removed
  outright, as before. Dropping both still leaves a week of running that is simply
  an easy one, which is a proportionate response.

The rule keys on **session count, not day count** — an earlier framing said "that's
three and four days" and was incomplete, because base weeks have one session at
five and six too. The coefficient, the test that a shortened session is not a
token (>40% of the original hard volume), and the proposal copy all follow from
the one rule.

## A cutback is a deload in **every** phase

There was a period where specific and peak were exempted from cutbacks, so that a
two-week phase could not lose its only rep week to one. That made cutbacks do two
contradictory things at once, and **"keep the hard work" is not a deload under any
reading of the word**. The runner's instruction was unambiguous: a cutback is
100% easy, to absorb the weeks before it.

The risk that exemption was papering over is real and is now **visible rather
than hidden**: `allocatePhases` splits by percentage and `isCutbackWeek` lands
wherever it lands, so on a short block a cutback can fall in the race-specific
phase and leave it without a rep week. **The fix for that is to place the cutback,
not to exempt a phase from deloading** — and it is not done yet.

The `>=1 quality session` invariant therefore covers *common* weeks and exempts
all cutbacks, which is what "common" was always meant to mean.

## A session's pace is a fact, not something to infer from its zone

**Found via a real report, and it was the second half of a fix I had already
made.** A runner's taper card read **5:46/km** while the same session's own
description read **5:06/km**. The previous round had corrected the *description*
to the goal pace and left the number on the card, which is the part a runner reads
first. Two numbers for one session, on the session that matters most.

The cause is structural, and no amount of picking a different zone fixes it:

```
ladder:  rep 4:28   int 4:53   thr 5:09   mar 5:46   easy 6:36
goal:    10K 51:00  = 5:06/km
```

**The goal pace is not on the ladder at all.** The card derived its number from
`paces.forZone(workout.zone)`, and `marathon` gave 5:46. Choosing the nearest rung
would shrink the error rather than remove it, because there is no rung at 5:06.
A zone is a five-rung classification of a continuum; real prescriptions do not
land on the rungs.

- **`Workout.prescribedPace`** is the number, nullable. `Workout.displayPace(paces)`
  is `prescribedPace ?? paces.forZone(zone)`, so the fallback stays the common case
  and only off-ladder sessions need the field. A test asserts a plain tempo still
  resolves from its zone, or the field would be pointless.
- **`TrainingPaces.nearestZone(pace)`** classifies for *colour only*. The taper's
  race-pace set was labelled `marathon`, which painted the hardest-scheduled
  session of the taper as the easiest thing in it — 5:06 is faster than that
  athlete's marathon equivalent of 5:46. It now reads as `threshold`, which is
  what 5:06 is for them.
- **The goal race had the same fault.** Its card showed the marathon-pace number
  for a race being entered at 5:06 — ~40 s/km wrong on the one session where the
  number is the point. It carries `prescribedPace` now; its zone stays `marathon`,
  because a race is a race and the card is already accented.

**The test is the generalisation of the warm-up one.** For every session in a real
plan: *the pace the card shows equals the pace its description names.* The card
and the body must not state different numbers — that is the invariant, and it is
the same one the "10 min warm-up" bug violated in distances.

Both render sites in `plan_screen.dart` (the week-list card and the session
sheet) read `workout.displayPace(paces)`. The zone *legend* in `review_screen.dart`
iterates zones rather than workouts and is correctly unchanged — a legend has no
session whose pace it could contradict.

## A form that emits on every keystroke must not reseed itself

**Found on a physical Samsung A35, and invisible to 630 tests.** A three-part
finish time could not be entered: `1:59:00` refused the second colon. The first
colon worked, and **that asymmetry is the tell**.

`GoalEditor.didUpdateWidget` guards its resync with `if (widget.value != old.value)`,
and the comment above it says the guard is there so "every keystroke" does not
reset the field being typed into. **`GoalRace` had no `==`, so that was an identity
comparison** — every emit produced a new instance, the comparison was always true,
and `_seed()` rewrote the field from `formatTimeInput` on every single character.

The asymmetry, traced:

| typed | field | `parseTimeInput` | what happened |
|---|---|---|---|
| `1` | `1` | null (one part) | no goal saved yet → `_emit` returns, no emit, no rebuild |
| `:` | `1:` | null (`int.tryParse("")`) | no goal saved yet → no emit — **first colon survives** |
| `5` | `1:5` | 1m05s | emits → parent `setState` → reseed → `1:05` |
| `9` | `1:059` | 1m59s | emits → reseed → `1:59` |
| `:` | `1:59:` | null | a previous goal now **exists**, so `_emit` emits it → reseed → `1:59` — **colon erased** |

**Every three-part time hits this**, because the second colon is the last character
typed and by then a successful parse has already created a previous value.

- **`GoalRace` and `RunnerProfile` now have value equality.** `RunnerProfile` is the
  identical fault one file over — same guard, five controllers, and its height /
  weight / weekly-km fields normalise the same way the time field did. Both are
  value objects with a `copyWith`; identity was never the semantics anyone wanted.
  Nothing else in the codebase compared two non-null goals with `==`, so no other
  behaviour changed.
- **`_seed` also skips the rewrite when the field already parses to the incoming
  value.** This is *not* what fixed the swallowed colon and the comment says so.
  It covers the quieter case: the runner taps a different distance while
  part-way through typing `1:5`, which legitimately fires the resync and would
  reformat it to `1:05` under their cursor.

### The lesson is about the test

**`tester.enterText` cannot see this class of bug.** It sets the whole string in one
go, so there is a single emit and a reseed that writes back an *identical* string.
The damage only appears when the text is built one character at a time and the
form's own normalisation changes it. The new tests type through
`tester.testTextInput.updateEditingValue`, one character at a time, with a
`pumpAndSettle` between each so the parent genuinely rebuilds.

**And each was verified to fail without its own fix** — the first attempt did not
reproduce the bug at all and passed with the `==` removed, which is the signal
that it was passing for the wrong reason. A test that cannot fail is not a test;
this repo has two prior instances of exactly that (`zone_anchor_regression_test`
is cited as having been written *before* the field existed, and the
`expectNoLayoutError` guard for the nav-bar padding).

**No `keyboardType` was set, deliberately.** A numeric or time keyboard removes the
colon on some devices, so the text keyboard — where a colon is available — is the
safer default here. The keyboard was never the cause: the first colon worked.

## The third taper week belongs to a marathon, and a cutback never opens a phase

**Found via a real report.** A runner with a half marathon 14 weeks out got a
**three-week** taper, a **two-week** peak, and a peak whose first week was a
deload — so the phase whose entire job is sharpening had **one quality week** in
it. They also could not find a cutback anywhere and assumed there wasn't one.

### Taper length was keyed on block length and ignored the distance

`taperWeeksFor` read `totalWeeks >= 14 ? 3 : 2` for every non-short race. Its own
doc comment said the third week was for "a **long block** for a **long race**",
but the code applied it to either. A 14-week half block got the marathon taper,
which stole two weeks of build: `base 4 / specific 4 / peak 2 / taper 3` instead
of `peak 3 / taper 2`.

```
5K, 10K                      -> 1
half                         -> 2, always
marathon, >= longBlockWeeks  -> 3      (18 weeks)
marathon, shorter            -> 2
```

The threshold is the judgement: a third taper week only pays for itself if there
is enough build to have accumulated the fatigue it exists to clear.

### Cutbacks were sampled, not placed — and sampling aligned with the phases

`isCutbackWeek` was `i % 4 == 0`. With `build = 10` the phases come out
**4 / 4 / 2**, so the boundaries sit at `i = 0, 4, 8` — *exactly* the sampled
positions. **In every block of that length both cutbacks land on a phase opening.**
It was arithmetic, not chance, and it is why the plan read as having no deloads:
both were simply quiet weeks.

A cutback now **never opens a phase**. It moves forward a week if it can, and
backward if it cannot — which happens whenever peak is the last build phase and
only two weeks long, because the week *after* peak's opening is the ramp into the
taper. Backward is the better fallback anyway: it puts the deload at the end of
the previous phase and brings the runner into the peak fresh.

If neither is available the deload **stays put**. A deload is a safety mechanism,
and dropping one to satisfy a tidiness rule is the wrong trade.

### The three call sites can no longer drift

`isCutbackWeek` had three callers — the volume curve and both generators — and
its doc comment records that they drifted once and produced 4 km long-run jumps.
It now takes the **phase list** and derives the build length itself, so there is
one way to call it and the sites cannot disagree. `cutbackWeeks(phases, every)`
returns the placed set; `isPhaseStart` is exported so the tests can assert against
the same definition rather than re-deriving it.

### The reported block, after

```
wk 1-4  base       47.3 -> 54.7          Tempo
wk 5    base       41.0  DELOAD
wk 6-8  specific    52.9 / 56.4 / 60.8   Tempo, 6x800m, Tempo
wk 9    specific   45.6  DELOAD
wk10-12 peak       54.0 / 60.8 / 60.8   12x400m x3   <- three quality weeks
wk13-14 taper      33.4 / 27.3          Tempo, 2x2km goal pace
wk15    race       25.1                 Half marathon
```

### The tests, and one I got wrong

The invariants are a table over every block length 6–20 × all four distances: no
cutback on a phase opening, the peak never entirely deloads, and a peak with room
to be eaten keeps ≥2 quality weeks. That last one is scoped to peaks of ≥2 weeks,
because a six-week block leaves a one-week peak and no amount of placement gives it
two.

**The first version of the phase-opening assertion had its predicate inverted** —
it asserted `phases[i] == phases[i-1]` was *false*, which flags a *mid-phase*
week as bad and would have passed a phase opening. It was caught by the diagnostic
script disagreeing with the test, not by the test failing loudly. Two assertions
in this repo have now been wrong in the same direction: **an assertion that cannot
fail is worse than one that fails**, and `expect(x, isFalse)` on a boolean
predicate deserves a second read.

## Zone anchor is CURRENT FITNESS, never the goal race pace — reversed

**Found via a real report.** A runner with a 52:25 10K, a 1:56:10 half and a 49:00 10K goal — a
6.7% improvement — was given threshold at 4:17/km and intervals at 4:01/km, and reported that
recovery (5:56) and easy (5:44) "are already a tempo run for me". All four numbers were correct.

**Cause:** zones were anchored on the *goal race pace*, a documented decision ("you train relative
to the race you are preparing for"). For a stretch goal that is actively harmful. Anchoring on
4:54/km shifted **every zone by the same −52 s/km**, so:

| zone | goal-anchored (was) | fitness-anchored (now) |
|---|---|---|
| recovery | 5:56 | 6:48 |
| easy | 5:44 | 6:36 |
| threshold | 4:17 | 5:09 |
| interval | 4:01 | 4:53 |

Threshold landed 12 s/km faster than a VDOT 38 athlete can sustain, and the easy→threshold gap
**collapsed from 87 s/km to 27**. That collapse is why easy felt like tempo: a runner whose easy is
27 s/km from threshold is running everything hard, and 80/20 becomes arithmetically unreachable.
The app flagged the goal `[caution] A stretch goal: 7% faster` and then built the training as though
it had been achieved.

**Now:** `zoneAnchorPace` ignores `goalDistance`/`goalFinishTime` entirely and always anchors on
fitness. The goal still shapes block length, volume curve, taper and race-week pacing — it just
cannot raise the intensity of a Tuesday session above what the athlete can currently sustain.

Three consequences, all asserted in `test/domain/zone_anchor_regression_test.dart`:

- **Absolute values, not just gaps.** A uniform shift preserves every *relative* relationship, so
  gap tests alone cannot catch this. The test asserts the ladder equals the published offsets applied
  to the fitness anchor exactly.
- **`minZoneGapSeconds` applies only to easy→threshold.** Recovery/easy (~12 s/km) and
  threshold/interval (~16 s/km) are deliberate neighbours in the source offsets; asserting a minimum
  there would invent a rule the ladder never had.
- **`derivePaces` no longer needs a goal to build one.** It used to be
  `goal == null && !hasData`, because the goal race supplied the anchor for a beginner with no race
  data. A goal is *not* a substitute for demonstrated fitness, so it is now `!hasData` outright.

## The splash screen is one idea in four places, and `#0E0D0D` is in five

The same logo-on-near-black appears on Android (pre-12 and 12+), iOS and the web. The artwork is
generated **transparent** by `tool\generate_icons.ps1`; each platform composites it over the app's
own base colour, so the background is declared once per platform rather than baked into the image.
Baking it in is what would let four copies of "black" drift apart.

| platform | artwork | background |
|---|---|---|
| Android <12 | `drawable/launch_background.xml` centred `<bitmap>` | `@color/splash_background` |
| Android 12+ | `windowSplashScreenAnimatedIcon` = `@mipmap/ic_launcher` | `windowSplashScreenBackground` |
| iOS | `LaunchImage` in `LaunchScreen.storyboard`, `contentMode="center"` | storyboard `backgroundColor` |
| Web | `<img>` in `web\index.html` | CSS `background-color` |

**`#0E0D0D` now appears in five files** and they must agree: `values/splash_background.xml`,
`values-night/ic_launcher_background.xml`, `LaunchScreen.storyboard`, `web/index.html` (twice - the
splash and `body`), and `web/manifest.json`'s `background_color`. Changing the base colour in
`lib/ui/theme.dart` means changing all of them.

**Three real bugs were fixed on the way, all of them "the template was never filled in":**

- **`NormalTheme` used `?android:colorBackground` under a `Theme.Light` parent** - a *white* window
  between the splash and Flutter's first frame, on a dark-only app. Both `values/` and
  `values-night/` now use `Theme.Black` and `@color/splash_background`. They are deliberately
  identical: the app is dark-only, so the system Dark Mode setting must not change what the runner
  sees before the first frame.
- **The iOS launch storyboard had a white `backgroundColor`.** A launch screen that does not match
  the app is a review rejection waiting to happen.
- **`web/index.html` had `<title>ai_running_trainer</title>`** - the *Dart package* name, not the app
  name, and the template's "A new Flutter project." description. That is a sixth place the
  user-visible name lives, which the five-place list in this file did not know about. The package
  name is still correct and still must not be renamed; it is just not a user-visible string.

**`postSplashScreenTheme` is deliberately absent from `values-v31`.** It belongs to
`androidx.core.splashscreen`, which this project does not depend on, and adding it fails the
resource link with `attr/postSplashScreenTheme not found`. Flutter's embedding already switches to
`NormalTheme` itself, via the `io.flutter.embedding.android.NormalTheme` meta-data in
`AndroidManifest.xml`. Hit this; do not add the dependency for it.

**The web splash is dismissed on Flutter's `flutter-first-frame` event, not a timer.** This was
checked rather than assumed: the string is genuinely dispatched in the compiled bundle
(`initEvent("flutter-first-frame",!0,!0)` then `dispatchEvent` on `window`), so a
`setTimeout` would have been a race. The 8s timeout is a *backstop* only, because a splash left
covering a working app is worse than no splash at all. The web build has no platform splash of its
own, so without this the runner stares at a blank dark rectangle for the whole engine boot.

**The generator verifies splash transparency** (corner alpha must be 0). Opaque splash art would
render as a dark rectangle sitting on the background rather than on it - the right colour, still
visibly wrong.

## Icons are generated from one master, never hand-edited

`assets/logo/mobile-logo.png` is the only artwork. `tool\generate_icons.ps1` produces every
launcher and app icon from it. **Change the master and re-run; never edit a file under
`web\icons`, `android\...\mipmap-*`, or the iOS `AppIcon.appiconset`.**

```bash
powershell -ExecutionPolicy Bypass -File tool\generate_icons.ps1
```

The source is an opaque 1254x1254 PNG with its near-black background baked in and **no alpha
channel**, so a plain resize is wrong in three separate ways:

- **It is off-centre** - the artwork sits at L=147 R=112 T=227 B=292, so anything that trusts
  the canvas is visibly off-balance.
- **Android 8+ uses adaptive icons.** The launcher crops to a shape chosen by the user's theme,
  and only the central 66.7% of the 108dp canvas is guaranteed visible. A raw square loses the
  runner's arms and the bar chart. Hence `mipmap-anydpi-v26/ic_launcher.xml`, a
  `ic_launcher_foreground` per density, and a solid `@color/ic_launcher_background`.
- **Web maskable icons** have the same problem at an 80% safe zone.

So the script flood-fills the background away **from the border** (a colour threshold would punch
holes in dark interior detail; a flood fill can only reach what is connected to the outside),
measures the artwork, feathers the alpha with one 3x3 box blur - the binary fill otherwise keeps
the source's hard staircase when scaled to 48px - and re-composites it centred on the app's own
`#0E0D0D` rather than the source's `#070707`, so the icon does not introduce a second "black".

**The adaptive artwork is placed at 0.62, not the 0.667 the spec guarantees.** The artwork is
1.35:1 so width is the limiting dimension, and at 0.667 it lands *exactly* on the safe-zone edge
and touches the launcher mask. Some OEM launchers crop past the spec, and the outermost speed
lines are the first thing lost. Verified on the emulator: the mask is a circle, everything inside.

**iOS icons must have no alpha channel at all.** App Store Connect rejects an icon that merely
*has* one, even when every pixel is opaque. Clearing to an opaque colour on a 32bpp canvas still
leaves the channel, so the pixel format has to be `Format24bppRgb` chosen up front. The first
version of the script got this wrong and the verification pass caught it.

The script **verifies its own output** and exits non-zero on: any iOS icon with an alpha channel,
adaptive artwork escaping the safe zone, or a non-square icon. A generator that cannot fail is not
a generator.

## What a goal may and may not change

**Found via a real report.** A runner set a 21K goal, saw no change to their sessions, removed it, and
saw no change again. Same paces, same distances. Read as broken. Two of the three things they noticed
are **correct**; one was a bug.

- **Paces must not change with the goal.** This is the zone-anchor rule, stated at the plan level. A
  goal that raises a Tuesday session above what the athlete can currently sustain is precisely how a
  stretch goal produces a plan that is too hard. `test/domain/goal_changes_the_plan_test.dart` pins
  all five zones as *identical* with and without a goal, because "the paces moved" is the exact
  symptom a runner reports as "it got harder when I added a race".
- **The first four weeks are identical either way.** Both blocks open with the same base build. The
  goal's real effects are block length (12 -> 17 weeks here) and everything from week 5 on:
  specific phase, intervals, peak, taper, and a race week that actually prescribes the race. The
  opening week matching is what generated the report, so the divergence point is *asserted* at
  index 4 - if a future change moves it, that is a decision to make consciously.
- **The notes were duplicated, and that was a real bug.** `validate` added one flag per
  `fitness.notes` entry, all titled "About your race data", so two notes rendered as two
  identically-titled cards stacked on top of each other. The runner's own data produced exactly two.
  Notes are one card joined by blank lines now. This was latent for a long time and only became
  visible when the measured-beats-projected note added a second one.

**Corollary, learned the hard way: "longest race wins" only applies *within* the freshness
window.** The reported runner's races, aged at 28 Sep 2026: 5K 19:50 (62d), 10K 42:02 (243d), 21K
1:35:34 (31d), 42K 3:23:26 (335d). The 10K and marathon are both outside the 183-day window, so the
**half anchors the plan** and the marathon is discarded with a note saying so. Reading "longest race
wins" off the comment alone gives the wrong answer here, and an earlier diagnosis in this same
report did exactly that.

Worth knowing: the anchor barely mattered to the *paces* (the half projects to a 3:19 marathon
equivalent against the real 3:23, so the ladder moves ~4 s/km). The stale data costs this runner
almost nothing in training pace. What it does cost is the 10K expectation, which falls back to a
projection because their 42:02 PB is 8 months old - the measured-beats-projected fix deliberately
does not reach across the freshness boundary.

## A prediction must never contradict a measurement

**Found via a real report.** A runner set a 10K goal of **42:00** with a PB of **42:02** from three
days earlier - a two-second target, no improvement at all. The app said:

> On your race times, you would expect around 44 for a 10K. 5% is at the hard end of what a
> training block delivers for this distance.

**Cause:** `assessFitness` picks the **longest** fresh race as the anchor, then built *every*
equivalent by projecting from it - including distances the runner had actually run. The marathon
(3:23:26) anchored the plan, and Riegel projected **44:13** for the 10K, overwriting the real
**42:02**. The goal check then scored 42:00 against 44:13 as a 4.6% stretch.

**Why the projection is systematically wrong in this direction.** `conservativeMargin` only
applies when *stretching out* (`ratio > 1.25`); Riegel going **down** in distance gets no margin
because it is already pessimistic. So the longest-race anchor reliably **overstates** short
distances. A marathon implies a 10K several percent slower than most runners actually manage.

**The rule:** a time the runner ran at distance `d` is a fact about `d`; a projection from a
different race is a guess about it. `equivalents[d]` now takes the freshest real result when one
exists in the freshness window, and projects only for distances with no result of their own.

- **The anchor is unchanged.** Choosing a different anchor is a separate decision with a much
  larger blast radius - it drives VDOT and therefore every pace in the plan. A test pins that the
  marathon is still the anchor so this fix cannot quietly make that change.
- **Disclosed, not silently corrected.** When a measurement and the projection disagree by more
  than 1%, a note says so. The file's existing rule is that the runner is told rather than left to
  wonder.
- **`test/domain/measured_beats_projected_test.dart`** is the guard: expectation, the equivalent,
  the absence of a stretch flag, and that a genuinely ambitious goal (38:00) is *still* flagged so
  the warning is corrected rather than silenced. It was verified to fail first, and the captured
  failure text reproduced the report verbatim.

**A formatting detail that hid this:** `_fmt` prints `44:13` as plain **"44"** - it only carries
seconds past an hour. A test asserting on `"44:"` never matches. Assert on the derived value.

## Bottom padding must account for the system nav bar

**Found on a real Samsung A35, invisible to the whole suite.** Scrolling bodies used a flat
`AppSpacing.xl` (32px) of bottom padding, measured from the bottom of the *screen*. On a device with
a home indicator or button bar the last stretch of that sits beneath the system navigation, so the
final component is clipped — the week strip's numbers, in this case.

**Why no test caught it, and why the first fix I tried also proved nothing:**

- The suite runs at **400x900**. An A35 is ~**384x832** — *shorter*. Nothing in the suite was ever
  short enough for the crop to appear.
- 32px happens to clear a **24dp** gesture bar, which is why the crop looked navigation-mode-specific.
  One UI's three-button bar is ~**48dp**, and 32 < 48.
- My first guard test asserted against a 24dp inset, so it **passed with the bug present**. A test
  that cannot fail is not a test. It is now bound to a single `navBar` constant used for both the
  fake inset and the assertion, and it was verified to fail first: tile bottom `800` where `784` was
  required, padding `32` where `80` was required.

**`AppSpacing.scrollBottom(context)`** adds `MediaQuery.viewPaddingOf(context).bottom` to the base
padding, and every scrolling body uses it. Four screens carried the same literal and would
otherwise drift apart again.

## Date pickers start at today

Both defaults pre-selected a date the runner then had to scroll *out of*, which reads as though the
app picked the date for them: a race result opened 60 days in the past ("2 months ago" on screen),
and a new goal race opened 126 days ahead. Both are now `DateTime.now()`. The pickers' own
`firstDate`/`lastDate` already bracketed today, so this needed no supporting change.

## The 90% rule (reactive volume curve)

`generate()` takes `weekLogs` as an **explicit input**, so the plan is still a pure function — the
logs are data, not hidden state. `TrainerController.logWeek` calls `_rebuild()`; without that the
curve silently never fires. There is a regression test for it.

- `minimumAdherenceToProgress = 0.9`. A week that fell short **holds the next week flat** instead
  of increasing it.
- **The hold is local, not cumulative.** Each week depends only on its immediate predecessor, so
  missing one week and then doing the next resumes the build from there. A running total would
  flatten the entire remaining block for one bad week.
- **A week with no record is unknown, not failed.** It must not block growth, or a plan generated for
  someone who has not started logging would never build at all.
- Prescribed sessions come from the day pattern, not from a generated plan — reading run counts off a
  plan that does not exist yet would be circular.
- `markWeekComplete` is **authoritative, not a merge**: it sets a clean completed state and discards
  stale partial detail. A predictable button beats one whose effect depends on invisible prior state.
  Use the log sheet to keep detail alongside "completed".
- Cutbacks and the taper still apply while progression is held, and the taper still descends from a
  held peak.

## Week log (per-week, not per-run)

**The scope decision:** per-week. A per-run log grows without bound and would eventually force a
real database; per-week keeps a few dozen small records in `shared_preferences`, which is the right
tool at this size. The trade-off is real: adaptation is coarser — you learn a week was too hard, not
*which* session in it was.

`WeekLog` (`domain/models/week_log.dart`): `completed`, `actualKm`, `sessionsDone`, `difficulty`
(1–10), `note`. Every field optional. `difficulty` is the important one — `completed` answers "did
you do it", `difficulty` answers "was it too much", and a runner ticking every box while grinding is
following a plan that is too hard for them.

- **Keys are week-start dates, not week numbers** — see below.
- `markWeekComplete(false)` clears the week's own data as well as everything after it. A
  half-recorded incomplete week produces misleading adherence figures.
- `PlanProgress.looksTooHard` needs **≥3 weeks rated 8+** and an average ≥7. The threshold is
  deliberately demanding: one hard week is a bad week, three is a miscalibrated plan.
- Adherence getters return **null, not 0**, when nothing is recorded. "No data" must not read as
  "0% adherence".
- `loadWeekLogs` migrates the older `completedWeeks` boolean-list format and skips individual
  unreadable entries rather than losing the whole history.

## Week completion

Completion is keyed on `PlanWeek.startDate` (ISO `yyyy-MM-dd` via `weekKey`), **not** on week number —
the plan is a pure function of the profile, so a goal change regenerates it and "week 5" can mean a
different session afterwards. Keying on the date is what lets a goal change stop discarding
completed weeks. See `domain/progress.dart`.

Rules that are easy to get wrong:

- **`missedWeekCount` is strictly *before* the current week.** The week in progress is not missed —
  on day one of week 1, nothing is missed.
- **`suggestedWeekIndex` never shows a completed week.** A runner who finished four weeks sees week
  5 even if the calendar says week 2. This replaced a trap where returning after a month dumped you
  on week 5 of a block you never started.
- **Un-marking a week also clears every week after it.** You cannot claim to have finished weeks
  built on one you just disowned.
- `PlanProgress` takes an injectable `now` so the calendar logic is testable without a real clock.
- The week strip in the plan screen is **horizontally** scrollable — a vertical `drag` will not
  scroll it. Use the "ALL WEEKS" route (a vertical list) for driving it in tests.

## Goal editing

`setGoal()` regenerates the plan from week 1 and persists. The form lives in
`ui/goal/goal_editor.dart` as a **controlled** component and is used by both the onboarding wizard
and the post-onboarding edit sheet — they must not drift apart, so do not duplicate it.

Two affordances reach it: the tappable race card / "no goal set" card on the plan screen, and the
Edit goal button on the review screen. Both are keyed (`race-card`, `add-goal-card`) for tests;
match on those keys, not on strings like "Marathon", which also appear in flag text.

Save is explicit rather than per-keystroke, so a half-typed finish time cannot silently become the
runner's target.

## Tests

```bash
flutter test                                  # 642 unit + widget, mocked storage
flutter test integration_test -d emulator-5554 # 12 on-device, REAL storage
```

`integration_test/persistence_test.dart` deliberately does **not** mock SharedPreferences. It writes
a profile, calls `SharedPreferences.resetStatic()` to drop the in-memory cache, then reads through
a fresh controller — so the read is forced off disk. A test that passes proves the file was written,
not just the map.

## Building for Android

**The project is on `I:` but the Pub cache is on `C:`.** Kotlin's incremental compiler requires a
source file and its base file to share a root, so any plugin containing Kotlin sources fails:

```
IllegalArgumentException: this and base files have different roots: ...Pub\Cache\...\Foo.kt and I:\...\android
Could not close incremental caches ... class-fq-name-to-source.tab
```

`android/gradle.properties` therefore sets `kotlin.incremental=false`. This is a deliberate
workaround, not a leftover. `flutter clean` does **not** fix it — the cause is the drive split, not
a corrupt cache. It can be removed if the project moves to `C:` or `PUB_CACHE` moves to `I:`.

`shared_preferences_android` is the plugin that triggers it, so this is invisible until the first
APK build.

## Device verification

Primary target is the `Medium_Phone` AVD: 1080×2400 @ 420dpi → **411×914 dp logical**. The widget
suite runs at 400×900, which is close but not identical — if layout looks wrong on the device,
trust the device.

Storage is verified by inspecting the app's data directory rather than assumed:

```bash
adb shell run-as com.example.ai_running_trainer ls shared_prefs
adb shell run-as com.example.ai_running_trainer cat shared_prefs/FlutterSharedPreferences.xml
```

`shared_preferences` writes to the app data dir and survives restarts and reboots, but not
reinstall or "clear data". Note `flutter test integration_test` **uninstalls the app** when it
finishes, so reinstall before inspecting.

**Do not use the debug APK to judge performance.** A debug build on this 2 GB emulator ANRs on
launch ("Input dispatching timed out") purely because the 153 MB unstripped debug build cannot
produce a first frame inside the 5 s input-dispatch budget. The 68 MB profile build launches
cleanly. If something looks slow or hangs, reproduce it in profile before investigating.

**Flutter does not expose its semantics tree to `uiautomator`** without an accessibility service,
so `uiautomator dump` returns no text and the screen cannot be read that way. Use the integration
test suite to assert on-device behaviour instead of scraping the view hierarchy.

## Known limitations

- **`applicationId` is still `com.example.ai_running_trainer`**, the Flutter template placeholder.
  Not publishable. It needs a real reverse-domain ID, which requires a domain the user owns — the
  user has deferred this. It cannot be changed after a store submission.



## Design system

Read `ui/theme.dart` before touching any screen. The rules that are easy to break:

- **The `ColorScheme` is hand-authored, not `fromSeed`.** `fromSeed` derives a whole tonal palette
  from one seed and produces the default Flutter look regardless of which seed you pass. Do not
  "simplify" it back.
- **Dark only.** `#0E0D0D` is the base; surfaces step up from it. A light theme would be a second
  tuned system, not an inversion.
- **`#FF3600` is the only brand colour.** `#FE7A0D` is a gradient partner, never a competing
  primary — they are ~14° apart in hue and read as muddled if both carry roles.
- **Zone colours are a single heat ramp, not six hues.** Easy and recovery are deliberately cool and
  desaturated so the ~80% of a week that is easy recedes; only threshold/interval glow. Nothing in
  the ramp may equal the brand except `interval`.
- **Type lives in the `AppType` extension on `ThemeData`** (`theme.display`, `theme.label`,
  `theme.tabular`, …). It is named `AppType`, not `AppTheme`, because a class and an extension cannot
  share a name — the class would shadow the extension and every `theme.display` would fail.
- **`tabular` on any numeral that re-renders.** Times and paces jitter sideways with proportional
  figures.
- **No `Colors.black26` or other palette literals in screens.** Pull from `AppColors` / `ZonePalette`.
- **Stat rows use `FittedBox(scaleDown)`.** A stat is a third of a phone-width row and the content
  is unbounded — three-digit volumes, seven-character durations. This is not optional; without it
  the week header overflows at 400px.
- **`ZoneRule` (a 3px bar) replaced the pill badge.** Chips and outlined cards are the clearest
  markers of an unstyled app; there are none left in the screens.


## Things an agent would get wrong

- **`lib/domain/` must not import `package:flutter`.** All the pace math lives there so it is
  unit-testable without a widget harness. Adding a Flutter import breaks that boundary.
- **Pace conversion is `s/mi ÷ 1.609344`, not `×`.** An earlier version multiplied, which put
  threshold pace a full minute off. `zones_test.dart` pins the published VDOT 50 values to catch it.
- **VDOT is a table, not the raw equation.** `engine/vdot.dart` embeds the published equivalent-time
  table and interpolates. The raw Daniels equation was deliberately not reproduced: implementations
  of it disagree by up to ~4%, and at least one popular calculator is simply wrong. Change the table
  only against a source, and update the anchors in `vdot_test.dart` with it.
- **Cutback weeks are defined once**, in `volume.isCutbackWeek`. The volume curve and both generators
  once disagreed about which weeks were cutbacks, which produced 4 km long-run jumps.
- **A cutback is a dip, not a downgrade.** The volume curve returns to the pre-cutback level
  afterwards; without that a 12-week block ends up smaller than it started.
- **The growth baseline is the *enforced* long run**, not the pre-enforcement one, or growth exceeds
  the cap after a cutback.
- **`Workout.hardFractionOfDistance` exists because 80/20 is otherwise unreachable.** A tempo is
  mostly easy by distance. Without it, one quality session counts as a third of the week at
  threshold.
- **Zone anchor is CURRENT fitness, not the goal race pace.** This line was wrong here for a long time
  and contradicted the section above it. `zoneAnchorPace` ignores `goalDistance` and `goalFinishTime`
  entirely; the goal shapes block length, volume, taper and race-week pacing, never a training pace.
  **The one exception is the taper's race-pace session** (`taperRepPace`), which is goal-anchored by
  design and floored at the repetition pace. Do not "fix" that one back.
- **A rep set's zone comes from its phase, not from its rep distance.**
  `repZoneForPhase`: threshold in base and specific, interval in peak only. Long reps are threshold work
  — running 2km at interval pace is a different and much more damaging session than the name implies.
- **Session copy is asserted against the prescription, not the source.** Every quality session names its
  easy legs in *distance* because it is budgeted in distance. A test parses the numbers back out. A
  third copy of the old "10 min warm-up" string sat in `generate.dart` for a whole round because nobody
  checked the output.
- **A session's pace is `workout.displayPace(paces)`, never `paces.forZone(workout.zone)`.** A zone is a
  five-rung classification of a continuum and real prescriptions do not land on the rungs — a 51:00
  10K is 5:06/km and the ladder had nothing at 5:06. Inferring it produced a card contradicting its own
  description, on the taper's race-pace session and on the goal race.
- **Riegel is optimistic at long distances.** `riiegel.conservativeMargin` is a deliberate, exposed
  heuristic. Do not remove it without replacing it.
- **Beginner path contains zero quality sessions.** That is a safety property, asserted in
  `plan_test.dart`. Do not add threshold work there.
- **The 80/20, long-run-share, and taper-monotonic rules are invariants**, enforced in
  `enforceSafety`/`buildVolumeCurve` and asserted across 10 plan shapes in `plan_test.dart`. A
  generator change that breaks them should fail the test, not be papered over. The long-run share is
  **day-aware** (`maxLongRunFractionFor`), and a plan week must satisfy *two* invariants at once:
  the long run is the longest run of the week, **and** the reported target equals the sum of the
  sessions. Either alone is satisfiable while the plan is still wrong.
- **Widget tests run at 400x900 on purpose.** They used to run at 1200x3000, which built every row
  at a width no device has — that is why a phone-width overflow shipped. `expectNoLayoutError` is
  the guard; do not widen the surface back.

## Known limitations

Resolved since v1, and previously listed here: goal changes no longer lose progress (completion is
keyed on week start dates), and the "only progress if the last week was completed" rule is now
implemented as the 90% rule.

Remaining:

- **`applicationId` is still `com.example.ai_running_trainer`**, the Flutter template placeholder.
  Not publishable. It needs a real reverse-domain ID, which requires a domain the user owns — the
  user has deferred this. It cannot be changed after a store submission.
- **No imperial units.** Everything is SI internally; display conversion is not built. Metric was an
  explicit product decision.
- **Plan is anchored to the next Monday after onboarding**, not the onboarding day. A mid-week start
  wastes week 1 and makes the runner look behind before running a step. `alignToNextMonday`; today
  being a Monday is used as-is. The review screen states the start date so it is not silent.
- **Goal realism is judged against *trained* fitness, not the bare PB.** `currentExpectation` in
  `validation.dart` nudges the anchor equivalent by ±1% from logged difficulties. A fitter athlete
  has less ground to cover to a given time, so absorbed training makes a goal look *less* ambitious
  and hard weeks make it look *more* — which is the useful direction, because a goal that has quietly
  become unreachable then gets flagged. The adjustment is deliberately small; claiming to know more
  than the logs do would be worse than leaving the PB alone.
- **No light theme**, and no elevation/shadow system — the design is flat surfaces plus hairlines.
- `Pace` rounds to whole seconds, so zone paces can differ by ~1 s/km from an exact calculation.
