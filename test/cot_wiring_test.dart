/// Wiring-level invariants for the CoT UI integration
/// (state/app_state.dart): the emitter evidence-line wording contract.
///
/// Load-bearing invariants:
///  1. The line carries the emitter callsign.
///  2. The line says "coincident" — never "confirmed", never identity
///     language ("identified", "hostile", "friendly").
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/state/app_state.dart';

void main() {
  test('emitter evidence line names the emitter and says coincident', () {
    final line = cotEmitterEvidenceLine('PREDATOR-07');
    expect(line, contains('PREDATOR-07'));
    expect(line, contains('coincident'));
  });

  test('emitter evidence line never confirms or identifies', () {
    final line = cotEmitterEvidenceLine('PREDATOR-07').toLowerCase();
    expect(line, isNot(contains('confirmed')));
    expect(line, isNot(contains('identified')));
    expect(line, isNot(contains('hostile')));
    expect(line, isNot(contains('friendly')));
    // "consistent with" family wording only.
    expect(line, contains('coincident'));
  });
}
