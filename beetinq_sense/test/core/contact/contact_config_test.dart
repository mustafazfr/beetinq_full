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
    test('RSSI eşiği -75 dBm (saha ayarı: -80 fazla gevşekti)', () {
      expect(kContactRssiThreshold, -75);
    });

    test('süre eşiği 10 sn (kullanıcı isteğiyle 60→10)', () {
      expect(kContactDurationSeconds, 10);
    });

    test('eviction eşiği 20 sn (BLE flicker payı)', () {
      expect(kContactEvictionSeconds, 20);
    });

    test('contact UUID doğru formatta', () {
      final re = RegExp(
        r'^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$',
      );
      expect(re.hasMatch(kContactTracingUuid), isTrue);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // Task 2.18: cross-platform contact advertisement helpers.
  // iOS yayını service UUID + local name format'ı kullanır; Android yayını
  // iBeacon major/minor format'ı kullanır. Encode/decode round-trip her iki
  // tarafta da aynı anonId'yi üretmeli.
  // ────────────────────────────────────────────────────────────────────────
  group('encodeAnonIdToLocalName', () {
    test('ilk 8 hex char alınır + "BTQ-" prefix eklenir', () {
      final ln = encodeAnonIdToLocalName(
        'a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e5f67890a1b2c3d4e5f67890',
      );
      expect(ln, 'BTQ-a1b2c3d4');
    });

    test('uppercase input lowercase\'e normalize edilir', () {
      final ln = encodeAnonIdToLocalName('DEADBEEF${'0' * 56}');
      expect(ln, 'BTQ-deadbeef');
    });

    test('kısa hash FormatException fırlatır', () {
      expect(() => encodeAnonIdToLocalName('abc'), throwsFormatException);
    });

    test('hex olmayan hash FormatException fırlatır', () {
      expect(
        () => encodeAnonIdToLocalName('zzzzzzzz${'0' * 56}'),
        throwsFormatException,
      );
    });
  });

  group('decodeLocalNameToAnonId', () {
    test('"BTQ-a1b2c3d4" → "a1b2:c3d4"', () {
      expect(decodeLocalNameToAnonId('BTQ-a1b2c3d4'), 'a1b2:c3d4');
    });

    test('uppercase hex → lowercase çıktı', () {
      expect(decodeLocalNameToAnonId('BTQ-DEADBEEF'), 'dead:beef');
    });

    test('null → null', () {
      expect(decodeLocalNameToAnonId(null), isNull);
    });

    test('prefix\'siz string → null (Beetinq paketi değil)', () {
      expect(decodeLocalNameToAnonId('Random Device'), isNull);
      expect(decodeLocalNameToAnonId('a1b2c3d4'), isNull);
    });

    test('eksik/geçersiz hex → null', () {
      expect(decodeLocalNameToAnonId('BTQ-zzzz'), isNull);
      expect(decodeLocalNameToAnonId('BTQ-a1b2'), isNull);
      expect(decodeLocalNameToAnonId('BTQ-a1b2c3d4ff'), isNull);
    });
  });

  group('Android iBeacon ↔ iOS localName platform tutarlılığı', () {
    test('aynı deviceIdHash her iki platformda aynı anonId üretir', () {
      final hash = '11223344${'0' * 56}';
      final ids = encodeDeviceId(hash);
      final androidAnonId = decodeAnonId(ids.major, ids.minor);
      final iosAnonId = decodeLocalNameToAnonId(encodeAnonIdToLocalName(hash));
      expect(androidAnonId, iosAnonId);
      expect(androidAnonId, '1122:3344');
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // Cross-platform contact KÖKTEN çözüm: anonId service UUID'ye gömülü.
  // Hem iOS hem Android cihaza-özel UUID yayar (prefix + anonId). Bu, plugin'in
  // Android'de localName yayamama kısıtını aşan ortak yol.
  // ────────────────────────────────────────────────────────────────────────
  group('encodeAnonIdToServiceUuid / decodeServiceUuidToAnonId', () {
    test('round-trip: deviceId → UUID → anonId (decodeAnonId ile uyumlu)', () {
      final hash = 'da9f52a4${'0' * 56}';
      final uuid = encodeAnonIdToServiceUuid(hash);
      // Son 8 hex = deviceId ilk 8 hex.
      expect(uuid.replaceAll('-', '').toLowerCase().endsWith('da9f52a4'), isTrue);
      // Decode anonId, decodeAnonId formatıyla aynı olmalı.
      expect(decodeServiceUuidToAnonId(uuid), 'da9f:52a4');
    });

    test('üretilen UUID geçerli canonical formatta', () {
      final uuid = encodeAnonIdToServiceUuid('abcdef01${'0' * 56}');
      final re = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      );
      expect(re.hasMatch(uuid), isTrue);
    });

    test('ortak prefix sabit, sadece son 8 hex cihaza göre değişir', () {
      final u1 = encodeAnonIdToServiceUuid('11111111${'0' * 56}');
      final u2 = encodeAnonIdToServiceUuid('22222222${'0' * 56}');
      final h1 = u1.replaceAll('-', '');
      final h2 = u2.replaceAll('-', '');
      expect(h1.substring(0, 24), h2.substring(0, 24)); // prefix aynı
      expect(h1.substring(24), isNot(h2.substring(24))); // anonId farklı
    });

    test('prefix taşımayan UUID → null (Beetinq paketi değil)', () {
      expect(decodeServiceUuidToAnonId('0000180a-0000-1000-8000-00805f9b34fb'),
          isNull);
      expect(decodeServiceUuidToAnonId(null), isNull);
      expect(decodeServiceUuidToAnonId('not-a-uuid'), isNull);
    });

    test('uppercase UUID de decode edilir (iOS upper döndürür)', () {
      final uuid = encodeAnonIdToServiceUuid('deadbeef${'0' * 56}');
      expect(decodeServiceUuidToAnonId(uuid.toUpperCase()), 'dead:beef');
    });

    test('kısa hash FormatException', () {
      expect(() => encodeAnonIdToServiceUuid('ab'), throwsFormatException);
    });

    test('service UUID anonId == decodeAnonId (tüm yollar tutarlı)', () {
      // Aynı cihaz: iBeacon, localName ve service UUID yolları aynı anonId vermeli.
      final hash = 'c0ffee42${'0' * 56}';
      final ids = encodeDeviceId(hash);
      final viaIBeacon = decodeAnonId(ids.major, ids.minor);
      final viaLocalName = decodeLocalNameToAnonId(encodeAnonIdToLocalName(hash));
      final viaServiceUuid =
          decodeServiceUuidToAnonId(encodeAnonIdToServiceUuid(hash));
      expect(viaServiceUuid, viaIBeacon);
      expect(viaServiceUuid, viaLocalName);
      expect(viaServiceUuid, 'c0ff:ee42');
    });
  });
}
