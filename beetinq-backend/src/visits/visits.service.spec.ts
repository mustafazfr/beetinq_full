import { Test, TestingModule } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import { BadRequestException, ServiceUnavailableException } from '@nestjs/common';

import { VisitsService } from './visits.service';
import { Visit } from './visit.entity';
import { EventsGateway } from '../events/events.gateway';
import { WipeStateService } from '../common/wipe-state.service';

/**
 * 2026-06-10 bug avı — VisitsService.create için ilk test kapsamı:
 * idempotency (clientEventId + server-side türetilmiş hash), zaman sanity
 * kontrolleri, wipe yarış koruması, unique-violation yarışı.
 */
describe('VisitsService.create', () => {
  let service: VisitsService;
  let repo: {
    findOne: jest.Mock;
    create: jest.Mock;
    save: jest.Mock;
  };
  let wipeState: { isWiping: boolean };
  let emitMock: jest.Mock;

  const baseDto = () => ({
    deviceId: 'a'.repeat(64),
    locationName: 'Sergi-A',
    enteredAt: new Date(Date.now() - 120_000).toISOString(),
    exitedAt: new Date(Date.now() - 60_000).toISOString(),
    durationSeconds: 60,
    clientEventId: '7e57ab1e-0000-4000-8000-000000000001',
  });

  beforeEach(async () => {
    repo = {
      findOne: jest.fn().mockResolvedValue(null),
      create: jest.fn().mockImplementation((v) => ({ ...v, id: 42 })),
      save: jest.fn().mockResolvedValue(undefined),
    };
    wipeState = { isWiping: false };
    emitMock = jest.fn();

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        VisitsService,
        { provide: getRepositoryToken(Visit), useValue: repo },
        { provide: EventsGateway, useValue: { emitDataChanged: emitMock } },
        { provide: WipeStateService, useValue: wipeState },
      ],
    }).compile();
    service = module.get(VisitsService);
  });

  it('normal kayıt: create + save + data-changed yayını', async () => {
    const out = await service.create(baseDto() as never);
    expect(out).toMatchObject({ success: true, id: 42 });
    expect(repo.save).toHaveBeenCalled();
    expect(emitMock).toHaveBeenCalledWith('visit');
  });

  it('idempotency: aynı clientEventId varsa duplicate döner, save ÇAĞRILMAZ', async () => {
    repo.findOne.mockResolvedValue({ id: 7 });
    const out = await service.create(baseDto() as never);
    expect(out).toMatchObject({ success: true, id: 7, duplicate: true });
    expect(repo.save).not.toHaveBeenCalled();
  });

  it('clientEventId YOKSA server deterministik eventId türetir (eski mobil uyumu)', async () => {
    const dto = { ...baseDto(), clientEventId: undefined };
    await service.create(dto as never);
    const created = repo.create.mock.calls[0][0];
    expect(created.clientEventId).toMatch(/^[0-9a-f]{32}$/); // sha256 ilk 32 hex
    // Aynı içerik tekrar gelirse AYNI id türetilmeli (duplicate yakalanır).
    repo.create.mockClear();
    repo.findOne.mockResolvedValue({ id: 9 });
    const out2 = await service.create(dto as never);
    expect(out2).toMatchObject({ duplicate: true, id: 9 });
  });

  it('exitedAt < enteredAt → 400', async () => {
    const dto = {
      ...baseDto(),
      enteredAt: new Date(Date.now() - 60_000).toISOString(),
      exitedAt: new Date(Date.now() - 120_000).toISOString(),
    };
    await expect(service.create(dto as never)).rejects.toBeInstanceOf(
      BadRequestException,
    );
  });

  it('gelecek tarihli ziyaret (cihaz saati bozuk) → 400', async () => {
    const dto = {
      ...baseDto(),
      enteredAt: new Date(Date.now() + 3_600_000).toISOString(),
      exitedAt: new Date(Date.now() + 3_660_000).toISOString(),
    };
    await expect(service.create(dto as never)).rejects.toBeInstanceOf(
      BadRequestException,
    );
  });

  it('durationSeconds zamanlardan HESAPLANIR (client değeri kaydedilmez)', async () => {
    const dto = { ...baseDto(), durationSeconds: 9999 }; // tutarsız client değeri
    await service.create(dto as never);
    const created = repo.create.mock.calls[0][0];
    expect(created.durationSeconds).toBe(60); // exitedAt - enteredAt
  });

  it('wipe sürerken kayıt → 503 (mobil retry eder, veri kaybolmaz)', async () => {
    wipeState.isWiping = true;
    await expect(service.create(baseDto() as never)).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );
  });

  it('unique-violation yarışı: paralel duplicate save patlarsa duplicate kabul edilir', async () => {
    const err = Object.create(
      // QueryFailedError instanceof kontrolünü geçmek için prototype zinciri.
      (jest.requireActual('typeorm') as typeof import('typeorm')).QueryFailedError
        .prototype,
    );
    err.message = 'SQLITE_CONSTRAINT: UNIQUE constraint failed';
    repo.save.mockRejectedValue(err);
    repo.findOne
      .mockResolvedValueOnce(null) // ilk idempotency kontrolü: yok
      .mockResolvedValueOnce({ id: 13 }); // yarış sonrası: rakip kayıt bulundu
    const out = await service.create(baseDto() as never);
    expect(out).toMatchObject({ success: true, id: 13, duplicate: true });
  });
});
