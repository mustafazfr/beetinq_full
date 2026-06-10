import { Test, TestingModule } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';

import { StatsService } from './stats.service';
import { Visit } from '../visits/visit.entity';
import { Stand } from '../stands/stand.entity';
import { ContactEvent } from '../contacts/contact-event.entity';
import { AccuracySample } from '../accuracy/accuracy-sample.entity';

/**
 * 2026-06-10 bug avı — panelin beslendiği stats endpoint'lerinin edge-case
 * testleri: heatmap sentinel stand'lar, accuracy medyan, dwell histogram kova
 * sınırları, contact self-filtresi.
 */
describe('StatsService — panel endpoint edge-case testleri', () => {
  let service: StatsService;

  // Her repo için ayrı yeniden kurulabilir query-builder mock'u.
  const qbMock = () => ({
    select: jest.fn().mockReturnThis(),
    addSelect: jest.fn().mockReturnThis(),
    where: jest.fn().mockReturnThis(),
    andWhere: jest.fn().mockReturnThis(),
    orWhere: jest.fn().mockReturnThis(),
    groupBy: jest.fn().mockReturnThis(),
    orderBy: jest.fn().mockReturnThis(),
    getRawMany: jest.fn().mockResolvedValue([]),
    getRawOne: jest.fn().mockResolvedValue(null),
    getMany: jest.fn().mockResolvedValue([]),
  });

  let visitQb: ReturnType<typeof qbMock>;
  let contactQb: ReturnType<typeof qbMock>;
  let accuracyQb: ReturnType<typeof qbMock>;
  let standsFind: jest.Mock;

  beforeEach(async () => {
    visitQb = qbMock();
    contactQb = qbMock();
    accuracyQb = qbMock();
    standsFind = jest.fn().mockResolvedValue([]);

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        StatsService,
        {
          provide: getRepositoryToken(Visit),
          useValue: { createQueryBuilder: jest.fn(() => visitQb) },
        },
        {
          provide: getRepositoryToken(Stand),
          useValue: { find: standsFind, count: jest.fn().mockResolvedValue(0) },
        },
        {
          provide: getRepositoryToken(ContactEvent),
          useValue: { createQueryBuilder: jest.fn(() => contactQb) },
        },
        {
          provide: getRepositoryToken(AccuracySample),
          useValue: { createQueryBuilder: jest.fn(() => accuracyQb) },
        },
      ],
    }).compile();
    service = module.get(StatsService);
  });

  describe('getHeatmapData', () => {
    it('yerleştirilmemiş stand (sentinel -1,-1) heatmap noktası ÜRETMEZ', async () => {
      // İlk getRawMany çağrısı trilaterasyon (boş), ikincisi fingerprint agg.
      visitQb.getRawMany
        .mockResolvedValueOnce([]) // trilat
        .mockResolvedValueOnce([
          { locationName: 'Sergi-A', count: 5 },
          { locationName: 'Sponsor', count: 9 }, // yerleştirilmemiş
        ]);
      standsFind.mockResolvedValue([
        { name: 'Sergi-A', x: 2.5, y: 2 },
        { name: 'Sponsor', x: -1, y: -1 }, // sentinel
      ]);

      const out = await service.getHeatmapData();
      expect(out.fingerprint).toHaveLength(1);
      expect(out.fingerprint[0]).toMatchObject({ x: 2.5, y: 2, count: 5 });
      // Hayalet leke yok: -1 koordinatlı nokta listede olmamalı.
      expect(out.fingerprint.some((p) => p.x < 0 || p.y < 0)).toBe(false);
    });

    it('trilaterasyon noktaları 0.5m grid\'e toplanır (count birikir)', async () => {
      visitQb.getRawMany
        .mockResolvedValueOnce([
          { x: 1.1, y: 1.2, locationName: 'a' },
          { x: 1.3, y: 1.4, locationName: 'a' }, // aynı 0.5m hücre (1.0,1.0)
          { x: 2.6, y: 2.6, locationName: 'b' }, // farklı hücre (2.5,2.5)
        ])
        .mockResolvedValueOnce([]);
      const out = await service.getHeatmapData();
      expect(out.trilateration).toHaveLength(2);
      const cell = out.trilateration.find((p) => p.x === 1 && p.y === 1);
      expect(cell?.count).toBe(2);
    });
  });

  describe('getAccuracyStats', () => {
    it('boş veri → null metrikler, sıfıra bölme yok', async () => {
      accuracyQb.getMany.mockResolvedValue([]);
      const out = await service.getAccuracyStats();
      expect(out.totalSamples).toBe(0);
      expect(out.fingerprintAccuracy).toBeNull();
      expect(out.meanErrorMeters).toBeNull();
      expect(out.medianErrorMeters).toBeNull();
    });

    it('medyan: çift sayıda örnekte iki ortancanın ortalaması', async () => {
      accuracyQb.getMany.mockResolvedValue([
        { positionSource: 'trilateration', correct: true, errorMeters: 1.0, groundTruth: 'a' },
        { positionSource: 'trilateration', correct: true, errorMeters: 2.0, groundTruth: 'a' },
        { positionSource: 'trilateration', correct: false, errorMeters: 3.0, groundTruth: 'a' },
        { positionSource: 'trilateration', correct: true, errorMeters: 10.0, groundTruth: 'a' },
      ]);
      const out = await service.getAccuracyStats();
      expect(out.medianErrorMeters).toBe(2.5); // (2+3)/2
      expect(out.meanErrorMeters).toBe(4); // 16/4
    });

    it('fingerprint isabeti yalnız fingerprint örneklerinden hesaplanır', async () => {
      accuracyQb.getMany.mockResolvedValue([
        { positionSource: 'fingerprint', correct: true, errorMeters: null, groundTruth: 'a' },
        { positionSource: 'fingerprint', correct: false, errorMeters: null, groundTruth: 'a' },
        // Trilaterasyon örnekleri isabet yüzdesine karışmamalı.
        { positionSource: 'trilateration', correct: false, errorMeters: 1, groundTruth: 'a' },
      ]);
      const out = await service.getAccuracyStats();
      expect(out.fingerprintSamples).toBe(2);
      expect(out.fingerprintAccuracy).toBe(50);
    });
  });

  describe('getDwellDistribution', () => {
    it('kova sınırları yarı-açık [min, max): tam 30s → "30-60s" kovası', async () => {
      visitQb.getRawMany.mockResolvedValue([
        { d: 0 },
        { d: 29 },
        { d: 30 }, // sınır → 30-60s
        { d: 60 }, // sınır → 1-2dk
        { d: 300 }, // sınır → 5+dk
        { d: 9999 },
      ]);
      const out = await service.getDwellDistribution();
      const byLabel = Object.fromEntries(out.buckets.map((b) => [b.label, b.count]));
      expect(byLabel['0-30s']).toBe(2);
      expect(byLabel['30-60s']).toBe(1);
      expect(byLabel['1-2 dk']).toBe(1);
      expect(byLabel['5+ dk']).toBe(2);
      expect(out.total).toBe(6);
    });
  });

  describe('getContactStats', () => {
    it('self-contact (a===b) çift/kişi istatistiklerine girmez ama toplam sayılır', async () => {
      const dev = 'aaaa1111' + '0'.repeat(56); // anonId: aaaa:1111
      contactQb.getMany.mockResolvedValue([
        {
          deviceId: dev,
          seenAnonId: 'aaaa:1111', // kendi yansıması (collision/echo)
          durationSeconds: 100,
          avgRssi: -60,
          locationName: null,
        },
        {
          deviceId: dev,
          seenAnonId: 'bbbb:2222',
          durationSeconds: 50,
          avgRssi: -65,
          locationName: 'masa',
        },
      ]);
      const out = await service.getContactStats();
      expect(out.totalContacts).toBe(2); // ham kayıt sayısı
      expect(out.pairs).toHaveLength(1); // self çifti yok
      expect(out.uniqueDevicesInvolved).toBe(2); // aaaa:1111 + bbbb:2222
      expect(out.standBreakdown).toEqual([
        { locationName: 'masa', count: 1, totalDuration: 50 },
      ]);
    });
  });
});
