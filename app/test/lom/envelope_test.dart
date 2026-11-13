import 'dart:convert';

import 'package:dsh_app/lom/lom_phone.dart';
import 'package:flutter_test/flutter_test.dart';

/// Vector from lom.entermodetwo.com/assets/phone-access/testvectors/remote-envelope-v1.json
const _vectorJson = '''
{"envelope":{"ciphertext":"5dpHTpbv6rZxQywWilDiNJ70xFvRMBcbMgv9cogOONjfCXLl3bToV5xxzsgHIWEdgDB2","ephemeral":"bc0WO7ErYq17Z9fMs1q6Om__WlOyIpAGTJI6y4AnzVU","id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","recipient":"V9tLNZ8jrl4Ubk4lEgVnBHIlBjSMFQwUdT0Mkz0E1CFDpy5xRAF2LfZraMJt-98mgqrsnyR07KRhPkJKD7r9PA","sender":"E75P6uryBMf9M1j8nAByGIHRdCeBKCJ-xnTzf3_pe20TmPYsbRpFfFG6aktfPb0vafypMhYhjciZfkFr0X2Tyg","signature":"rpAMtxOGzrHAR8rxgLYnEfzxS_2foN-2MFhcOKKkRSnvzhPhwJbjuaCSFLKef59vufGsXqeDhGyQzs0j8nbMBQ"},"recipient":"V9tLNZ8jrl4Ubk4lEgVnBHIlBjSMFQwUdT0Mkz0E1CFDpy5xRAF2LfZraMJt-98mgqrsnyR07KRhPkJKD7r9PA","sender":"E75P6uryBMf9M1j8nAByGIHRdCeBKCJ-xnTzf3_pe20TmPYsbRpFfFG6aktfPb0vafypMhYhjciZfkFr0X2Tyg"}
''';

Future<LomIdentity> _senderIdentity() => LomIdentity.fromPrivateBytes(
      x25519PrivateKey: List<int>.filled(32, 0x07),
      ed25519Seed: List<int>.filled(32, 0x08),
    );

Future<LomIdentity> _receiverIdentity() => LomIdentity.fromPrivateBytes(
      x25519PrivateKey: List<int>.filled(32, 0x09),
      ed25519Seed: List<int>.filled(32, 0x0A),
    );

void main() {
  group('remote-envelope-v1.json vector', () {
    test('derived K values match the vector sender/recipient', () async {
      final sender = await _senderIdentity();
      final receiver = await _receiverIdentity();
      final vector = jsonDecode(_vectorJson) as Map<String, dynamic>;
      expect(sender.keys, vector['sender']);
      expect(receiver.keys, vector['recipient']);
    });

    test('opens to "模型同步：test-key"', () async {
      final receiver = await _receiverIdentity();
      final vector = jsonDecode(_vectorJson) as Map<String, dynamic>;
      final envelope = LomEnvelope.fromJson(
        vector['envelope'] as Map<String, dynamic>,
      );
      final plain = await openEnvelope(
        envelope: envelope,
        ownIdentity: receiver,
        trustedSenders: {envelope.sender},
      );
      expect(utf8.decode(plain), '模型同步：test-key');
    });

    test('tampering with any field fails', () async {
      final receiver = await _receiverIdentity();
      final vector = jsonDecode(_vectorJson) as Map<String, dynamic>;
      final base = vector['envelope'] as Map<String, dynamic>;

      LomEnvelope tampered(Map<String, dynamic> patch) {
        final m = Map<String, dynamic>.from(base)..addAll(patch);
        return LomEnvelope.fromJson(m);
      }

      // id changed: AAD changes -> signature fails
      await expectLater(
        openEnvelope(
          envelope: tampered({'id': 'b' * 32}),
          ownIdentity: receiver,
          trustedSenders: {base['sender'] as String},
        ),
        throwsA(isA<LomEnvelopeException>()),
      );
      // ephemeral changed: shared secret + signature fail
      await expectLater(
        openEnvelope(
          envelope: tampered({
            'ephemeral': b64urlEncode(
              List<int>.generate(32, (i) => i == 0 ? 1 : 0),
            ),
          }),
          ownIdentity: receiver,
          trustedSenders: {base['sender'] as String},
        ),
        throwsA(isA<LomEnvelopeException>()),
      );
      // ciphertext: flip one byte
      final ct = b64urlDecodeStrict(base['ciphertext'] as String)!;
      ct[20] ^= 0x01;
      await expectLater(
        openEnvelope(
          envelope: tampered({'ciphertext': b64urlEncode(ct)}),
          ownIdentity: receiver,
          trustedSenders: {base['sender'] as String},
        ),
        throwsA(isA<LomEnvelopeException>()),
      );
      // signature: flip one byte
      final sig = b64urlDecodeStrict(base['signature'] as String)!;
      sig[0] ^= 0x01;
      await expectLater(
        openEnvelope(
          envelope: tampered({'signature': b64urlEncode(sig)}),
          ownIdentity: receiver,
          trustedSenders: {base['sender'] as String},
        ),
        throwsA(isA<LomEnvelopeException>()),
      );
    });

    test('sender outside the trust set fails', () async {
      final receiver = await _receiverIdentity();
      final vector = jsonDecode(_vectorJson) as Map<String, dynamic>;
      final envelope = LomEnvelope.fromJson(
        vector['envelope'] as Map<String, dynamic>,
      );
      await expectLater(
        openEnvelope(
          envelope: envelope,
          ownIdentity: receiver,
          trustedSenders: {},
        ),
        throwsA(isA<LomEnvelopeException>()),
      );
    });

    test('wrong recipient fails', () async {
      final sender = await _senderIdentity();
      final vector = jsonDecode(_vectorJson) as Map<String, dynamic>;
      final envelope = LomEnvelope.fromJson(
        vector['envelope'] as Map<String, dynamic>,
      );
      await expectLater(
        openEnvelope(
          envelope: envelope,
          ownIdentity: sender,
          trustedSenders: {envelope.sender},
        ),
        throwsA(isA<LomEnvelopeException>()),
      );
    });

    test('reply sealed by the receiver opens with the sender identity', () async {
      final sender = await _senderIdentity();
      final receiver = await _receiverIdentity();
      final vector = jsonDecode(_vectorJson) as Map<String, dynamic>;
      final request = LomEnvelope.fromJson(
        vector['envelope'] as Map<String, dynamic>,
      );
      final reply = await sealEnvelope(
        plaintext: utf8.encode('{"status":"ok"}'),
        id: request.id,
        senderIdentity: receiver,
        recipientKeys: request.sender,
      );
      expect(reply.id, request.id);
      expect(reply.sender, receiver.keys);
      expect(reply.recipient, request.sender);
      expect(reply.ephemeral.length, 43);
      final plain = await openEnvelope(
        envelope: reply,
        ownIdentity: sender,
        trustedSenders: {receiver.keys},
      );
      expect(utf8.decode(plain), '{"status":"ok"}');
    });
  });

  group('envelope shape', () {
    test('seal/open round-trip with fresh identities', () async {
      final a = await LomIdentity.generate();
      final b = await LomIdentity.generate();
      final env = await sealEnvelope(
        plaintext: utf8.encode('hello, Lom'),
        id: newEnvelopeId(),
        senderIdentity: a,
        recipientKeys: b.keys,
      );
      expect(env.toJson().length, 6);
      final plain = await openEnvelope(
        envelope: env,
        ownIdentity: b,
        trustedSenders: {a.keys},
      );
      expect(utf8.decode(plain), 'hello, Lom');
    });

    test('fromJson rejects wrong field count', () {
      expect(
        () => LomEnvelope.fromJson({'id': 'x'}),
        throwsA(isA<LomEnvelopeException>()),
      );
    });

    test('seal rejects oversized plaintext', () async {
      final a = await LomIdentity.generate();
      final b = await LomIdentity.generate();
      await expectLater(
        sealEnvelope(
          plaintext: List<int>.filled(350001, 0x61),
          id: newEnvelopeId(),
          senderIdentity: a,
          recipientKeys: b.keys,
        ),
        throwsA(isA<LomEnvelopeException>()),
      );
    });

    test('newEnvelopeId is 32 lowercase hex chars', () {
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(newEnvelopeId()), isTrue);
    });
  });
}
