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

  /**
   * x/y verilmediyse mevcut beacon sayısına göre 1m aralıklı grid'e
   * yerleştirir: 5'lik satır, satırlar 1m aralıklı. (1,1), (2,1)...
   * (5,1), (1,2)... Kullanıcı admin panelden drag-drop ile düzeltir.
   */
  private async nextAutoPosition(eventId: string): Promise<{ x: number; y: number }> {
    const n = await this.beaconsRepository.count({ where: { eventId } });
    return { x: 1 + (n % 5), y: 1 + Math.floor(n / 5) };
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

    const eventId = dto.eventId ?? 'default';
    // x veya y verilmemişse auto-grid: kullanıcı zaten admin panelden düzeltebilir.
    const auto = (dto.x === undefined || dto.y === undefined)
      ? await this.nextAutoPosition(eventId)
      : null;

    const beacon = this.beaconsRepository.create({
      id,
      uuid: dto.uuid.toUpperCase(),
      major: dto.major,
      minor: dto.minor,
      x: dto.x ?? auto!.x,
      y: dto.y ?? auto!.y,
      name: dto.name ?? null,
      stand,
      eventId,
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

  async update(id: string, dto: { x?: number; y?: number }) {
    const beacon = await this.beaconsRepository.findOne({ where: { id } });
    if (!beacon) {
      throw new NotFoundException(`Beacon bulunamadı: ${id}`);
    }
    if (dto.x !== undefined) beacon.x = dto.x;
    if (dto.y !== undefined) beacon.y = dto.y;
    return this.beaconsRepository.save(beacon);
  }

  async remove(id: string) {
    const result = await this.beaconsRepository.delete(id);
    if (result.affected === 0) {
      throw new NotFoundException(`Beacon bulunamadı: ${id}`);
    }
    return { success: true };
  }
}
