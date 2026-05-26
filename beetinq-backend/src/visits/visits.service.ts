import {
  Injectable,
  BadRequestException,
  Logger,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { QueryFailedError, Repository } from 'typeorm';

import { CreateVisitDto } from './dto/create-visit.dto';
import { Visit } from './visit.entity';
import { EventsGateway } from '../events/events.gateway';

@Injectable()
export class VisitsService {
  private readonly logger = new Logger(VisitsService.name);

  constructor(
    @InjectRepository(Visit)
    private visitsRepository: Repository<Visit>,
    private readonly events: EventsGateway,
  ) {}

  async create(dto: CreateVisitDto) {
    const enteredAt = new Date(dto.enteredAt);
    const exitedAt = new Date(dto.exitedAt);

    // Sanity: zaman sıralaması doğru mu
    if (exitedAt < enteredAt) {
      throw new BadRequestException(
        'exitedAt enteredAt\'tan önce olamaz',
      );
    }

    // Sanity: durationSeconds ile zamanlar arası fark tutarlı mı
    // (mobil kendi hesaplıyor, 10 sn tolerans veriyoruz)
    const computed = Math.round(
      (exitedAt.getTime() - enteredAt.getTime()) / 1000,
    );
    if (Math.abs(computed - dto.durationSeconds) > 10) {
      this.logger.warn(
        `Duration uyumsuz: client=${dto.durationSeconds}s, ` +
          `zamanlardan=${computed}s. Zamanlar baz alınarak kaydediliyor.`,
      );
    }

    // Idempotency: clientEventId verildiyse duplicate kontrolü
    if (dto.clientEventId) {
      const existing = await this.visitsRepository.findOne({
        where: {
          deviceId: dto.deviceId,
          clientEventId: dto.clientEventId,
        },
      });
      if (existing) {
        this.logger.debug(
          `Duplicate visit eventId=${dto.clientEventId}, döndürülen id=${existing.id}`,
        );
        return { success: true, id: existing.id, duplicate: true };
      }
    }

    const visit = this.visitsRepository.create({
      deviceId: dto.deviceId,
      clientEventId: dto.clientEventId ?? null,
      locationName: dto.locationName,
      enteredAt,
      exitedAt,
      // Client'tan gelen değeri değil hesaplananı kaydet — single source of truth
      durationSeconds: computed,
      positionSource: dto.positionSource ?? null,
      x: dto.x ?? null,
      y: dto.y ?? null,
    });

    try {
      await this.visitsRepository.save(visit);
    } catch (e) {
      // SQLite unique constraint violation — race condition: aynı
      // clientEventId iki paralel istekle geldi, ikincisi burada patlar.
      if (e instanceof QueryFailedError) {
        const msg = (e as QueryFailedError).message.toLowerCase();
        if (msg.includes('unique') || msg.includes('constraint')) {
          this.logger.debug(
            `Unique violation race: eventId=${dto.clientEventId}, duplicate kabul ediliyor`,
          );
          const existing = await this.visitsRepository.findOne({
            where: {
              deviceId: dto.deviceId,
              clientEventId: dto.clientEventId ?? undefined,
            },
          });
          if (existing) {
            return { success: true, id: existing.id, duplicate: true };
          }
        }
      }
      throw e;
    }

    this.logger.log(
      `Visit saved id=${visit.id} device=${dto.deviceId.slice(0, 8)}… ` +
        `loc="${dto.locationName}" dur=${computed}s src=${dto.positionSource ?? '-'}`,
    );
    // Gerçek zamanlı panel: yeni ziyaret → "yenile" sinyali yayınla.
    this.events.emitDataChanged('visit');
    return { success: true, id: visit.id };
  }
}
