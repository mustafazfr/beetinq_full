import {
  Injectable,
  BadRequestException,
  ServiceUnavailableException,
  Logger,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { QueryFailedError, Repository, IsNull } from 'typeorm';
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

  // BUG FIX (K1): Temporal merge findOne→save arası atomik DEĞİL; iki eşzamanlı
  // POST `await` noktalarında interleave olup aynı kaydı okuyup üstüne yazabilir
  // (lost update / bölünmüş temas). better-sqlite3 senkron olduğu için create'i
  // promise-zinciriyle serileştirmek bedava ve yarışı tamamen kapatır.
  private _writeChain: Promise<unknown> = Promise.resolve();

  create(dto: CreateContactEventDto) {
    const next = this._writeChain.then(() => this._createImpl(dto));
    // Zincir bir hatada kırılmasın; bir sonraki create yine sıraya girsin.
    this._writeChain = next.then(
      () => undefined,
      () => undefined,
    );
    return next;
  }

  private async _createImpl(dto: CreateContactEventDto) {
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

    // ── TEMPORAL MERGE (session stitching) ──────────────────────────────────
    // Mobil tarafta BLE flicker / encounter eviction yüzünden aynı temas birden
    // çok parçaya bölünebiliyor (her ~20sn'de yeni clientEventId → yeni kayıt).
    // Sunucu bunları birleştirir: aynı (raporlayan, görülen) çifti için son kayıt,
    // yeni kaydın başlangıcından en fazla MERGE penceresi kadar önce bittiyse VE
    // aynı stand'daysa → ayrı kayıt açma, mevcut kaydı UZAT. Böylece dashboard'da
    // "20sn'lik parçalar" yerine tek sürekli temas görünür. Farklı stand veya
    // pencere dışı → gerçekten yeni temas (per-stand contact korunur).
    const mergeWindowMs = 60 * 1000;
    const recent = await this.contactsRepository.findOne({
      where: {
        deviceId: dto.deviceId,
        seenAnonId: dto.seenAnonId,
        locationName: dto.locationName ?? IsNull(),
      },
      order: { lastSeenAt: 'DESC' },
    });
    if (recent) {
      const gapMs = firstSeenAt.getTime() - recent.lastSeenAt.getTime();
      // gap negatif (örtüşme) veya pencere içinde → aynı temasın devamı.
      if (gapMs <= mergeWindowMs) {
        // Bitişi ileri taşı (yeni daha geçse). Süre = bitiş - ilk görülme.
        if (lastSeenAt > recent.lastSeenAt) recent.lastSeenAt = lastSeenAt;
        recent.durationSeconds = Math.round(
          (recent.lastSeenAt.getTime() - recent.firstSeenAt.getTime()) / 1000,
        );
        recent.avgRssi = dto.avgRssi;
        // BUG FIX (O2): merge'de sampleCount sınırsız birikmesin (kötü niyetli
        // istemci pencere içinde 100000'lik parçalarla şişirebilir). DTO tek-POST
        // sınırıyla (100000) aynı tavanda kelepçele.
        recent.sampleCount = Math.min(recent.sampleCount + dto.sampleCount, 100000);
        await this.contactsRepository.save(recent);
        this.logger.debug(
          `Contact birleştirildi (temporal merge) id=${recent.id}, ` +
            `gap=${Math.round(gapMs / 1000)}s, yeni süre=${recent.durationSeconds}s`,
        );
        this.events.emitDataChanged('contact');
        return { success: true, id: recent.id, merged: true };
      }
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
