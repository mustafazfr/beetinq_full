import { Test, TestingModule } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';

import { StatsService } from './stats.service';
import { Visit } from '../visits/visit.entity';
import { Stand } from '../stands/stand.entity';
import { ContactEvent } from '../contacts/contact-event.entity';
import { AccuracySample } from '../accuracy/accuracy-sample.entity';

/**
 * StatsService.getContactEvents — HER KAYIT BİR OTURUM (2026-06-07 stand
 * segmentasyonu). Çift birleştirme KALDIRILDI: aynı çiftin birden çok temas
 * oturumu birden çok satır kalır, her satırın süresi kendi oturumunundur (span
 * değil). Yön bağımsızlığı yalnız "A ↔ B" gösterimi için (lo/hi sıralı).
 */
describe('StatsService.getContactEvents', () => {
  let service: StatsService;
  let contactsQb: { andWhere: jest.Mock; getMany: jest.Mock };

  // da9f:52a4 (cihaz A, tam hash) ile 57db:c31d (cihaz B) arası temas.
  const devA = 'da9f52a4' + '0'.repeat(56);
  const devB = '57dbc31d' + '0'.repeat(56);
  const d = (sec: number) => new Date(Date.now() + sec * 1000);

  const setRows = (rows: unknown[]) => {
    contactsQb.getMany.mockResolvedValue(rows);
  };

  beforeEach(async () => {
    contactsQb = {
      andWhere: jest.fn().mockReturnThis(),
      getMany: jest.fn().mockResolvedValue([]),
    };
    const contactsRepo = {
      createQueryBuilder: jest.fn().mockReturnValue(contactsQb),
    };
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        StatsService,
        { provide: getRepositoryToken(Visit), useValue: {} },
        { provide: getRepositoryToken(Stand), useValue: {} },
        { provide: getRepositoryToken(ContactEvent), useValue: contactsRepo },
        { provide: getRepositoryToken(AccuracySample), useValue: {} },
      ],
    }).compile();
    service = module.get(StatsService);
  });

  it('her kayıt ayrı oturum satırı; süre kendi süresidir (span DEĞİL), yön bağımsız "A ↔ B"', async () => {
    setRows([
      // A'nın gözünden bir oturum
      {
        deviceId: devA,
        seenAnonId: '57db:c31d',
        firstSeenAt: d(-300),
        lastSeenAt: d(-200),
        durationSeconds: 100,
        avgRssi: -67,
        locationName: 'masa',
      },
      // B'nin gözünden ayrı bir oturum (artık BİRLEŞMEZ → 2 satır)
      {
        deviceId: devB,
        seenAnonId: 'da9f:52a4',
        firstSeenAt: d(-280),
        lastSeenAt: d(-100),
        durationSeconds: 180,
        avgRssi: -43,
        locationName: 'masa',
      },
    ]);
    const out = await service.getContactEvents();
    expect(out).toHaveLength(2); // birleştirme yok → 2 oturum
    // İkisi de aynı yön-bağımsız çifti göstermeli (lo/hi sıralı).
    for (const e of out) {
      expect([e.reporterAnonId, e.seenAnonId]).toEqual(['57db:c31d', 'da9f:52a4']);
      expect(e.eventCount).toBe(1); // her satır tek oturum
    }
    // Süreler KENDİ oturum süreleri (span 200s DEĞİL): 100 ve 180.
    expect(out.map((e) => e.durationSeconds).sort((a, b) => a - b)).toEqual([100, 180]);
    // En yeni (lastSeenAt -100, dur 180) üstte.
    expect(out[0].durationSeconds).toBe(180);
    expect(out[0].avgRssi).toBe(-43);
  });

  it('farklı çiftler ayrı satır kalır', async () => {
    const devC = 'cccccccc' + '0'.repeat(56);
    setRows([
      {
        deviceId: devA,
        seenAnonId: '57db:c31d',
        firstSeenAt: d(-200),
        lastSeenAt: d(-100),
        durationSeconds: 100,
        avgRssi: -60,
        locationName: null,
      },
      {
        deviceId: devC,
        seenAnonId: 'dddd:dddd',
        firstSeenAt: d(-200),
        lastSeenAt: d(-100),
        durationSeconds: 100,
        avgRssi: -60,
        locationName: null,
      },
    ]);
    const out = await service.getContactEvents();
    expect(out).toHaveLength(2);
  });

  it('deviceId tam hash reporterAnonId formatına indirgenir (xxxx:yyyy)', async () => {
    setRows([
      {
        deviceId: devA,
        seenAnonId: 'ffff:ffff',
        firstSeenAt: d(-50),
        lastSeenAt: d(-10),
        durationSeconds: 40,
        avgRssi: -55,
        locationName: null,
      },
    ]);
    const out = await service.getContactEvents();
    // anonId'ler sıralı çift; devA → "da9f:52a4"
    const ids = [out[0].reporterAnonId, out[0].seenAnonId];
    expect(ids).toContain('da9f:52a4');
    expect(ids).toContain('ffff:ffff');
  });

  it('boş veri → boş liste', async () => {
    setRows([]);
    expect(await service.getContactEvents()).toEqual([]);
  });
});
