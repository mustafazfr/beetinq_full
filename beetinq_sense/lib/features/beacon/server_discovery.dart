import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

/// Otomatik backend keşfi (Task 2.19).
///
/// Saha günü kullanıcı IP yazmasın diye: cihazın kendi IPv4 subnet'ini
/// hesaplayıp /24 aralığını paralel tarar, `GET /api/discover` cevabı veren
/// ilk host'u backend olarak kabul eder.
///
/// **Neden mDNS değil**: Üniversite/kurumsal WiFi'lerde multicast genelde
/// blocked olduğu için mDNS sessizce başarısız olur. Subnet scan TCP
/// üzerinden çalışır, multicast'a bağımlı değildir.
///
/// **Neden /24**: Tipik konut/kurumsal LAN. /16 olsa 65k IP tarayıp 5 dk
/// beklemek gerekirdi. /24 → 254 IP × ~32 paralel = ~1-2 saniyede biter.
class ServerDiscovery {
  static const int _defaultPort = 3000;
  static const int _chunkSize = 32;
  static const Duration _perRequestTimeout = Duration(milliseconds: 500);

  /// LAN'da Beetinq backend'ini bulmaya çalışır.
  ///
  /// [port] backend port'u (default 3000).
  /// [overallTimeout] toplam max süre — bu süreden uzun sürse bile abort.
  ///
  /// Dönüş: bulunursa "http://x.y.z.w:port/api", yoksa null.
  Future<String?> discover({
    int port = _defaultPort,
    Duration overallTimeout = const Duration(seconds: 6),
  }) async {
    final completer = Completer<String?>();

    // Overall timeout — discovery hiç sonuçlanmazsa null döner.
    final timeoutTimer = Timer(overallTimeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });

    try {
      final candidates = await _gatherCandidates();
      if (candidates.isEmpty) {
        if (!completer.isCompleted) completer.complete(null);
        return completer.future;
      }

      // Chunk'lar halinde paralel probe. İlk başarılı cevap → completer.complete.
      // Geri kalan probe'lar arka planda devam edebilir, completer ikinci
      // complete'ı yutar.
      unawaited(_scanChunks(candidates, port, completer));
    } catch (e) {
      debugPrint('[ServerDiscovery] discover hatası: $e');
      if (!completer.isCompleted) completer.complete(null);
    }

    final result = await completer.future;
    timeoutTimer.cancel();
    return result;
  }

  /// Cihazın IPv4 adreslerinden /24 subnet host listesi üretir.
  /// IPv6 ve loopback hariç. Birden çok interface varsa hepsinin subnet'ini
  /// birleştirir (WiFi + cellular + hotspot).
  Future<List<String>> _gatherCandidates() async {
    final candidates = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          // BUG FIX (Mobil R12): Yalnızca private LAN subnet'lerini tara.
          // Android hotspot + cellular paralel açıkken cellular arayüzü de
          // dönüyordu → 254 ulaşılamaz cellular IP'sine boşa probe (pil/veri/
          // operatör throttle). Backend her zaman LAN'da → RFC1918 yeterli.
          if (!_isPrivateSubnet(parts)) continue;
          final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
          // Kendi IP'mizi de listede tutmak zararsız — backend kendine cevap
          // veremezse de doğal akış. Hattı kompleksleştirmeye gerek yok.
          for (int i = 1; i <= 254; i++) {
            candidates.add('$prefix.$i');
          }
        }
      }
    } catch (e) {
      debugPrint('[ServerDiscovery] interface list hatası: $e');
    }
    return candidates.toList();
  }

  /// RFC1918 private aralık kontrolü: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16.
  /// Cellular/public IP'leri eler — backend her zaman aynı LAN'da.
  static bool _isPrivateSubnet(List<String> parts) {
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    if (a == 10) return true;
    if (a == 192 && b == 168) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    return false;
  }

  Future<void> _scanChunks(
    List<String> hosts,
    int port,
    Completer<String?> completer,
  ) async {
    for (var i = 0; i < hosts.length; i += _chunkSize) {
      if (completer.isCompleted) return;
      final end = (i + _chunkSize).clamp(0, hosts.length);
      final chunk = hosts.sublist(i, end);
      final probes = chunk.map((h) => _probe(h, port, completer));
      await Future.wait(probes);
    }
    // Hiçbir chunk'ta bulunmadıysa null ile kapat.
    if (!completer.isCompleted) completer.complete(null);
  }

  Future<void> _probe(String host, int port, Completer<String?> completer) async {
    if (completer.isCompleted) return;
    try {
      final response = await http
          .get(Uri.parse('http://$host:$port/api/discover'))
          .timeout(_perRequestTimeout);
      if (response.statusCode != 200) return;
      final body = jsonDecode(response.body);
      if (body is! Map) return;
      if (body['service'] != 'beetinq') return;
      // Bulundu — completer'ı complete et (ilk başarı kazanır).
      if (!completer.isCompleted) {
        final url = 'http://$host:$port/api';
        debugPrint('[ServerDiscovery] backend bulundu: $url');
        completer.complete(url);
      }
    } catch (_) {
      // Timeout / connection refused / unreachable — sessizce atla.
      // Subnet'in çoğu IP'sinde cihaz olmaz, bu beklenen davranış.
    }
  }
}

final serverDiscoveryProvider = Provider<ServerDiscovery>(
  (ref) => ServerDiscovery(),
);
