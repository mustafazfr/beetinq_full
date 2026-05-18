import { Controller, Get } from '@nestjs/common';
import { SkipThrottle } from '@nestjs/throttler';

/**
 * Mobil tarafın otomatik backend keşfi için endpoint (Task 2.19).
 *
 * Mobil cihaz açılışta kendi IPv4 subnet'ini tarar; her IP'ye paralel
 * `GET /api/discover` atar. İlk 200 + `service:"beetinq"` cevabı veren
 * IP, backend olarak kabul edilir ve SharedPreferences'a kaydedilir.
 *
 * @SkipThrottle: 32 paralel scan içinde rate-limit (10/sn) tetiklenmesin.
 * Cevap minimum — ağ trafiği düşük tutuldu.
 */
// Named throttler'larda parametresiz @SkipThrottle() çalışmıyor —
// app.module.ts'te 'short' ve 'long' adlı iki ThrottlerModule var,
// her birini explicit bypass etmek gerekiyor. Aksi takdirde 32 paralel
// subnet probe'unda 10/sn limit tetiklenip 429 dönüyor (smoke test bulgusu).
@Controller('discover')
@SkipThrottle({ short: true, long: true })
export class DiscoveryController {
  @Get()
  discover(): { service: string; version: number; serverTime: string } {
    return {
      service: 'beetinq',
      version: 1,
      serverTime: new Date().toISOString(),
    };
  }
}
