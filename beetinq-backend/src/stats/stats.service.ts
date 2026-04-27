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
   * düşürerek döndürür. Böylece fingerprint ziyaretleri de haritada görünür.
   */
  async getHeatmapData(from?: string, to?: string) {
    // 1) Trilaterasyon tabanlı ham noktalar
    const trilatQb = this.visitsRepository
      .createQueryBuilder('visit')
      .select(['visit.x AS x', 'visit.y AS y', 'visit.locationName AS locationName'])
      .where('visit.x IS NOT NULL')
      .andWhere('visit.y IS NOT NULL');
    this.applyDateFilter(trilatQb, 'visit', from, to);
    const trilatPoints = await trilatQb.getRawMany();

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
      trilateration: trilatPoints.map((p) => ({
        x: Number(p.x),
        y: Number(p.y),
        locationName: p.locationName,
      })),
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
    this.applyDateFilter(qb, 'c', from, to);
    const agg = await qb.getRawOne();

    // Unique devices (bir taraf): deviceId + seenAnonId kümelerinin birleşimi.
    const deviceRows = await this.applyDateFilter(
      this.contactsRepository
        .createQueryBuilder('c')
        .select('DISTINCT c.deviceId', 'v'),
      'c',
      from,
      to,
    ).getRawMany();
    const anonRows = await this.applyDateFilter(
      this.contactsRepository
        .createQueryBuilder('c')
        .select('DISTINCT c.seenAnonId', 'v'),
      'c',
      from,
      to,
    ).getRawMany();
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
      .limit(10);
    this.applyDateFilter(pairsQb, 'c', from, to);
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
}
