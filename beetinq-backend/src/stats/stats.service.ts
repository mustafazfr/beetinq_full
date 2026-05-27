import { Injectable } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { ObjectLiteral, Repository, SelectQueryBuilder } from 'typeorm';
import type { Writable } from 'stream';
import PDFDocument from 'pdfkit';

import { Visit } from '../visits/visit.entity';
import { Stand } from '../stands/stand.entity';
import { ContactEvent } from '../contacts/contact-event.entity';
import { AccuracySample } from '../accuracy/accuracy-sample.entity';

@Injectable()
export class StatsService {
  constructor(
    @InjectRepository(Visit)
    private visitsRepository: Repository<Visit>,
    @InjectRepository(Stand)
    private standsRepository: Repository<Stand>,
    @InjectRepository(ContactEvent)
    private contactsRepository: Repository<ContactEvent>,
    @InjectRepository(AccuracySample)
    private accuracyRepository: Repository<AccuracySample>,
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
      // BUG FIX (R1): SQL operator precedence — AND OR'dan yüksek precedence
      // taşır. Eski hali `.where('x IS NULL OR y IS NULL').andWhere('enteredAt >= :from')`
      // sonra SQL üretirken `x IS NULL OR y IS NULL AND enteredAt >= :from` haline
      // gelir → tarih filtresi sadece y IS NULL satırlara uygulanır, x IS NULL
      // tüm geçmiş ziyaretler filtreden bağımsız sızar. Dış parantez ile çözüldü.
      .where('(visit.x IS NULL OR visit.y IS NULL)')
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
   * Raporlayan cihazın tam hash deviceId'sini, karşı tarafın gördüğü anonId
   * formatına (xxxx:yyyy) indirger. Mobildeki encodeDeviceId + decodeAnonId
   * ile AYNI mantık: SHA-256'nın ilk 4 byte'ı major:minor olur.
   *
   * Böylece "A raporladı" (deviceId) ile "biri A'yı gördü" (seenAnonId) aynı
   * kimliğe çöker → her cihaz tek düğüm/satır olur, graf/matris anlam kazanır.
   */
  private deviceIdToAnonId(deviceId: string): string {
    const prefix = deviceId.slice(0, 8).toLowerCase();
    if (!/^[0-9a-f]{8}$/.test(prefix)) {
      // Beklenmeyen format (eski/fallback id) — prefix'i olduğu gibi anahtarla.
      return deviceId.slice(0, 9);
    }
    return `${prefix.slice(0, 4)}:${prefix.slice(4, 8)}`;
  }

  /**
   * Contact tracing aggregate — kimlik normalize edilmiş.
   *
   * Her temas kaydı asimetrik (deviceId = raporlayan tam hash, seenAnonId =
   * görülen anon). Burada deviceId de anonId'ye indirgenip temas YÖNSÜZ çift
   * olarak toplanır (A↔B = B↔A). Çıktı:
   * - totalContacts: ham kayıt sayısı
   * - uniqueDevicesInvolved: GERÇEK benzersiz kişi sayısı (artık üst sınır değil)
   * - participants: kişi listesi (anonId + temas sayısı + toplam süre) — matris ekseni
   * - pairs: yönsüz temas çiftleri (count, toplam/ort süre, ort RSSI) — matris hücreleri + liste
   * - topPairs: ilk 10 (geriye dönük uyumluluk için a/b alanlı)
   */
  async getContactStats(from?: string, to?: string) {
    const qb = this.contactsRepository.createQueryBuilder('c');
    if (from) qb.andWhere('c.firstSeenAt >= :from', { from: new Date(from) });
    if (to) qb.andWhere('c.firstSeenAt <= :to', { to: new Date(to) });
    const rows = await qb.getMany();

    // Yönsüz çift + kişi aggregate (JS — fuar ölçeğinde kayıt sayısı yönetilebilir).
    const pairMap = new Map<
      string,
      { a: string; b: string; count: number; totalDuration: number; rssiSum: number }
    >();
    const persons = new Map<
      string,
      { anonId: string; contacts: number; totalDuration: number; degree: number }
    >();
    let durationSum = 0;

    // Stand bazlı temas: hangi standda kaç temas oldu (networking hotspot).
    const standMap = new Map<string, { locationName: string; count: number; totalDuration: number }>();

    // Temas süresi dağılımı (her ölçekte okunur — binlerce temasta bile 5 kova).
    const durationBuckets = [
      { label: '<1dk', min: 0, max: 60, count: 0 },
      { label: '1-2dk', min: 60, max: 120, count: 0 },
      { label: '2-5dk', min: 120, max: 300, count: 0 },
      { label: '5-10dk', min: 300, max: 600, count: 0 },
      { label: '10dk+', min: 600, max: Infinity, count: 0 },
    ];

    for (const r of rows) {
      const a = this.deviceIdToAnonId(r.deviceId);
      const b = r.seenAnonId;
      durationSum += r.durationSeconds;

      // Süre dağılımı (self dahil — her temas kaydı sayılır).
      for (const bucket of durationBuckets) {
        if (r.durationSeconds >= bucket.min && r.durationSeconds < bucket.max) {
          bucket.count++;
          break;
        }
      }

      // Stand bazlı temas (konum dolu olanlar).
      if (r.locationName) {
        const sm =
          standMap.get(r.locationName) ??
          { locationName: r.locationName, count: 0, totalDuration: 0 };
        sm.count++;
        sm.totalDuration += r.durationSeconds;
        standMap.set(r.locationName, sm);
      }

      if (a === b) continue; // self-contact güvenlik filtresi

      // Yönsüz: alfabetik sırala ki A↔B ve B↔A aynı hücreye düşsün.
      const [x, y] = a < b ? [a, b] : [b, a];
      const key = `${x}|${y}`;
      const p =
        pairMap.get(key) ??
        { a: x, b: y, count: 0, totalDuration: 0, rssiSum: 0 };
      p.count++;
      p.totalDuration += r.durationSeconds;
      p.rssiSum += r.avgRssi;
      pairMap.set(key, p);

      for (const id of [a, b]) {
        const pr =
          persons.get(id) ??
          { anonId: id, contacts: 0, totalDuration: 0, degree: 0 };
        pr.contacts++;
        pr.totalDuration += r.durationSeconds;
        persons.set(id, pr);
      }
    }

    // Derece (degree) = bir kişinin temas ettiği FARKLI kişi sayısı. Yönsüz
    // benzersiz çiftlerden türetilir — her çift iki tarafın derecesini +1 yapar.
    for (const p of pairMap.values()) {
      const pa = persons.get(p.a);
      if (pa) pa.degree++;
      const pb = persons.get(p.b);
      if (pb) pb.degree++;
    }

    const pairs = Array.from(pairMap.values())
      .map((p) => ({
        a: p.a,
        b: p.b,
        count: p.count,
        totalDuration: p.totalDuration,
        avgDuration: Math.round(p.totalDuration / p.count),
        avgRssi: Math.round(p.rssiSum / p.count),
      }))
      .sort((m, n) => n.count - m.count || n.totalDuration - m.totalDuration);

    // En aktif kişiler önce (en çok farklı kişiyle temas eden = potansiyel "hub").
    const participants = Array.from(persons.values()).sort(
      (m, n) => n.degree - m.degree || n.totalDuration - m.totalDuration,
    );

    // Kişi başı temas (derece) dağılımı — ölçekten bağımsız okunur.
    const degreeBuckets = [
      { label: '1 kişi', min: 1, max: 1, count: 0 },
      { label: '2-3', min: 2, max: 3, count: 0 },
      { label: '4-6', min: 4, max: 6, count: 0 },
      { label: '7-10', min: 7, max: 10, count: 0 },
      { label: '11+', min: 11, max: Infinity, count: 0 },
    ];
    for (const p of participants) {
      for (const bucket of degreeBuckets) {
        if (p.degree >= bucket.min && p.degree <= bucket.max) {
          bucket.count++;
          break;
        }
      }
    }

    const personCount = persons.size;
    // Kişi başı ortalama temas (farklı kişi) = Σderece / kişi = 2·|çift| / kişi.
    const avgContactsPerPerson =
      personCount > 0 ? +((2 * pairs.length) / personCount).toFixed(1) : 0;

    return {
      totalContacts: rows.length,
      uniqueDevicesInvolved: personCount,
      avgDuration: rows.length ? Math.round(durationSum / rows.length) : 0,
      avgContactsPerPerson,
      // Matris yalnız küçük etkinlikte anlamlı (N² hücre); büyükse panel
      // dağılımlara döner. Eşik 15: 15×15=225 hücre hâlâ okunur.
      showMatrix: personCount > 0 && personCount <= 15,
      participants,
      pairs,
      durationDistribution: durationBuckets.map((b) => ({
        label: b.label,
        count: b.count,
      })),
      // Stand bazlı temas (en çok temas olan stand önce) — networking hotspot.
      standBreakdown: Array.from(standMap.values()).sort(
        (m, n) => n.count - m.count,
      ),
      degreeDistribution: degreeBuckets.map((b) => ({
        label: b.label,
        count: b.count,
      })),
      // Geriye dönük uyumluluk (eski panel/PDF alanları a→deviceId, b→seenAnonId).
      topPairs: pairs.slice(0, 10).map((p) => ({
        deviceId: p.a,
        seenAnonId: p.b,
        count: p.count,
      })),
    };
  }

  /**
   * Ham temas kayıtları — "KİM KİMİ NE ZAMAN gördü" okunur listesi için.
   *
   * getContactStats aggregate döndürür (matris/çiftler); bu method ise her
   * temas olayını tek tek, yönlü olarak döndürür:
   * - reporterAnonId: raporlayan cihazın tam hash'i anonId'ye indirgenmiş
   *   ("xxxx:yyyy"). seenAnonId ile AYNI formatta → panelde net karşılaştırma.
   * - seenAnonId: görülen cihazın anon kimliği (DB'de zaten kısa).
   * - firstSeenAt / lastSeenAt: ISO string (format panelde yapılır).
   * - durationSeconds, avgRssi, locationName: olduğu gibi.
   *
   * YÖN-BAĞIMSIZ birleştirme (kullanıcı kararı: "tek sürekli temas"):
   * A→B ve B→A aynı fiziksel temasın iki cihazın gözünden hâli; tek satırda
   * "A ↔ B" olarak birleştirilir. Aynı çiftin tüm yönlü/parçalı kayıtları
   * toplanır: süre = en geç bitiş − en erken başlangıç, RSSI = en güçlü (en
   * yakın an), stand = en baskın konum, eventCount = kaç ham kayıt birleşti.
   * Böylece dashboard "8 parça" yerine tek temas gösterir. En yeni üstte.
   */
  async getContactEvents(from?: string, to?: string) {
    const qb = this.contactsRepository.createQueryBuilder('c');
    if (from) qb.andWhere('c.firstSeenAt >= :from', { from: new Date(from) });
    if (to) qb.andWhere('c.firstSeenAt <= :to', { to: new Date(to) });
    const rows = await qb.getMany();

    const toDate = (v: Date | string) => (v instanceof Date ? v : new Date(v));

    // Yön-bağımsız çift anahtarı (sıralı) → birleşik kayıt.
    const pairs = new Map<
      string,
      {
        anonA: string;
        anonB: string;
        firstSeenAt: Date;
        lastSeenAt: Date;
        bestRssi: number;
        locCounts: Record<string, number>;
        eventCount: number;
      }
    >();

    for (const r of rows) {
      const a = this.deviceIdToAnonId(r.deviceId);
      const b = r.seenAnonId;
      const [lo, hi] = a < b ? [a, b] : [b, a];
      const key = `${lo}|${hi}`;
      const first = toDate(r.firstSeenAt);
      const last = toDate(r.lastSeenAt);
      const locKey = r.locationName ?? '';
      const cur = pairs.get(key);
      if (!cur) {
        pairs.set(key, {
          anonA: lo,
          anonB: hi,
          firstSeenAt: first,
          lastSeenAt: last,
          bestRssi: r.avgRssi,
          locCounts: { [locKey]: 1 },
          eventCount: 1,
        });
      } else {
        if (first < cur.firstSeenAt) cur.firstSeenAt = first;
        if (last > cur.lastSeenAt) cur.lastSeenAt = last;
        if (r.avgRssi > cur.bestRssi) cur.bestRssi = r.avgRssi; // negatif → büyük = yakın
        cur.locCounts[locKey] = (cur.locCounts[locKey] ?? 0) + 1;
        cur.eventCount++;
      }
    }

    const result = [...pairs.values()].map((p) => {
      // En baskın stand (boş anahtar = konumsuz).
      const dom = Object.entries(p.locCounts).sort((x, y) => y[1] - x[1])[0][0];
      return {
        reporterAnonId: p.anonA, // UI alan adları korundu; artık yön-bağımsız çift
        seenAnonId: p.anonB,
        firstSeenAt: p.firstSeenAt.toISOString(),
        lastSeenAt: p.lastSeenAt.toISOString(),
        durationSeconds: Math.round(
          (p.lastSeenAt.getTime() - p.firstSeenAt.getTime()) / 1000,
        ),
        avgRssi: Math.round(p.bestRssi),
        locationName: dom === '' ? null : dom,
        eventCount: p.eventCount,
      };
    });
    // En yeni üstte.
    result.sort((a, b) => b.lastSeenAt.localeCompare(a.lastSeenAt));
    return result;
  }

  /**
   * Konum doğruluğu özeti — tez accuracy metriği. Kullanıcının saha
   * ölçümlerinden (AccuracySample) hesaplanır:
   * - fingerprintAccuracy: fingerprint tahminlerinde isabet yüzdesi.
   * - meanError / medianError: trilaterasyon hata mesafesi (m), errorMeters
   *   dolu örnekler üzerinden.
   * - byLocation: stand bazında isabet (hangi stand zor ayırt ediliyor).
   */
  async getAccuracyStats(from?: string, to?: string) {
    const qb = this.accuracyRepository.createQueryBuilder('a');
    if (from) qb.andWhere('a.createdAt >= :from', { from: new Date(from) });
    if (to) qb.andWhere('a.createdAt <= :to', { to: new Date(to) });
    const rows = await qb.getMany();

    const total = rows.length;
    const fpRows = rows.filter((r) => r.positionSource === 'fingerprint');
    const fpCorrect = fpRows.filter((r) => r.correct).length;
    const errors = rows
      .map((r) => r.errorMeters)
      .filter((e): e is number => e != null)
      .sort((a, b) => a - b);

    const mean =
      errors.length > 0
        ? errors.reduce((s, e) => s + e, 0) / errors.length
        : null;
    const median =
      errors.length > 0
        ? errors.length % 2
          ? errors[(errors.length - 1) / 2]
          : (errors[errors.length / 2 - 1] + errors[errors.length / 2]) / 2
        : null;

    // Stand bazında isabet.
    const byLoc = new Map<string, { total: number; correct: number }>();
    for (const r of rows) {
      const g = byLoc.get(r.groundTruth) ?? { total: 0, correct: 0 };
      g.total++;
      if (r.correct) g.correct++;
      byLoc.set(r.groundTruth, g);
    }

    return {
      totalSamples: total,
      fingerprintSamples: fpRows.length,
      fingerprintCorrect: fpCorrect,
      fingerprintAccuracy:
        fpRows.length > 0 ? Math.round((fpCorrect / fpRows.length) * 100) : null,
      meanErrorMeters: mean != null ? +mean.toFixed(2) : null,
      medianErrorMeters: median != null ? +median.toFixed(2) : null,
      errorSampleCount: errors.length,
      byLocation: [...byLoc.entries()]
        .map(([name, g]) => ({
          name,
          total: g.total,
          correct: g.correct,
          accuracy: Math.round((g.correct / g.total) * 100),
        }))
        .sort((a, b) => a.accuracy - b.accuracy), // zayıf üstte
    };
  }

  /**
   * Saat bazında trafik: 24 saatlik dilimlerde ziyaret sayısı ve unique device.
   *
   * BUG FIX (R5 — sunum etkili): TypeORM datetime kolonunu SQLite'a UTC ISO
   * olarak yazar; strftime default UTC kabul eder. TR (UTC+3) demosunda saat
   * 14:30 gelen visit "11" kovasına düşüyordu → bar chart yanıltıcıydı,
   * tez sunumunda saatler tutarsız görünebilirdi. `'localtime'` modifier'ı
   * SQLite'a "kayıttaki UTC değeri server local saatine çevir" der.
   */
  async getHourlyTraffic(from?: string, to?: string) {
    // SQLite specific: strftime('%H', enteredAt, 'localtime') → '00'..'23' (server local)
    const qb = this.visitsRepository
      .createQueryBuilder('visit')
      .select("strftime('%H', visit.enteredAt, 'localtime')", 'hour')
      .addSelect('COUNT(*)', 'visitCount')
      .addSelect('COUNT(DISTINCT visit.deviceId)', 'uniqueDevices')
      .groupBy("strftime('%H', visit.enteredAt, 'localtime')")
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
   * Etkinlik sonrası analiz raporu (PDF) — Sia özetindeki "PDF/Panel"
   * çıktısı. Tarih filtreli özet + stand bazlı dwell tablosu + kaynak
   * dağılımı + temas özeti içerir.
   *
   * Türkçe karakter notu: PDFKit'in built-in fontları (Helvetica/Times)
   * WinAnsi encoding kullanır; ı/ş/ğ gibi karakterleri "?" ile çizer.
   * Asset font eklemek yerine ASCII downgrade ettik — saha demosu için
   * yeterli, tezde ek olarak normal Türkçe yazı yazılır.
   */
  async generatePdfReport(
    from: string | undefined,
    to: string | undefined,
    out: Writable,
  ) {
    const [summary, dwell, sources, contacts] = await Promise.all([
      this.getSummary(from, to),
      this.getDwellStats(from, to),
      this.getSourceDistribution(from, to),
      this.getContactStats(from, to),
    ]);

    const tr2ascii = (s: string) =>
      s.replace(/[İıŞşĞğÜüÖöÇç]/g, (c) =>
        (({
          İ: 'I',
          ı: 'i',
          Ş: 'S',
          ş: 's',
          Ğ: 'G',
          ğ: 'g',
          Ü: 'U',
          ü: 'u',
          Ö: 'O',
          ö: 'o',
          Ç: 'C',
          ç: 'c',
        } as Record<string, string>)[c] ?? c),
      );
    const t = (s: string) => tr2ascii(s);

    const doc = new PDFDocument({ margin: 50, size: 'A4' });
    doc.pipe(out);

    // ── Header ────────────────────────────────────────────────────────
    doc
      .fontSize(22)
      .fillColor('#111')
      .text(t('Beetinq Sense — Etkinlik Analiz Raporu'), { align: 'center' });
    doc.moveDown(0.2);
    doc
      .fontSize(10)
      .fillColor('#666')
      .text(
        t(
          `Olusturuldu: ${new Date().toLocaleString('tr-TR')}  -  ` +
            `Donem: ${from ? new Date(from).toLocaleDateString('tr-TR') : 'baslangic'} - ` +
            `${to ? new Date(to).toLocaleDateString('tr-TR') : 'su an'}`,
        ),
        { align: 'center' },
      );
    doc.moveDown();
    doc.moveTo(50, doc.y).lineTo(545, doc.y).strokeColor('#ddd').stroke();
    doc.moveDown(0.8);

    // ── Özet ─────────────────────────────────────────────────────────
    doc.fontSize(14).fillColor('#111').text(t('1. Genel Ozet'));
    doc.moveDown(0.4);
    doc.fontSize(11).fillColor('#222');
    // Sadeleştirildi: "Toplam Bekleme (sn)" ve "Temasa Giren Cihaz (~)"
    // çıkarıldı — anlamsız büyük sayı / kafa karıştıran tilde. Süreler
    // dakika:saniye olarak okunur biçimde.
    const fmtDur = (sec: number) => {
      const m = Math.floor(sec / 60);
      const s = sec % 60;
      return m > 0 ? `${m} dk ${s} sn` : `${s} sn`;
    };
    const metrics: Array<[string, string]> = [
      [t('Toplam Ziyaret'), `${summary.totalVisits}`],
      [t('Benzersiz Cihaz'), `${summary.uniqueDevices}`],
      [t('Ortalama Bekleme'), fmtDur(summary.avgDuration)],
      [t('Aktif Stand'), `${summary.activeStands}`],
      [t('Toplam Temas'), `${contacts.totalContacts}`],
      [t('Ortalama Temas Suresi'), fmtDur(contacts.avgDuration)],
    ];
    for (const [label, value] of metrics) {
      doc.text(`  ${label}: ${value}`);
    }
    doc.moveDown();

    // ── Stand bazlı dwell ────────────────────────────────────────────
    doc.fontSize(14).fillColor('#111').text(t('2. Stand Bazli Bekleme Sureleri'));
    doc.moveDown(0.4);
    doc.fontSize(11).fillColor('#222');
    // Sahte "stand"ları ele: trilaterasyon bazen beacon etiketini ("1-2",
    // "1-3" gibi major-minor) locationName olarak yazıyor; bunlar gerçek stand
    // değil, rapora kirlilik katıyor. major-minor desenini filtrele.
    const realDwell = dwell.filter((d) => !/^\d+-\d+$/.test(d.locationName));
    const left = doc.page.margins.left; // 50
    if (realDwell.length === 0) {
      doc.text(t('  (Bu donemde stand ziyareti bulunmuyor.)'));
    } else {
      // Sabit kolonlar (mutlak X). Tablo bittikten sonra akış metni için x
      // sol marja resetlenir (yoksa sonraki metin dar sağ kolona sıkışıyordu).
      const col1 = 60;
      const col2 = 300;
      const col3 = 390;
      const col4 = 470;
      const header = () => {
        const rowY = doc.y;
        doc
          .fillColor('#666')
          .fontSize(10)
          .text(t('Stand'), col1, rowY, { width: 230 })
          .text(t('Ort. Sure'), col2, rowY, { width: 80 })
          .text(t('Ziyaret'), col3, rowY, { width: 70 })
          .text(t('Cihaz'), col4, rowY, { width: 70 });
        doc.moveDown(0.3);
        doc.fillColor('#222').fontSize(11);
      };
      header();
      for (const d of realDwell) {
        // Sayfa-bölme: satır sayfa sonuna yaklaşırsa yeni sayfa + başlık.
        if (doc.y > doc.page.height - doc.page.margins.bottom - 24) {
          doc.addPage();
          doc.fontSize(11).fillColor('#222');
          header();
        }
        const y = doc.y;
        doc
          .text(t(d.locationName), col1, y, { width: 230 })
          .text(fmtDur(d.avgDuration), col2, y, { width: 80 })
          .text(`${d.visitCount}`, col3, y, { width: 70 })
          .text(`${d.uniqueVisitors}`, col4, y, { width: 70 });
        doc.moveDown(0.2);
      }
    }
    // Mutlak-X tablodan sonra akış metnini sol marja + tam genişliğe döndür.
    doc.text('', left, doc.y);
    doc.moveDown(1.2);

    // ── KVKK notu ────────────────────────────────────────────────────
    // Bölüm 3 (kaynak dağılımı %) ve 4 (ham anonId çiftleri) kaldırıldı:
    // teknik/anlamsız bilgiydi, rapora değer katmıyordu.
    doc.fontSize(9).fillColor('#888');
    doc.text(
      t(
        'KVKK/GDPR uyumu: Tum cihaz kimlikleri SHA-256 ile anonim tutulur, ' +
          'MAC adresi veya kisisel veri kaydedilmez. Veriler 14 gun sonra otomatik silinir. ' +
          'Kullanici Konum ve Temas Analizi ayarlarini istedigi zaman kapatabilir.',
      ),
      left,
      doc.y,
      { align: 'justify', width: doc.page.width - left - doc.page.margins.right },
    );

    doc.end();
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
