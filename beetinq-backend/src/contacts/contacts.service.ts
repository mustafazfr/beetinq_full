import {
  Injectable,
  BadRequestException,
  ServiceUnavailableException,
  Logger,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { QueryFailedError, Repository } from 'typeorm';
import * as crypto from 'crypto';

import { CreateContactEventDto } from './dto/create-contact-event.dto';
import { ContactEvent } from './contact-event.entity';
import { EventsGateway } from '../events/events.gateway';
import { WipeStateService } from '../common/wipe-state.service';

@Injectable()
export class ContactsService {
  private readonly logger = new Logger(ContactsService.name);

  constructor(
    @InjectRepository(ContactEvent)
    private contactsRepository: Repository<ContactEvent>,
    private readonly events: EventsGateway,
    private readonly wipeState: WipeStateService,
  ) {}

  async create(dto: CreateContactEventDto) {
    // Wipe yarış koruması (R4) — visit ile aynı.
    if (this.wipeState.isWiping) {
      throw new ServiceUnavailableException(
        'Sunucu sıfırlanıyor, lütfen birazdan tekrar deneyin',
      );
    }

    const firstSeenAt = new Date(dto.firstSeenAt);
    const lastSeenAt = new Date(dto.lastSeenAt);

    if (lastSeenAt < firstSeenAt) {
      throw new BadRequestException(
        'lastSeenAt firstSeenAt\'tan önce olamaz',
      );
    }

    // BUG FIX (Backend R6): Gelecek tarihli sahte temas reddi (visit ile aynı).
    const futureLimit = Date.now() + 5 * 60 * 1000;
    if (lastSeenAt.getTime() > futureLimit || firstSeenAt.getTime() > futureLimit) {
      throw new BadRequestException(
        'Gelecek tarihli temas kabul edilmiyor (cihaz saati hatalı olabilir)',
      );
    }

    // Sanity: durationSeconds zamanlarla tutarlı olmalı (10 sn tolerans)
    const computed = Math.round(
      (lastSeenAt.getTime() - firstSeenAt.getTime()) / 1000,
    );
    if (Math.abs(computed - dto.durationSeconds) > 10) {
      this.logger.warn(
        `Duration uyumsuz: client=${dto.durationSeconds}s, ` +
          `zamanlardan=${computed}s. Zamanlar baz alınarak kaydediliyor.`,
      );
    }

    // BUG FIX (Backend R11): clientEventId yoksa server-side deterministik
    // hash üret → eski mobil veya geri retry'larda aynı contact'ın N kez
    // duplicate olarak yazılmasını engeller. (deviceId + seenAnonId + first
    // ISO) hash'i; aynı encounter tekrar gelirse aynı id → unique index
    // yakalar veya upsert dalı tetiklenir.
    const effectiveEventId =
      dto.clientEventId ??
      crypto
        .createHash('sha256')
        .update(
          [
            dto.deviceId,
            dto.seenAnonId,
            firstSeenAt.toISOString(),
          ].join('|'),
        )
        .digest('hex')
        .slice(0, 32);

    const existing = await this.contactsRepository.findOne({
      where: {
        deviceId: dto.deviceId,
        clientEventId: effectiveEventId,
      },
    });
    if (existing) {
      // Upsert: uzun temaslarda mobil aynı clientEventId ile güncel (daha
      // uzun) süreyle tekrar gönderir. firstSeenAt sabit kalır; süre/son
      // görülme/rssi/örnek sayısı güncellenir. Böylece "ortalama temas
      // süresi" gerçek süreyi yansıtır, eski donmuş ~60sn değil.
      existing.lastSeenAt = lastSeenAt;
      existing.durationSeconds = computed;
      existing.avgRssi = dto.avgRssi;
      existing.sampleCount = dto.sampleCount;
      if (dto.locationName !== undefined) {
        existing.locationName = dto.locationName;
      }
      await this.contactsRepository.save(existing);
      this.logger.debug(
        `Contact güncellendi (re-report) eventId=${effectiveEventId}, ` +
          `id=${existing.id}, yeni süre=${computed}s`,
      );
      // Süre güncellendi → panel yenilensin.
      this.events.emitDataChanged('contact');
      return {
        success: true,
        id: existing.id,
        duplicate: true,
        updated: true,
      };
    }

    const entity = this.contactsRepository.create({
      deviceId: dto.deviceId,
      clientEventId: effectiveEventId,
      seenAnonId: dto.seenAnonId,
      firstSeenAt,
      lastSeenAt,
      durationSeconds: computed,
      avgRssi: dto.avgRssi,
      sampleCount: dto.sampleCount,
      locationName: dto.locationName ?? null,
    });

    try {
      await this.contactsRepository.save(entity);
    } catch (e) {
      if (e instanceof QueryFailedError) {
        const msg = (e as QueryFailedError).message.toLowerCase();
        if (msg.includes('unique') || msg.includes('constraint')) {
          this.logger.debug(
            `Unique violation race: eventId=${effectiveEventId}, duplicate kabul ediliyor`,
          );
          const raced = await this.contactsRepository.findOne({
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
      `Contact saved id=${entity.id} device=${dto.deviceId.slice(0, 8)}… ` +
        `peer=${dto.seenAnonId} dur=${computed}s avgRssi=${dto.avgRssi}`,
    );
    // Gerçek zamanlı panel: yeni temas → "yenile" sinyali yayınla.
    this.events.emitDataChanged('contact');
    return { success: true, id: entity.id };
  }
}
