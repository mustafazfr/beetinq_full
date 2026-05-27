import { Test, TestingModule } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';

import { StatsService } from './stats.service';
import { Visit } from '../visits/visit.entity';
import { Stand } from '../stands/stand.entity';
import { ContactEvent } from '../contacts/contact-event.entity';

/**
 * StatsService.getContactEvents — yön-bağımsız birleştirme. A→B ve B→A aynı
 * fiziksel temasın iki perspektifi; tek "A ↔ B" satırına birleşmeli. Bu
 * oturumda eklenen "tek sürekli temas" dashboard mantığının regression kilidi.
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
      ],
    }).compile();
    service = module.get(StatsService);
  });

  it('A→B ve B→A tek "A ↔ B" satırına birleşir', async () => {
    setRows([
      // A'nın gözünden: A(deviceId) gördü B(seenAnonId)
      {
        deviceId: devA,
        seenAnonId: '57db:c31d',
        firstSeenAt: d(-300),
        lastSeenAt: d(-200),
        durationSeconds: 100,
        avgRssi: -67,
        locationName: 'masa',
      },
      // B'nin gözünden: B(deviceId) gördü A(seenAnonId)
      {
        deviceId: devB,
        seenAnonId: 'da9f:52a4',
        firstSeenAt: d(-280),
        lastSeenAt: d(-100), // daha geç bitiş
        durationSeconds: 180,
        avgRssi: -43, // daha güçlü (yakın)
        locationName: 'masa',
      },
    ]);
    const out = await service.getContactEvents();
    expect(out).toHaveLength(1); // tek birleşik temas
    const e = out[0];
    // Çift sıralı (alfabetik): 57db:c31d < da9f:52a4
    expect([e.reporterAnonId, e.seenAnonId].sort()).toEqual([
      '57db:c31d',
      'da9f:52a4',
    ]);
    expect(e.eventCount).toBe(2);
    // Süre = en geç bitiş(-100) - en erken başlangıç(-300) ≈ 200s
    expect(e.durationSeconds).toBeGreaterThanOrEqual(195);
    // En yakın (en güçlü) RSSI = -43
    expect(e.avgRssi).toBe(-43);
    expect(e.locationName).toBe('masa');
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
