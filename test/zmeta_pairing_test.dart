import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepherd/services/zmeta_pairing.dart';

final String _k1 = base64.encode(List<int>.filled(32, 1));
final String _k2 = base64.encode(List<int>.filled(32, 2));

String _code({
  String host = 'hub.example.com',
  String pairPort = '8443',
  String wgPort = '51820',
  String? token,
  String? certfp,
}) {
  final t = token ?? 'A' * 43;
  final f = certfp ?? 'ab' * 32;
  return 'Z1.$host.$pairPort.$wgPort.$t.$f';
}

void main() {
  group('parseInviteCode', () {
    test('parses a well-formed code', () {
      final c = parseInviteCode(_code());
      expect(c.hubHost, 'hub.example.com');
      expect(c.pairPort, 8443);
      expect(c.wgPort, 51820);
      expect(c.token, 'A' * 43);
      expect(c.certFpHex, 'ab' * 32);
      expect(c.redeemUrl, 'https://hub.example.com:8443/redeem');
    });

    test('hub host may itself contain dots', () {
      final c = parseInviteCode(_code(host: 'a.b.c.example.net'));
      expect(c.hubHost, 'a.b.c.example.net');
    });

    test('hub host may be an IP literal', () {
      final c = parseInviteCode(_code(host: '192.168.7.10'));
      expect(c.hubHost, '192.168.7.10');
    });

    test('cert fingerprint is lowercased', () {
      final c = parseInviteCode(_code(certfp: 'AB' * 32));
      expect(c.certFpHex, 'ab' * 32);
    });

    test('rejects wrong prefix', () {
      expect(() => parseInviteCode('Z2.hub.example.com.8443.51820.${'A' * 43}.${'ab' * 32}'),
          throwsA(isA<ZmetaPairingException>()));
    });

    test('rejects truncated code', () {
      expect(() => parseInviteCode('Z1.hub.example.com.8443'),
          throwsA(isA<ZmetaPairingException>()));
    });

    test('rejects short cert fingerprint', () {
      expect(() => parseInviteCode(_code(certfp: 'ab' * 16)),
          throwsA(isA<ZmetaPairingException>()));
    });

    test('rejects non-hex cert fingerprint', () {
      expect(() => parseInviteCode(_code(certfp: 'zz' * 32)),
          throwsA(isA<ZmetaPairingException>()));
    });

    test('rejects short token', () {
      expect(() => parseInviteCode(_code(token: 'A' * 42)),
          throwsA(isA<ZmetaPairingException>()));
    });

    test('rejects token with bad alphabet', () {
      expect(() => parseInviteCode(_code(token: '!' * 43)),
          throwsA(isA<ZmetaPairingException>()));
    });

    test('rejects non-numeric ports', () {
      expect(() => parseInviteCode(_code(pairPort: 'abc')),
          throwsA(isA<ZmetaPairingException>()));
      expect(() => parseInviteCode(_code(wgPort: '99999')),
          throwsA(isA<ZmetaPairingException>()));
    });

    test('rejects empty invite', () {
      expect(() => parseInviteCode('   '),
          throwsA(isA<ZmetaPairingException>()));
    });
  });

  group('platform id', () {
    test('accepts valid ids', () {
      expect(zmetaIsValidPlatformId('shepherd-mesh-1'), isTrue);
      expect(zmetaIsValidPlatformId('a'), isTrue);
      expect(zmetaIsValidPlatformId('team-42-north'), isTrue);
    });

    test('rejects invalid ids', () {
      expect(zmetaIsValidPlatformId(''), isFalse);
      expect(zmetaIsValidPlatformId('Shepherd-Mesh'), isFalse);
      expect(zmetaIsValidPlatformId('mesh 1'), isFalse);
      expect(zmetaIsValidPlatformId('mesh_1'), isFalse);
      expect(zmetaIsValidPlatformId('a' * 33), isFalse);
    });
  });

  group('wg conf', () {
    test('builds exact config text', () {
      final conf = zmetaBuildWgConf(
        privateKeyB64: _k1,
        tunnelIp: '10.99.0.11',
        hubPubkey: _k2,
        hubEndpoint: 'hub.example.com:51820',
      );
      expect(conf, '[Interface]\n'
          'PrivateKey = $_k1\n'
          'Address = 10.99.0.11/32\n'
          '\n'
          '[Peer]\n'
          'PublicKey = $_k2\n'
          'Endpoint = hub.example.com:51820\n'
          'AllowedIPs = 10.99.0.0/24\n'
          'PersistentKeepalive = 25\n');
    });
  });

  group('wg conf hardening', () {
    String build({String? pub, String? ep, String ip = '10.99.0.11'}) =>
        zmetaBuildWgConf(
          privateKeyB64: _k1,
          tunnelIp: ip,
          hubPubkey: pub ?? _k2,
          hubEndpoint: ep ?? 'hub.example.com:51820',
        );

    test('rejects newline injection in endpoint and key', () {
      expect(
          () => build(
              ep: 'hub.example.com:51820\n[Peer]\nAllowedIPs = 0.0.0.0/0'),
          throwsA(isA<ZmetaPairingException>()));
      expect(() => build(pub: '$_k2\nPostUp = x'),
          throwsA(isA<ZmetaPairingException>()));
      expect(() => build(ep: 'host:99999'),
          throwsA(isA<ZmetaPairingException>()));
    });

    test('AllowedIPs follows the assigned tunnel subnet', () {
      expect(build(ip: '10.50.7.9'), contains('AllowedIPs = 10.50.7.0/24\n'));
    });

    test('accepts ipv6 endpoints', () {
      expect(zmetaIsValidWgEndpoint('[2001:db8::1]:51820'), isTrue);
      expect(zmetaIsValidWgEndpoint('no port'), isFalse);
    });
  });

  group('ingest host policy', () {
    test('public-CA mode keeps the token on the invite hub family', () {
      expect(
          zmetaIngestHostAllowed('hub.example.com', 'hub.example.com',
              pinMode: false),
          isTrue);
      expect(
          zmetaIngestHostAllowed('ingest.example.com', 'hub.example.com',
              pinMode: false),
          isTrue);
      expect(
          zmetaIngestHostAllowed('evil.test', 'hub.example.com',
              pinMode: false),
          isFalse);
      expect(zmetaIngestHostAllowed('evil.test', 'hub.example.com',
          pinMode: true), isTrue);
    });
  });

  group('zmeta target', () {
    test('splits host:port', () {
      final t = zmetaParseTarget('10.99.0.1:5555')!;
      expect(t.host, '10.99.0.1');
      expect(t.port, 5555);
    });

    test('rejects garbage', () {
      expect(zmetaParseTarget('nope'), isNull);
      expect(zmetaParseTarget('host:99999'), isNull);
      expect(zmetaParseTarget(':5555'), isNull);
    });
  });

  group('hub errors', () {
    test('humanizes known errors', () {
      expect(zmetaHumanizeHubError('token expired'), contains('expired'));
      expect(zmetaHumanizeHubError('token already used'), contains('already used'));
      expect(zmetaHumanizeHubError('platform taken'), contains('already registered'));
      expect(zmetaHumanizeHubError('rate limited'), contains('rate-limiting'));
      expect(zmetaHumanizeHubError('mystery'), contains('mystery'));
    });
  });

  group('keypair', () {
    test('generates 32-byte base64 keys', () async {
      final kp = await zmetaGenerateWgKeypair();
      expect(kp.publicB64.length, 44);
      expect(kp.privateB64.length, 44);
      expect(base64.decode(kp.publicB64).length, 32);
      expect(base64.decode(kp.privateB64).length, 32);
    });
  });

  group('ingestUrl', () {
    test('accepts https', () {
      expect(
          zmetaValidateIngestUrl('https://hub.example.com/zmeta/ingest'),
          'https://hub.example.com/zmeta/ingest');
    });

    test('accepts https with port', () {
      expect(zmetaValidateIngestUrl('https://hub.example.com:8443/ingest'),
          'https://hub.example.com:8443/ingest');
    });

    test('accepts http on loopback', () {
      expect(zmetaValidateIngestUrl('http://127.0.0.1:8443/ingest'),
          'http://127.0.0.1:8443/ingest');
      expect(zmetaValidateIngestUrl('http://localhost:8443/ingest'),
          'http://localhost:8443/ingest');
    });

    test('rejects http on non-loopback', () {
      expect(() => zmetaValidateIngestUrl('http://hub.example.com/ingest'),
          throwsA(isA<ZmetaPairingException>()));
    });

    test('rejects non-https schemes', () {
      expect(() => zmetaValidateIngestUrl('ftp://hub.example.com/ingest'),
          throwsA(isA<ZmetaPairingException>()));
    });

    test('rejects empty and malformed', () {
      expect(() => zmetaValidateIngestUrl('   '),
          throwsA(isA<ZmetaPairingException>()));
      expect(() => zmetaValidateIngestUrl('not a url'),
          throwsA(isA<ZmetaPairingException>()));
      expect(() => zmetaValidateIngestUrl('https:///no-host'),
          throwsA(isA<ZmetaPairingException>()));
    });

    test('usability check does not throw', () {
      expect(zmetaIsUsableIngestUrl('https://hub.example.com/i'), isTrue);
      expect(zmetaIsUsableIngestUrl('http://hub.example.com/i'), isFalse);
      expect(zmetaIsUsableIngestUrl(''), isFalse);
    });
  });

  group('ingestToken', () {
    test('accepts a well-formed token', () {
      const t = 'Ab3_valid-token_0123456789abcdef';
      expect(zmetaValidateIngestToken(t), t);
    });

    test('rejects empty, short, and whitespace tokens', () {
      expect(() => zmetaValidateIngestToken('   '),
          throwsA(isA<ZmetaPairingException>()));
      expect(() => zmetaValidateIngestToken('abc123'),
          throwsA(isA<ZmetaPairingException>()));
      expect(
          () => zmetaValidateIngestToken('Ab3_valid token 0123456789abcdef'),
          throwsA(isA<ZmetaPairingException>()));
    });
  });

  group('zmetaInviteCodeFromScan', () {
    test('accepts a bare QR payload that is just the code', () {
      expect(zmetaInviteCodeFromScan(_code()), _code());
    });

    test('extracts the code from labeled text', () {
      expect(zmetaInviteCodeFromScan('Shepherd invite: ${_code()}'),
          _code());
    });

    test('extracts the code from a URL-shaped payload', () {
      expect(
          zmetaInviteCodeFromScan('https://hub.example.com/join?c=${_code()}'),
          _code());
      // Also when the code is not the final query parameter.
      expect(
          zmetaInviteCodeFromScan(
              'https://hub.example.com/join?c=${_code()}&src=qr'),
          _code());
    });

    test('rejects QRs that are not invites', () {
      expect(zmetaInviteCodeFromScan('https://example.com/'), isNull);
      expect(zmetaInviteCodeFromScan('WIFI:S:foo;T:WPA;P:bar;;'), isNull);
      expect(zmetaInviteCodeFromScan(''), isNull);
    });

    test('rejects a malformed Z1-looking string', () {
      expect(zmetaInviteCodeFromScan('Z1.hub.example.com.8443'), isNull);
    });
  });
}
