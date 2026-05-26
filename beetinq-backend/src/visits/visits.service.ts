import {
  Injectable,
  BadRequestException,
  Logger,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { QueryFailedError, Repository } from 'typeorm';
import * as crypto from 'crypto';

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

    // BUG FIX (Backend R6): Gelecek tarihli sahte veri reddi. Cihaz saati
    // ileri ayarlıysa enteredAt="2099-..." gelir; retention cron'u (now-14gün)
    // bunu asla silemez → kalıcı çöp + "active now" sayacı sürekli şişer.
    // 5 dk client clock skew toleransı.
    const futureLimit = Date.now() + 5 * 60 * 1000;
    if (exitedAt.getTime() > futureLimit || enteredAt.getTime() > futureLimit) {
      throw new BadRequestException(
        'Gelecek tarihli ziyaret kabul edilmiyor (cihaz saati hatalı olabilir)',
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

    // BUG FIX (Backend R11): Eski mobil sürümleri clientEventId göndermiyordu;
    // idempotency guard `if (dto.clientEventId)` ile atlanıyor → offline retry
    // sırasında aynı visit N kez kayda geçiyor ("aynı yerde sürekli veri"
    // şikâyetinin server tarafı). clientEventId yoksa server-side deterministik
    // hash üret (deviceId + locationName + enter/exit ISO) → aynı içerik tekrar
    // gelirse aynı eventId → unique index duplicate yakalar. DTO'daki @IsUUID
    // validasyonu bypass edilmez (sadece istemci yollamadığında server türetir).
    const effectiveEventId =
      dto.clientEventId ??
      crypto
        .createHash('sha256')
        .update(
          [
            dto.deviceId,
            dto.locationName,
            enteredAt.toISOString(),
            exitedAt.toISOString(),
          ].join('|'),
        )
        .digest('hex')
        .slice(0, 32);

    // Idempotency: effectiveEventId her zaman var → duplicate kontrolü her isteğe uygulanır
    const existing = await this.visitsRepository.findOne({
      where: {
        deviceId: dto.deviceId,
        clientEventId: effectiveEventId,
      },
    });
    if (existing) {
      this.logger.debug(
        `Duplicate visit eventId=${effectiveEventId}, döndürülen id=${existing.id}`,
      );
      return { success: true, id: existing.id, duplicate: true };
    }

    const visit = this.visitsRepository.create({
      deviceId: dto.deviceId,
      clientEventId: effectiveEventId,
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
            `Unique violation race: eventId=${effectiveEventId}, duplicate kabul ediliyor`,
          );
          const raced = await this.visitsRepository.findOne({
            where: {
              deviceId: dto.deviceId,
              clientEventId: effectiveEventId,
            },
          });
          if (raced) {
            return { success: true, id: raced.id, duplicate: true };
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
