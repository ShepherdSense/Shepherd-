import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/build_age.dart';

void main() {
  group('buildAgeWarning', () {
    test('quiet on build day', () {
      expect(
        buildAgeWarning(
          now: DateTime(2026, 11, 5),
          build: DateTime(2026, 11, 5),
        ),
        isNull,
      );
    });

    test('quiet at 89 days', () {
      expect(
        buildAgeWarning(
          now: DateTime(2027, 2, 2),
          build: DateTime(2026, 11, 5),
        ),
        isNull,
      );
    });

    test('warns at exactly 90 days', () {
      final warning = buildAgeWarning(
        now: DateTime(2027, 2, 3),
        build: DateTime(2026, 11, 5),
      );
      expect(warning, isNotNull);
      expect(warning, contains('90 DAYS OLD'));
      expect(warning, contains('SENSING AND ALERTS ARE UNAFFECTED'));
    });

    test('warns later with the real day count', () {
      final warning = buildAgeWarning(
        now: DateTime(2027, 3, 5),
        build: DateTime(2026, 11, 5),
      );
      expect(warning, contains('120 DAYS OLD'));
    });

    test('clock before the build date stays quiet, never negative', () {
      expect(
        buildAgeDays(
          now: DateTime(2026, 11, 1),
          build: DateTime(2026, 11, 5),
        ),
        0,
      );
      expect(
        buildAgeWarning(
          now: DateTime(2026, 11, 1),
          build: DateTime(2026, 11, 5),
        ),
        isNull,
      );
    });
  });

  group('shipped buildDate', () {
    test('is 2026-11-05, the v0.27.1 cut date', () {
      expect(buildDate, DateTime(2026, 11, 5));
      expect(buildAgeWarningDays, 90);
    });
  });
}
