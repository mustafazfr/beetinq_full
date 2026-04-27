import 'package:flutter_test/flutter_test.dart';
import 'package:beetinq_sense/core/contact/contact_config.dart';

void main() {
  group('encodeDeviceId', () {
    test('ilk 4 byte doğru biçimde major/minor ayrılır', () {
      // 'a1b2c3d4...' → 0xA1B2C3D4 → major=0xA1B2 (41394), minor=0xC3D4 (50132)
      final r = encodeDeviceId(
        'a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e5f67890',
      );
      expect(r.major, 0xA1B2);
      expect(r.minor, 0xC3D4);
    });

    test('tümü sıfır hash → major=0 minor=0', () {
      final r = encodeDeviceId('00000000${'deadbeef' * 7}');
      expect(r.major, 0);
      expect(r.minor, 0);
    });

    test('maksimum değer: ffffffff → major=0xFFFF minor=0xFFFF', () {
      final r = encodeDeviceId('ffffffff${'0' * 56}');
      expect(r.major, 0xFFFF);
      expect(r.minor, 0xFFFF);
    });

    test('kısa hash FormatException fırlatır', () {
      expect(() => encodeDeviceId('abc'), throwsFormatException);
    });

    test('hex olmayan hash FormatException fırlatır', () {
      expect(() => encodeDeviceId('zzzzzzzz${'0' * 56}'), throwsFormatException);
    });
  });

  group('decodeAnonId', () {
    test('küçük harf + padding uygulanır', () {
      expect(decodeAnonId(0xA1B2, 0xC3D4), 'a1b2:c3d4');
    });

    test('küçük değerler sol-sıfır paddli gelir', () {
      expect(decodeAnonId(0x1, 0x2), '0001:0002');
    });

    test('sıfır → 0000:0000', () {
      expect(decodeAnonId(0, 0), '0000:0000');
    });
  });

  group('round-trip encode → decode', () {
    test('rastgele hash verisinde anon ID stabil', () {
      final hash = 'deadbeef${'0' * 56}';
      final (:major, :minor) = encodeDeviceId(hash);
      expect(decodeAnonId(major, minor), 'dead:beef');
    });

    test('aynı hash aynı anon ID üretir (deterministik)', () {
      final hash = 'abcdef01${'0' * 56}';
      final a = encodeDeviceId(hash);
      final b = encodeDeviceId(hash);
      expect(decodeAnonId(a.major, a.minor), decodeAnonId(b.major, b.minor));
    });

    test('farkli hash-ler genelde farkli anon ID uretir', () {
      final a = encodeDeviceId('11111111${'0' * 56}');
      final b = encodeDeviceId('22222222${'0' * 56}');
      expect(
        decodeAnonId(a.major, a.minor),
        isNot(decodeAnonId(b.major, b.minor)),
      );
    });
  });

  group('eşikler', () {
    test('RSSI eşiği -80 dBm', () {
      expect(kContactRssiThreshold, -80);
    });

    test('süre eşiği 60 sn', () {
      expect(kContactDurationSeconds, 60);
    });

    test('contact UUID doğru formatta', () {
      final re = RegExp(
        r'^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$',
      );
      expect(re.hasMatch(kContactTracingUuid), isTrue);
    });
  });
}
