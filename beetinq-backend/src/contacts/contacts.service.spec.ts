import { Test, TestingModule } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import { BadRequestException } from '@nestjs/common';

import { ContactsService } from './contacts.service';
import { ContactEvent } from './contact-event.entity';
import { EventsGateway } from '../events/events.gateway';
import { WipeStateService } from '../common/wipe-state.service';

/**
 * ContactsService.create — clientEventId idempotency + temporal merge + RSSI/
 * tarih validasyonu. Bu oturumda eklenen "tek sürekli temas" mantığının
 * regression kilidi. Repository mock'lanır; merge/upsert dallarının doğru
 * findOne/save çağırdığı doğrulanır.
 */
describe('ContactsService.create', () => {
  let service: ContactsService;
  let repo: {
    findOne: jest.Mock;
    save: jest.Mock;
    create: jest.Mock;
  };

  // now-merkezli yardımcı: saniye ofsetiyle ISO üretir.
  const iso = (secFromNow: number) =>
    new Date(Date.now() + secFromNow * 1000).toISOString();

  const baseDto = (over: Record<string, unknown> = {}) => ({
    deviceId: 'a'.repeat(64),
    seenAnonId: 'bbbb:cccc',
    firstSeenAt: iso(-120),
    lastSeenAt: iso(-100),
    durationSeconds: 20,
    avgRssi: -55,
    sampleCount: 10,
    ...over,
  });

  beforeEach(async () => {
    repo = {
      findOne: jest.fn().mockResolvedValue(null),
      save: jest.fn().mockImplementation((e) => Promise.resolve({ id: 1, ...e })),
      create: jest.fn().mockImplementation((e) => e),
    };
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        ContactsService,
        { provide: getRepositoryToken(ContactEvent), useValue: repo },
        { provide: EventsGateway, useValue: { emitDataChanged: jest.fn() } },
        { provide: WipeStateService, useValue: { isWiping: false } },
      ],
    }).compile();
    service = module.get(ContactsService);
  });

  it('yeni temas: kayıt yoksa create + save çağrılır', async () => {
    const r = await service.create(baseDto() as never);
    expect(repo.create).toHaveBeenCalledTimes(1);
    expect(repo.save).toHaveBeenCalledTimes(1);
    expect(r.success).toBe(true);
  });

  it('clientEventId upsert: aynı eventId varsa mevcut güncellenir, yeni create YOK', async () => {
    const existing = {
      id: 7,
      firstSeenAt: new Date(iso(-200)),
      lastSeenAt: new Date(iso(-180)),
      locationName: null,
      sampleCount: 5,
    };
    // İlk findOne (clientEventId) → existing döner.
    repo.findOne.mockResolvedValueOnce(existing);
    const r = await service.create(
      baseDto({ clientEventId: '11111111-1111-4111-8111-111111111111' }) as never,
    );
    expect(r).toMatchObject({ duplicate: true, updated: true, id: 7 });
    expect(repo.create).not.toHaveBeenCalled();
    expect(repo.save).toHaveBeenCalledWith(
      expect.objectContaining({ id: 7 }),
    );
  });

  it('temporal merge: aynı çift, zaman-yakın (gap<60s) → birleşir, yeni create YOK', async () => {
    const recent = {
      id: 3,
      firstSeenAt: new Date(iso(-200)),
      lastSeenAt: new Date(iso(-130)), // yeni firstSeen(-120) ile gap = 10s
      locationName: 'masa',
      sampleCount: 8,
      avgRssi: -60,
    };
    // 1. findOne (clientEventId) → null; 2. findOne (deviceId+seenAnonId) → recent
    repo.findOne.mockResolvedValueOnce(null).mockResolvedValueOnce(recent);
    const r = await service.create(baseDto({ firstSeenAt: iso(-120), lastSeenAt: iso(-100) }) as never);
    expect(r).toMatchObject({ merged: true, id: 3 });
    expect(repo.create).not.toHaveBeenCalled();
    // recent bitişi ileri taşındı, süre güncellendi.
    expect(repo.save).toHaveBeenCalledWith(expect.objectContaining({ id: 3 }));
    const saved = repo.save.mock.calls[0][0];
    expect(saved.durationSeconds).toBeGreaterThan(20); // -200 → -100 ≈ 100s
  });

  it('temporal merge: stand farklı olsa bile zaman-yakınsa birleşir (tek sürekli temas)', async () => {
    const recent = {
      id: 4,
      firstSeenAt: new Date(iso(-200)),
      lastSeenAt: new Date(iso(-130)),
      locationName: 'televizyon', // farklı stand
      sampleCount: 8,
      avgRssi: -60,
    };
    repo.findOne.mockResolvedValueOnce(null).mockResolvedValueOnce(recent);
    const r = await service.create(
      baseDto({ firstSeenAt: iso(-120), lastSeenAt: iso(-100), locationName: 'masa' }) as never,
    );
    // Farklı stand → yine merge (per-stand bölme kaldırıldı).
    expect(r).toMatchObject({ merged: true });
    expect(repo.create).not.toHaveBeenCalled();
  });

  it('temporal merge: pencere dışı (gap>60s) → YENİ temas açılır', async () => {
    const recent = {
      id: 5,
      firstSeenAt: new Date(iso(-400)),
      lastSeenAt: new Date(iso(-300)), // yeni firstSeen(-120) ile gap = 180s > 60
      locationName: 'masa',
      sampleCount: 8,
      avgRssi: -60,
    };
    repo.findOne.mockResolvedValueOnce(null).mockResolvedValueOnce(recent);
    await service.create(baseDto({ firstSeenAt: iso(-120), lastSeenAt: iso(-100) }) as never);
    expect(repo.create).toHaveBeenCalledTimes(1); // yeni kayıt
  });

  it('merge sampleCount tavanı (100000) aşmaz', async () => {
    const recent = {
      id: 6,
      firstSeenAt: new Date(iso(-200)),
      lastSeenAt: new Date(iso(-130)),
      locationName: null,
      sampleCount: 99999,
      avgRssi: -60,
    };
    repo.findOne.mockResolvedValueOnce(null).mockResolvedValueOnce(recent);
    await service.create(
      baseDto({ firstSeenAt: iso(-120), lastSeenAt: iso(-100), sampleCount: 50 }) as never,
    );
    const saved = repo.save.mock.calls[0][0];
    expect(saved.sampleCount).toBeLessThanOrEqual(100000);
  });

  it('gelecek tarihli temas reddedilir (400)', async () => {
    await expect(
      service.create(baseDto({ firstSeenAt: iso(600), lastSeenAt: iso(620) }) as never),
    ).rejects.toBeInstanceOf(BadRequestException);
  });

  it('lastSeenAt < firstSeenAt reddedilir (400)', async () => {
    await expect(
      service.create(baseDto({ firstSeenAt: iso(-50), lastSeenAt: iso(-100) }) as never),
    ).rejects.toBeInstanceOf(BadRequestException);
  });
});
