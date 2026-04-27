import {
  Injectable,
  ConflictException,
  NotFoundException,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';

import { Beacon } from './beacon.entity';
import { Stand } from '../stands/stand.entity';
import { CreateBeaconDto } from './dto/create-beacon.dto';

@Injectable()
export class BeaconsService {
  constructor(
    @InjectRepository(Beacon)
    private beaconsRepository: Repository<Beacon>,
    @InjectRepository(Stand)
    private standsRepository: Repository<Stand>,
  ) {}

  /** Mobil'in `BeaconRow.key` ile aynı formatta id üretir. */
  private buildId(uuid: string, major: number, minor: number): string {
    return `${uuid.toUpperCase()}-${major}-${minor}`;
  }

  async create(dto: CreateBeaconDto) {
    const id = this.buildId(dto.uuid, dto.major, dto.minor);
    const existing = await this.beaconsRepository.findOne({ where: { id } });
    if (existing) {
      throw new ConflictException(
        `Beacon zaten kayıtlı: ${id}`,
      );
    }

    let stand: Stand | null = null;
    if (dto.standId !== undefined) {
      stand = await this.standsRepository.findOne({
        where: { id: dto.standId },
      });
      if (!stand) {
        throw new NotFoundException(`Stand bulunamadı: id=${dto.standId}`);
      }
    }

    const beacon = this.beaconsRepository.create({
      id,
      uuid: dto.uuid.toUpperCase(),
      major: dto.major,
      minor: dto.minor,
      x: dto.x,
      y: dto.y,
      name: dto.name ?? null,
      stand,
      eventId: dto.eventId ?? 'default',
    });
    return this.beaconsRepository.save(beacon);
  }

  findAll(eventId?: string) {
    return this.beaconsRepository.find({
      where: eventId ? { eventId } : {},
      relations: ['stand'],
      order: { major: 'ASC', minor: 'ASC' },
    });
  }

  /**
   * Mobil'in `fetchBeaconLocations` metodu bu endpoint'i çağırır.
   * Format mobilin `BeaconLocation.fromJson` beklentisiyle birebir uyumlu:
   * { id, x, y, name? }
   */
  async getLocationsForMobile(eventId = 'default') {
    const beacons = await this.beaconsRepository.find({
      where: { eventId },
      relations: ['stand'],
    });
    return beacons.map((b) => ({
      id: b.id,
      x: b.x,
      y: b.y,
      // Tercih sırası: explicit name > stand name > null
      name: b.name ?? b.stand?.name ?? null,
    }));
  }

  async remove(id: string) {
    const result = await this.beaconsRepository.delete(id);
    if (result.affected === 0) {
      throw new NotFoundException(`Beacon bulunamadı: ${id}`);
    }
    return { success: true };
  }
}
