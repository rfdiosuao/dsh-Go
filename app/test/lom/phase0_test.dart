import 'package:dsh_app/lom/lom_phone.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('base64url (strict, unpadded)', () {
    test('round-trip', () {
      for (final bytes in [
        <int>[],
        [0],
        [0xff, 0xfe],
        List<int>.generate(32, (i) => i),
        List<int>.generate(64, (i) => 255 - i),
      ]) {
        final s = b64urlEncode(bytes);
        expect(s.contains('='), isFalse);
        expect(b64urlDecodeStrict(s), bytes);
      }
    });

    test('rejects padding and standard-base64 characters', () {
      expect(b64urlDecodeStrict('AA=='), isNull);
      expect(b64urlDecodeStrict('a+b/'), isNull);
      expect(b64urlDecodeStrict('ab cd'), isNull);
      expect(b64urlDecodeStrict('AB'), isNull); // non-canonical trailing bits
      expect(b64urlDecodeStrict('A'), isNull); // length % 4 == 1
    });

    test('rejects wrong length', () {
      expect(b64urlDecodeStrictLength('AA', 2), isNull);
      expect(b64urlDecodeStrictLength('AAA', 2), [0, 0]);
    });

    test('constant-time equals', () {
      expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
      expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
      expect(constantTimeEquals([1, 2], [1, 2, 3]), isFalse);
    });
  });

  group('pairing-v1.json vectors', () {
    // Both cases from lom.entermodetwo.com/assets/phone-access/testvectors/pairing-v1.json
    final cases = [
      {
        'host': 'lom.entermodetwo.com',
        'pairing_id': 'OgX7dsvX6Pp6hNZsT6w8Sw',
        'claim_token': 'FQw1yQZ_QDI9gaoYuU4eRwQdFFjrO-YJZWp5v_TVKaE',
        'psk': '3yUTIoVtslOrzFoP_u6Mv94XCSibzlDW7C6unULIp3o',
        'desktop_keys':
            '32jqJTBThIbGnEQca3yRNAUe9-fqOW8Rkj1fHjMPej2E1bsA0518osSsj3Rp8dx4MXI6mu0t9VQ30chWisbnbA',
        'desktop_fingerprint': 'rp1mfT5Bdyg1iFGecQecVQ',
        'phone_keys':
            'FukJ5vAdsxAgpk1BpIEm6fz2ExraZY4MBy6QymqDna_CB2bIRp3GlEwfqwxC7UUsu8VyDV84p_TJmQnkPwuWbw',
        'phone_fingerprint': 'Ti0hVBou-hZOde-bso7M2Q',
        'qr':
            'lom://pair?v=1&h=bG9tLmVudGVybW9kZXR3by5jb20&p=OgX7dsvX6Pp6hNZsT6w8Sw&t=FQw1yQZ_QDI9gaoYuU4eRwQdFFjrO-YJZWp5v_TVKaE&k=3yUTIoVtslOrzFoP_u6Mv94XCSibzlDW7C6unULIp3o&f=rp1mfT5Bdyg1iFGecQecVQ',
        'key_proof': 'AhC3_kPvKz1tG45um27Ovh-jkGhQ8jxCPBCk9lkVqqE',
        'sas': '643266',
      },
      {
        'host': 'relay.example.cn',
        'pairing_id': 'mntD9iGtAxNFEDb-v4rUSg',
        'claim_token': 'ZdzxbqPfpJBpYoCJ60p1SDBw9VhLKiHuZJErX2IfEto',
        'psk': 'TYDmLs6Q7vnG0RRnN_cFPAgJeFchsJkOIp85TSIzgh4',
        'desktop_keys':
            'uzOk8RlrRIgVr9vcplKLSAIWTs2NvxtQMJxum7qc_B_MbHokMKqY_1oYpo5VYdNO45OSXTZbhc_xdAWdzvV-0g',
        'desktop_fingerprint': 'NuqfSSvlficw-XJrjywqxQ',
        'phone_keys':
            'h_UTzu97EWvgemFEkBmivdbfWhgnvGp8viwKK3gucnexXu5pnEsj7SqWM62XRGGL5tsY2XM6NtDGhuZot4QKXw',
        'phone_fingerprint': 'YGKr9rMqR0BMZ3SaIWD-FA',
        'qr':
            'lom://pair?v=1&h=cmVsYXkuZXhhbXBsZS5jbg&p=mntD9iGtAxNFEDb-v4rUSg&t=ZdzxbqPfpJBpYoCJ60p1SDBw9VhLKiHuZJErX2IfEto&k=TYDmLs6Q7vnG0RRnN_cFPAgJeFchsJkOIp85TSIzgh4&f=NuqfSSvlficw-XJrjywqxQ',
        'key_proof': '0gQ8fpfbC8YA2zeTYY-JkoAz3xUJq0cDpMcpkYaCEI4',
        'sas': '645446',
      },
    ];

    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      test('case $i fingerprint / key_proof / sas', () {
        expect(fingerprint(c['desktop_keys']!), c['desktop_fingerprint']);
        expect(fingerprint(c['phone_keys']!), c['phone_fingerprint']);
        final psk = b64urlDecodeStrict(c['psk']!)!;
        expect(psk.length, 32);
        expect(
          keyProof(
            psk: psk,
            pairingId: c['pairing_id']!,
            desktopKeys: c['desktop_keys']!,
            phoneKeys: c['phone_keys']!,
          ),
          c['key_proof'],
        );
        expect(
          sasCode(
            pairingId: c['pairing_id']!,
            desktopKeys: c['desktop_keys']!,
            phoneKeys: c['phone_keys']!,
          ),
          c['sas'],
        );
      });
    }

    test('case 0 QR link parses (host whitelisted)', () {
      final link = LomPairLink.parse(cases[0]['qr']!);
      expect(link.host, 'lom.entermodetwo.com');
      expect(link.pairingId, 'OgX7dsvX6Pp6hNZsT6w8Sw');
      expect(link.claimToken, 'FQw1yQZ_QDI9gaoYuU4eRwQdFFjrO-YJZWp5v_TVKaE');
      expect(link.psk.length, 32);
      expect(link.fingerprint.length, 16);
      expect(link.baseUrl, 'https://lom.entermodetwo.com');
      // The fingerprint in the link matches the desktop K fingerprint.
      expect(
        b64urlEncode(link.fingerprint),
        fingerprint(cases[0]['desktop_keys']!),
      );
    });

    test('case 1 QR link rejected: host not whitelisted', () {
      expect(
        () => LomPairLink.parse(cases[1]['qr']!),
        throwsA(
          isA<LomPairingLinkException>().having(
            (e) => e.code,
            'code',
            'pairing.qr_invalid',
          ),
        ),
      );
    });
  });

  group('lom://pair validation failures', () {
    const good =
        'lom://pair?v=1&h=bG9tLmVudGVybW9kZXR3by5jb20&p=OgX7dsvX6Pp6hNZsT6w8Sw&t=FQw1yQZ_QDI9gaoYuU4eRwQdFFjrO-YJZWp5v_TVKaE&k=3yUTIoVtslOrzFoP_u6Mv94XCSibzlDW7C6unULIp3o&f=rp1mfT5Bdyg1iFGecQecVQ';

    void expectInvalid(String input) {
      expect(
        () => LomPairLink.parse(input),
        throwsA(
          isA<LomPairingLinkException>().having(
            (e) => e.code,
            'code',
            'pairing.qr_invalid',
          ),
        ),
        reason: input,
      );
    }

    test('wrong scheme / host / fragment / version', () {
      expectInvalid(good.replaceFirst('lom://pair', 'https://pair'));
      expectInvalid(good.replaceFirst('lom://pair', 'lom://other'));
      expectInvalid('$good#frag');
      expectInvalid(good.replaceFirst('v=1', 'v=2'));
    });

    test('missing / duplicate / unknown field', () {
      expectInvalid(good.replaceFirst('&f=rp1mfT5Bdyg1iFGecQecVQ', ''));
      expectInvalid('$good&v=1');
      expectInvalid('$good&x=1');
    });

    test('non-canonical base64url and wrong lengths', () {
      expectInvalid(good.replaceFirst('p=OgX7dsvX6Pp6hNZsT6w8Sw', 'p=OgX7dsvX6Pp6hNZsT6w8Sx'));
      expectInvalid(good.replaceFirst('t=FQw1yQZ', 't=FQw1yQ=='));
      expectInvalid(good.replaceFirst('f=rp1mfT5Bdyg1iFGecQecVQ', 'f=rp1mfT5Bdyg1iFGecQecVR'));
    });

    test('over 2048 chars', () {
      expectInvalid('${good}AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
    });

    test('field order does not matter', () {
      final reordered =
          'lom://pair?f=rp1mfT5Bdyg1iFGecQecVQ&k=3yUTIoVtslOrzFoP_u6Mv94XCSibzlDW7C6unULIp3o&t=FQw1yQZ_QDI9gaoYuU4eRwQdFFjrO-YJZWp5v_TVKaE&p=OgX7dsvX6Pp6hNZsT6w8Sw&h=bG9tLmVudGVybW9kZXR3by5jb20&v=1';
      expect(LomPairLink.parse(reordered).pairingId, 'OgX7dsvX6Pp6hNZsT6w8Sw');
    });
  });

  group('manual pairing code', () {
    test('normalises case, hyphens and spaces', () {
      expect(normalizeManualCode('ab3d-9xk2'), 'AB3D-9XK2');
      expect(normalizeManualCode('AB3D9XK2'), 'AB3D-9XK2');
      expect(normalizeManualCode('ab3d 9xk2'), 'AB3D-9XK2');
    });
    test('rejects bad codes', () {
      expect(normalizeManualCode('AB3D-9XK'), isNull); // 7 chars
      expect(normalizeManualCode('AB3D-9XK22'), isNull); // 9 chars
      expect(normalizeManualCode('AB0D-9XK2'), isNull); // 0 not in alphabet
      expect(normalizeManualCode('ABOD-9XK2'), isNull); // O not in alphabet
      expect(normalizeManualCode('ABID-9XK2'), isNull); // I not in alphabet
      expect(normalizeManualCode('ABLD-9XK2'), isNull); // L not in alphabet
    });
  });

  group('identity', () {
    test('generated K is 86 chars and round-trips', () async {
      final id = await LomIdentity.generate();
      expect(id.keys.length, 86);
      final split = splitPublicKeyString(id.keys);
      expect(split, isNotNull);
      expect(split!.x25519, id.x25519PublicKey);
      expect(split.ed25519, id.ed25519PublicKey);
      expect(parsePublicKeyString(id.keys)?.length, 64);
    });

    test('two generated identities differ', () async {
      final a = await LomIdentity.generate();
      final b = await LomIdentity.generate();
      expect(a.keys, isNot(equals(b.keys)));
    });

    test('private bytes extract to 64 bytes', () async {
      final id = await LomIdentity.generate();
      expect((await id.extractPrivateBytes()).length, 64);
    });
  });
}
