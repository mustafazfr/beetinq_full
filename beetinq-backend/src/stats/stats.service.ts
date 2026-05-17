import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { ObjectLiteral, Repository, SelectQueryBuilder } from 'typeorm';

import { Visit } from '../visits/visit.entity';
import { Stand } from '../stands/stand.entity';
import { ContactEvent } from '../contacts/contact-event.entity';

@Injectable()
export class StatsService {
  constructor(
    @InjectRepository(Visit)
    private visitsRepository: Repository<Visit>,
    @InjectRepository(Stand)
    private standsRepository: Repository<Stand>,
    @InjectRepository(ContactEvent)
    private contactsRepository: Repository<ContactEvent>,
  ) {}

  /** Tarih filtresini query builder'a uygular (varsa). */
  private applyDateFilter<T extends ObjectLiteral>(
    qb: SelectQueryBuilder<T>,
    alias: string,
    from?: string,
    to?: string,
  ) {
    if (from) {
      qb.andWhere(`${alias}.enteredAt >= :from`, { from: new Date(from) });
    }
    if (to) {
      qb.andWhere(`${alias}.enteredAt <= :to`, { to: new Date(to) });
    }
    return qb;
  }

  async getDwellStats(from?: string, to?: string) {
    const qb = this.visitsRepository
      .createQueryBuilder('visit')
      .select('visit.locationName', 'locationName')
      .addSelect('AVG(visit.durationSeconds)', 'avgDuration')
      .addSelect('COUNT(*)', 'visitCount')
      .addSelect('COUNT(DISTINCT visit.deviceId)', 'uniqueVisitors')
      .groupBy('visit.locationName')
      .orderBy('avgDuration', 'DESC');

    this.applyDateFilter(qb, 'visit', from, to);
    const result = await qb.getRawMany();

    return result.map((r) => ({
      locationName: r.locationName,
      avgDuration: Math.round(Number(r.avgDuration) || 0),
      visitCount: Number(r.visitCount),
      uniqueVisitors: Number(r.uniqueVisitors),
    }));
  }

  /**
   * Heatmap: hem trilaterasyon tabanlı (x,y dolu) ziyaretleri hem de
   * fingerprint tabanlı (x,y boş) ziyaretleri stand'ın kendi koordinatına
   * düşürerek döndürür.
   *
   * İYİLEŞTİRME (önceki ham nokta-listesi yerine): trilaterasyon noktaları
   * 0.5m grid'e quantize edilip count ile aggregate edilir. Böylece
   * simpleheat'in `data` array'ine [x, y, count] gönderilebilir → asıl
   * "yoğun" alanlar görsel olarak baskın çıkar. Önceki kod her noktaya
   * count=1 veriyordu, sıcaklık dağılımı uniform görünüyordu.
   */
  async getHeatmapData(from?: string, to?: string) {
    // 1) Trilaterasyon tabanlı ham noktalar + 0.5m grid aggregation
    const trilatQb = this.visitsRepository
      .createQueryBuilder('visit')
      .select(['visit.x AS x', 'visit.y AS y', 'visit.locationName AS locationName'])
      .where('visit.x IS NOT NULL')
      .andWhere('visit.y IS NOT NULL');
    this.applyDateFilter(trilatQb, 'visit', from, to);
    const trilatRaw = await trilatQb.getRawMany();

    // 0.5m bucket: floor(x*2)/2, count++; locationName de en sık geçeni tut.
    const bucketMap = new Map<
      string,
      { x: number; y: number; locationName: string; count: number }
    >();
    for (const p of trilatRaw) {
      const bx = Math.floor(Number(p.x) * 2) / 2;
      const by = Math.floor(Number(p.y) * 2) / 2;
      const key = `${bx},${by}`;
      const existing = bucketMap.get(key);
      if (existing) {
        existing.count++;
      } else {
        bucketMap.set(key, {
          x: bx,
          y: by,
          locationName: p.locationName,
          count: 1,
        });
      }
    }
    const trilatPoints = Array.from(bucketMap.values());

    // 2) Fingerprint tabanlı ziyaretler için stand bazında aggregate
    const fpQb = this.visitsRepository
      .createQueryBuilder('visit')
      .select('visit.locationName', 'locationName')
      .addSelect('COUNT(*)', 'count')
      .where('visit.x IS NULL OR visit.y IS NULL')
      .groupBy('visit.locationName');
    this.applyDateFilter(fpQb, 'visit', from, to);
    const fpAggregates = await fpQb.getRawMany();

    // 3) Stand lookup ile koordinata düşür
    const stands = await this.standsRepository.find();
    const standMap = new Map(stands.map((s) => [s.name, s]));

    const fpPoints: Array<{ x: number; y: number; locationName: string; count: number }> = [];
    for (const agg of fpAggregates) {
      const stand = standMap.get(agg.locationName);
      if (!stand) continue; // Admin paneli bu stand'ı henüz tanımlamamış
      fpPoints.push({
        x: stand.x,
        y: stand.y,
        locationName: agg.locationName,
        count: Number(agg.count),
      });
    }

    return {
      trilateration: trilatPoints,
      fingerprint: fpPoints,
    };
  }

  async getSummary(from?: string, to?: string) {
    const qb = this.visitsRepository
      .createQueryBuilder('visit')
      .select('COUNT(*)', 'totalVisits')
      .addSelect('COUNT(DISTINCT visit.deviceId)', 'uniqueDevices')
      .addSelect('AVG(visit.durationSeconds)', 'avgDuration')
      .addSelect('SUM(visit.durationSeconds)', 'totalDuration');
    this.applyDateFilter(qb, 'visit', from, to);
    const row = await qb.getRawOne();

    const standCount = await this.standsRepository.count();

    return {
      totalVisits: Number(row?.totalVisits) || 0,
      uniqueDevices: Number(row?.uniqueDevices) || 0,
      avgDuration: Math.round(Number(row?.avgDuration) || 0),
      totalDuration: Number(row?.totalDuration) || 0,
      activeStands: standCount,
    };
  }

  /**
   * Contact tracing aggregate (Task 1.5.9).
   * - totalContacts: kayıt sayısı (her çift kontağını iki taraf da
   *   kaydederse 2 sayılır; "benzersiz çift" sayısı istenirse topPairs'e bak)
   * - uniqueDevicesInvolved: deviceId DISTINCT ∪ seenAnonId DISTINCT kümesi.
   *   seenAnonId anon hash olduğu için deviceId ile karşılaştırılamaz,
   *   dolayısıyla gerçek "benzersiz cihaz" sayısı bu iki kümenin birleşiminin
   *   üst sınırıdır. Tezde "tahmini" olarak belirt.
   * - avgDuration: saniye cinsinden tüm temasların ortalaması.
   * - topPairs: en çok tekrar eden (deviceId, seenAnonId) çiftleri, ilk 10.
   */
  async getContactStats(from?: string, to?: string) {
    const qb = this.contactsRepository
      .createQueryBuilder('c')
      .select('COUNT(*)', 'totalContacts')
      .addSelect('AVG(c.durationSeconds)', 'avgDuration');
    // Contact için tarih filtre kolonu firstSeenAt — ayrı helper yerine inline.
    if (from) qb.andWhere('c.firstSeenAt >= :from', { from: new Date(from) });
    if (to) qb.andWhere('c.firstSeenAt <= :to', { to: new Date(to) });
    const agg = await qb.getRawOne();

    // Unique devices (bir taraf): deviceId + seenAnonId kümelerinin birleşimi.
    const deviceQb = this.contactsRepository
      .createQueryBuilder('c')
      .select('DISTINCT c.deviceId', 'v');
    if (from) deviceQb.andWhere('c.firstSeenAt >= :from', { from: new Date(from) });
    if (to) deviceQb.andWhere('c.firstSeenAt <= :to', { to: new Date(to) });
    const deviceRows = await deviceQb.getRawMany();

    const anonQb = this.contactsRepository
      .createQueryBuilder('c')
      .select('DISTINCT c.seenAnonId', 'v');
    if (from) anonQb.andWhere('c.firstSeenAt >= :from', { from: new Date(from) });
    if (to) anonQb.andWhere('c.firstSeenAt <= :to', { to: new Date(to) });
    const anonRows = await anonQb.getRawMany();

    const unique = new Set<string>();
    for (const r of deviceRows) unique.add(`d:${r.v}`);
    for (const r of anonRows) unique.add(`a:${r.v}`);

    const pairsQb = this.contactsRepository
      .createQueryBuilder('c')
      .select('c.deviceId', 'deviceId')
      .addSelect('c.seenAnonId', 'seenAnonId')
      .addSelect('COUNT(*)', 'count')
      .groupBy('c.deviceId')
      .addGroupBy('c.seenAnonId')
      .orderBy('count', 'DESC')
      .limit(20);
    if (from) pairsQb.andWhere('c.firstSeenAt >= :from', { from: new Date(from) });
    if (to) pairsQb.andWhere('c.firstSeenAt <= :to', { to: new Date(to) });
    const pairs = await pairsQb.getRawMany();

    return {
      totalContacts: Number(agg?.totalContacts) || 0,
      uniqueDevicesInvolved: unique.size,
      avgDuration: Math.round(Number(agg?.avgDuration) || 0),
      topPairs: pairs.map((p) => ({
        deviceId: `${String(p.deviceId).slice(0, 8)}…`, // PII: sadece prefix
        seenAnonId: p.seenAnonId,
        count: Number(p.count),
      })),
    };
  }

  /**
   * Saat bazında trafik: 24 saatlik dilimlerde ziyaret sayısı ve unique device.
   * Saat = enteredAt'in lokal saat (00-23). Pratikte SQLite timezone neutral
   * tutulduğu için server timezone'una göre çıkar. Tez raporu için yeterli.
   */
  async getHourlyTraffic(from?: string, to?: string) {
    // SQLite specific: strftime('%H', enteredAt) → '00'..'23'
    const qb = this.visitsRepository
      .createQueryBuilder('visit')
      .select("strftime('%H', visit.enteredAt)", 'hour')
      .addSelect('COUNT(*)', 'visitCount')
      .addSelect('COUNT(DISTINCT visit.deviceId)', 'uniqueDevices')
      .groupBy("strftime('%H', visit.enteredAt)")
      .orderBy('hour', 'ASC');
    this.applyDateFilter(qb, 'visit', from, to);
    const rows = await qb.getRawMany();

    // 0..23 saat slot'larını boşları da doldurarak döndür (frontend bar
    // chart'ı için sabit kova sayısı kullanışlı).
    const byHour = new Map(
      rows.map((r) => [
        Number(r.hour),
        {
          hour: Number(r.hour),
          visitCount: Number(r.visitCount),
          uniqueDevices: Number(r.uniqueDevices),
        },
      ]),
    );
    const result: Array<{
      hour: number;
      visitCount: number;
      uniqueDevices: number;
    }> = [];
    for (let h = 0; h < 24; h++) {
      result.push(
        byHour.get(h) ?? { hour: h, visitCount: 0, uniqueDevices: 0 },
      );
    }
    return result;
  }

  /**
   * Son N dakika içinde herhangi bir aktivite (visit veya contact) gönderen
   * unique cihaz sayısı. "Şu an aktif" göstergesi için.
   *
   * Visit: enteredAt VEYA exitedAt son N dk içindeyse aktif.
   * Contact: lastSeenAt son N dk içindeyse aktif.
   */
  async getActiveNow(minutes = 5) {
    const cutoff = new Date(Date.now() - minutes * 60 * 1000);

    const visitDevices = await this.visitsRepository
      .createQueryBuilder('v')
      .select('DISTINCT v.deviceId', 'deviceId')
      .where('v.exitedAt >= :cutoff', { cutoff })
      .orWhere('v.enteredAt >= :cutoff', { cutoff })
      .getRawMany();

    const contactDevices = await this.contactsRepository
      .createQueryBuilder('c')
      .select('DISTINCT c.deviceId', 'deviceId')
      .where('c.lastSeenAt >= :cutoff', { cutoff })
      .getRawMany();

    const active = new Set<string>();
    for (const r of visitDevices) active.add(r.deviceId);
    for (const r of contactDevices) active.add(r.deviceId);

    return {
      windowMinutes: minutes,
      activeDevices: active.size,
      asOf: new Date().toISOString(),
    };
  }

  /**
   * positionSource bazında ziyaret dağılımı (fingerprint vs trilateration vs
   * unknown). Pie chart için. Tarih filtreli.
   */
  async getSourceDistribution(from?: string, to?: string) {
    const qb = this.visitsRepository
      .createQueryBuilder('visit')
      .select(
        "COALESCE(visit.positionSource, 'unknown')",
        'source',
      )
      .addSelect('COUNT(*)', 'count')
      .groupBy('source');
    this.applyDateFilter(qb, 'visit', from, to);
    const rows = await qb.getRawMany();

    // Üç sabit kova: fingerprint, trilateration, unknown.
    const out = { fingerprint: 0, trilateration: 0, unknown: 0 };
    let total = 0;
    for (const r of rows) {
      const k = (r.source as string) ?? 'unknown';
      const n = Number(r.count) || 0;
      total += n;
      if (k === 'fingerprint') out.fingerprint += n;
      else if (k === 'trilateration') out.trilateration += n;
      else out.unknown += n;
    }
    return { ...out, total };
  }

  /**
   * Dwell time histogram: 5 sabit kova.
   * 0-30s, 30-60s, 60-120s, 120-300s, 300+s. Stand bazlı opsiyonel.
   * Histogram için frontend bar chart çizer.
   */
  async getDwellDistribution(
    from?: string,
    to?: string,
    locationName?: string,
  ) {
    const qb = this.visitsRepository
      .createQueryBuilder('visit')
      .select('visit.durationSeconds', 'd');
    this.applyDateFilter(qb, 'visit', from, to);
    if (locationName) {
      qb.andWhere('visit.locationName = :ln', { ln: locationName });
    }
    const rows = await qb.getRawMany();

    const buckets = [
      { label: '0-30s', min: 0, max: 30, count: 0 },
      { label: '30-60s', min: 30, max: 60, count: 0 },
      { label: '1-2 dk', min: 60, max: 120, count: 0 },
      { label: '2-5 dk', min: 120, max: 300, count: 0 },
      { label: '5+ dk', min: 300, max: Infinity, count: 0 },
    ];

    for (const r of rows) {
      const d = Number(r.d) || 0;
      for (const b of buckets) {
        if (d >= b.min && d < b.max) {
          b.count++;
          break;
        }
      }
    }

    return {
      total: rows.length,
      locationName: locationName ?? null,
      buckets: buckets.map((b) => ({ label: b.label, count: b.count })),
    };
  }

  /**
   * Tüm ziyaretleri CSV format'ında stream'lemek için raw veri döndürür.
   * Controller bunu CSV'ye serialize edip Content-Type ile gönderir.
   */
  async getAllVisitsForCsv(from?: string, to?: string) {
    const qb = this.visitsRepository
      .createQueryBuilder('visit')
      .select([
        'visit.id',
        'visit.deviceId',
        'visit.locationName',
        'visit.enteredAt',
        'visit.exitedAt',
        'visit.durationSeconds',
        'visit.positionSource',
        'visit.x',
        'visit.y',
        'visit.createdAt',
      ])
      .orderBy('visit.enteredAt', 'ASC');
    this.applyDateFilter(qb, 'visit', from, to);
    return qb.getMany();
  }
}
