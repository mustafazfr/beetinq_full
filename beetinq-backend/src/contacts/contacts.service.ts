import { Injectable, BadRequestException, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { QueryFailedError, Repository } from 'typeorm';

import { CreateContactEventDto } from './dto/create-contact-event.dto';
import { ContactEvent } from './contact-event.entity';

@Injectable()
export class ContactsService {
  private readonly logger = new Logger(ContactsService.name);

  constructor(
    @InjectRepository(ContactEvent)
    private contactsRepository: Repository<ContactEvent>,
  ) {}

  async create(dto: CreateContactEventDto) {
    const firstSeenAt = new Date(dto.firstSeenAt);
    const lastSeenAt = new Date(dto.lastSeenAt);

    if (lastSeenAt < firstSeenAt) {
      throw new BadRequestException(
        'lastSeenAt firstSeenAt\'tan önce olamaz',
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

    if (dto.clientEventId) {
      const existing = await this.contactsRepository.findOne({
        where: {
          deviceId: dto.deviceId,
          clientEventId: dto.clientEventId,
        },
      });
      if (existing) {
        this.logger.debug(
          `Duplicate contact eventId=${dto.clientEventId}, döndürülen id=${existing.id}`,
        );
        return { success: true, id: existing.id, duplicate: true };
      }
    }

    const entity = this.contactsRepository.create({
      deviceId: dto.deviceId,
      clientEventId: dto.clientEventId ?? null,
      seenAnonId: dto.seenAnonId,
      firstSeenAt,
      lastSeenAt,
      durationSeconds: computed,
      avgRssi: dto.avgRssi,
      sampleCount: dto.sampleCount,
    });

    try {
      await this.contactsRepository.save(entity);
    } catch (e) {
      if (e instanceof QueryFailedError) {
        const msg = (e as QueryFailedError).message.toLowerCase();
        if (msg.includes('unique') || msg.includes('constraint')) {
          this.logger.debug(
            `Unique violation race: eventId=${dto.clientEventId}, duplicate kabul ediliyor`,
          );
          const existing = await this.contactsRepository.findOne({
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
      `Contact saved id=${entity.id} device=${dto.deviceId.slice(0, 8)}… ` +
        `peer=${dto.seenAnonId} dur=${computed}s avgRssi=${dto.avgRssi}`,
    );
    return { success: true, id: entity.id };
  }
}
