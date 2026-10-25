import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/phone_tier.dart';

void main() {
  group('activation', () {
    test('active with no hardware attached', () {
      final tier = PhoneTier.evaluate(
        hardware: const HardwareAttachment(),
      );
      expect(tier.active, isTrue);
      expect(tier.modeLabel, 'PHONE-ONLY');
    });

    test('inactive when a mesh driver is attached', () {
      final tier = PhoneTier.evaluate(
        hardware: const HardwareAttachment(meshDriverAttached: true),
      );
      expect(tier.active, isFalse);
      expect(tier.modeLabel, isNot('PHONE-ONLY'));
    });

    test('inactive when an SDR is attached', () {
      final tier = PhoneTier.evaluate(
        hardware: const HardwareAttachment(sdrAttached: true),
      );
      expect(tier.active, isFalse);
    });

    test('inactive when a serial driver is attached', () {
      final tier = PhoneTier.evaluate(
        hardware: const HardwareAttachment(serialDriverAttached: true),
      );
      expect(tier.active, isFalse);
    });
  });

  group('exposed sources', () {
    test('active tier exposes only the five phone sources', () {
      final tier = PhoneTier.evaluate(
        hardware: const HardwareAttachment(),
      );
      expect(
        tier.availableSources,
        [
          PhoneScanSource.bleScan,
          PhoneScanSource.wifiSurvey,
          PhoneScanSource.remoteId,
          PhoneScanSource.signatureLibrary,
          PhoneScanSource.hunt,
        ],
      );
      // No hardware driver can be represented: the source enum has
      // no Silvus / SDR / serial member, and labels say so.
      final labels =
          tier.availableSources.map((s) => s.label).join(' ').toLowerCase();
      expect(labels, isNot(contains('silvus')));
      expect(labels, isNot(contains('sdr')));
      expect(labels, isNot(contains('serial')));
      expect(tier.hasAnySource, isTrue);
    });

    test('inactive tier exposes no sources', () {
      final tier = PhoneTier.evaluate(
        hardware: const HardwareAttachment(meshDriverAttached: true),
      );
      expect(tier.availableSources, isEmpty);
      expect(tier.hasAnySource, isFalse);
      expect(tier.unavailableReason, isNull);
    });
  });

  group('range honesty', () {
    test('active tier labels phone range, never mesh coverage', () {
      final tier = PhoneTier.evaluate(
        hardware: const HardwareAttachment(),
      );
      expect(tier.rangeLabel, contains('PHONE-RANGE'));
      expect(tier.rangeLabel, contains('tens of meters'));
      expect(tier.rangeLabel, contains('not area coverage'));
    });

    test('inactive tier does not claim phone range', () {
      final tier = PhoneTier.evaluate(
        hardware: const HardwareAttachment(sdrAttached: true),
      );
      expect(tier.rangeLabel, isNot(contains('PHONE-RANGE')));
    });
  });

  group('graceful degradation', () {
    test('unavailable scan source degrades to off and is named', () {
      final tier = PhoneTier.evaluate(
        hardware: const HardwareAttachment(),
        sourceAvailable: {
          PhoneScanSource.bleScan: false,
          PhoneScanSource.wifiSurvey: false,
        },
      );
      expect(tier.active, isTrue);
      expect(tier.availableSources, isNot(contains(PhoneScanSource.bleScan)));
      expect(tier.availableSources, isNot(contains(PhoneScanSource.wifiSurvey)));
      expect(
        tier.unavailableSources,
        [PhoneScanSource.bleScan, PhoneScanSource.wifiSurvey],
      );
      expect(tier.unavailableReason, contains('Phone BLE scan'));
      expect(tier.unavailableReason, contains('Phone Wi-Fi survey'));
    });

    test('all sources unavailable still active, but with nothing to run', () {
      final tier = PhoneTier.evaluate(
        hardware: const HardwareAttachment(),
        sourceAvailable: {
          for (final s in PhoneScanSource.values) s: false,
        },
      );
      expect(tier.active, isTrue);
      expect(tier.availableSources, isEmpty);
      expect(tier.hasAnySource, isFalse);
      expect(tier.unavailableReason, isNotNull);
    });

    test('all sources available means no unavailable reason', () {
      final tier = PhoneTier.evaluate(
        hardware: const HardwareAttachment(),
      );
      expect(tier.unavailableSources, isEmpty);
      expect(tier.unavailableReason, isNull);
    });
  });
}
