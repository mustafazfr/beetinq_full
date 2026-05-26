import { Injectable, Logger, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';

import { Fingerprint } from './fingerprint.entity';
import { CreateFingerprintDto } from './dto/create-fingerprint.dto';

@Injectable()
export class FingerprintsService {
  private readonly logger = new Logger(FingerprintsService.name);

  constructor(
    @InjectRepository(Fingerprint)
    private repo: Repository<Fingerprint>,
  ) {}

  /**
   * Upsert: aynı id ile gelen kayıt güncellenir (mobil aynı fingerprint'i
   * tekrar push edebilir), yoksa yeni eklenir. Duplicate satır oluşmaz.
   */
  async create(dto: CreateFingerprintDto) {
    const existing = await this.repo.findOne({ where: { id: dto.id } });
    if (existing) {
      existing.name = dto.name;
      existing.rssiMap = dto.rssiMap;
      if (dto.eventId) existing.eventId = dto.eventId;
      await this.repo.save(existing);
      this.logger.debug(`Fingerprint güncellendi id=${dto.id} name="${dto.name}"`);
      return { success: true, id: existing.id, updated: true };
    }
    const fp = this.repo.create({
      id: dto.id,
      name: dto.name,
      rssiMap: dto.rssiMap,
      eventId: dto.eventId ?? 'default',
    });
    await this.repo.save(fp);
    this.logger.log(
      `Fingerprint saved id=${fp.id} name="${fp.name}" ` +
        `(${Object.keys(dto.rssiMap).length} beacon)`,
    );
    return { success: true, id: fp.id };
  }

  /** Mobilin indirip kendi engine'ine yükleyeceği tüm fingerprint'ler. */
  findAll(eventId = 'default') {
    return this.repo.find({ where: { eventId }, order: { name: 'ASC' } });
  }

  async remove(id: string) {
    // BUG FIX (Backend R8): 0 satır etkilenirse 404 at (Stand/Beacon ile
    // tutarlı). Eskiden var olmayan id'de bile {success:true} dönüyordu →
    // panel "silindi" der ama gerçekte silmez (silent no-op).
    const res = await this.repo.delete(id);
    if (!res.affected) {
      throw new NotFoundException(`id=${id} fingerprint bulunamadı`);
    }
    return { success: true };
  }
}
