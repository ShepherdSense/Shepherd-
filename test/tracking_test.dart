import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/models/tracking.dart';
import 'package:shepherd/state/app_state.dart';

void main() {
  group('callsign validation', () {
    test('accepts valid callsigns', () {
      expect(AppState.cleanCallsign('RAPTOR-1'), 'RAPTOR-1');
      expect(AppState.cleanCallsign('raptor 2'), 'RAPTOR 2');
      expect(AppState.cleanCallsign('A_B-3'), 'A_B-3');
    });

    test('rejects invalid callsigns', () {
      expect(AppState.cleanCallsign(''), isNull);
      expect(AppState.cleanCallsign('   '), isNull);
      expect(AppState.cleanCallsign('WAYTOO-LONG-CALLSIGN!'), isNull);
      expect(AppState.cleanCallsign('RAPTOR;1'), isNull);
      expect(AppState.cleanCallsign('<script>'), isNull);
    });
  });

  group('NodePosition callsign', () {
    test('displayName prefers callsign', () {
      final n = NodePosition(nodeId: 'SHN-AB12', x: 0, y: 0);
      expect(n.displayName, 'SHN-AB12');
      n.callsign = 'RAPTOR-1';
      expect(n.displayName, 'RAPTOR-1');
    });

    test('round-trips through json', () {
      final n = NodePosition(nodeId: 'SHN-AB12', x: 1, y: 2)
        ..callsign = 'RAPTOR-1'
        ..callsignByUser = true;
      final m = NodePosition.fromJson(n.toJson());
      expect(m.callsign, 'RAPTOR-1');
      expect(m.callsignByUser, isTrue);
      expect(m.displayName, 'RAPTOR-1');
    });

    test('omits empty callsign from json', () {
      final n = NodePosition(nodeId: 'SHN-AB12', x: 0, y: 0);
      expect((n.toJson())['callsign'], isNull);
    });
  });
}
