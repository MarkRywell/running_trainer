import 'package:ai_running_trainer/domain/models/week_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('hasData', () {
    test('an empty log has no data', () {
      expect(const WeekLog().hasData, isFalse);
    });

    test('any single field makes it a log', () {
      expect(const WeekLog(completed: true).hasData, isTrue);
      expect(const WeekLog(actualKm: 30).hasData, isTrue);
      expect(const WeekLog(sessionsDone: 3).hasData, isTrue);
      expect(const WeekLog(difficulty: 6).hasData, isTrue);
      expect(const WeekLog(note: 'knee').hasData, isTrue);
    });

    test('a blank note is not data', () {
      expect(const WeekLog(note: '   ').hasData, isFalse);
      expect(const WeekLog(note: '').hasData, isFalse);
    });
  });

  group('difficulty bands', () {
    test('8 and above counts as too hard', () {
      expect(const WeekLog(difficulty: 8).feltTooHard, isTrue);
      expect(const WeekLog(difficulty: 10).feltTooHard, isTrue);
      expect(const WeekLog(difficulty: 7).feltTooHard, isFalse);
    });

    test('1 and 2 counts as too easy', () {
      expect(const WeekLog(difficulty: 1).feltTooEasy, isTrue);
      expect(const WeekLog(difficulty: 2).feltTooEasy, isTrue);
      expect(const WeekLog(difficulty: 3).feltTooEasy, isFalse);
    });

    test('unrated is neither', () {
      expect(const WeekLog().feltTooHard, isFalse);
      expect(const WeekLog().feltTooEasy, isFalse);
    });
  });

  group('json', () {
    test('round-trips a full log', () {
      const log = WeekLog(
        completed: true,
        actualKm: 42.5,
        sessionsDone: 4,
        difficulty: 7,
        note: 'felt strong',
      );
      final back = WeekLog.fromJson(log.toJson());
      expect(back.completed, isTrue);
      expect(back.actualKm, 42.5);
      expect(back.sessionsDone, 4);
      expect(back.difficulty, 7);
      expect(back.note, 'felt strong');
    });

    test('omits absent fields so the stored value stays small', () {
      final json = const WeekLog(completed: true).toJson();
      expect(json.containsKey('completed'), isTrue);
      expect(json.containsKey('actualKm'), isFalse);
      expect(json.containsKey('difficulty'), isFalse);
      expect(json.containsKey('note'), isFalse);
    });

    test('survives a minimal entry', () {
      final back = WeekLog.fromJson(const WeekLog(completed: true).toJson());
      expect(back.completed, isTrue);
      expect(back.actualKm, isNull);
    });
  });

  group('copyWith', () {
    test('replaces one field and keeps the rest', () {
      const log = WeekLog(completed: true, actualKm: 30, difficulty: 5);
      final next = log.copyWith(difficulty: 9);
      expect(next.completed, isTrue);
      expect(next.actualKm, 30);
      expect(next.difficulty, 9);
    });

    test('can clear the note explicitly', () {
      const log = WeekLog(note: 'knee');
      expect(log.copyWith(clearNote: true).note, isNull);
    });
  });
}
