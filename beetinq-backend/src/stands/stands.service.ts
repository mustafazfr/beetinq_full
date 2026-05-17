import {
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';

import { Stand } from './stand.entity';
import { CreateStandDto } from './dto/create-stand.dto';
import { UpdateStandDto } from './dto/update-stand.dto';

@Injectable()
export class StandsService {
  constructor(
    @InjectRepository(Stand)
    private standsRepository: Repository<Stand>,
  ) {}

  /**
   * x/y verilmediyse mevcut stand sayısına göre 1m aralıklı grid'e
   * oturt: 5'lik satır. (1,1), (2,1)... (5,1), (1,2)... Beacon ile
   * aynı mantık (BeaconsService.nextAutoPosition).
   */
  private async nextAutoPosition(): Promise<{ x: number; y: number }> {
    const n = await this.standsRepository.count();
    return { x: 1 + (n % 5), y: 1 + Math.floor(n / 5) };
  }

  /**
   * Idempotent create: aynı isimde stand varsa yenisini eklemeden
   * mevcut'u döndürür. Mobilden fingerprint kaydı her seferinde aynı
   * locationName ile gelebilir; her birinde 409 atmak yerine sessizce
   * geçeriz. Davranış 200/201 ayrımı yok — controller her ikisinde de
   * objeyi döner.
   */
  async create(dto: CreateStandDto) {
    const existing = await this.standsRepository.findOne({
      where: { name: dto.name },
    });
    if (existing) return existing;

    const auto = (dto.x === undefined || dto.y === undefined)
      ? await this.nextAutoPosition()
      : null;
    const stand = this.standsRepository.create({
      name: dto.name,
      x: dto.x ?? auto!.x,
      y: dto.y ?? auto!.y,
    });
    return this.standsRepository.save(stand);
  }

  findAll() {
    return this.standsRepository.find({ order: { name: 'ASC' } });
  }

  async findOne(id: number) {
    const stand = await this.standsRepository.findOne({ where: { id } });
    if (!stand) {
      throw new NotFoundException(`id=${id} stand bulunamadı`);
    }
    return stand;
  }

  async updatePosition(id: number, dto: UpdateStandDto) {
    // Önce var mı kontrol et — update() 0 satır etkilerse sessizce geçer
    await this.findOne(id);
    await this.standsRepository.update(id, dto);
    return this.findOne(id);
  }

  async remove(id: number) {
    // Var mı kontrolü — bulunamazsa 404
    await this.findOne(id);
    await this.standsRepository.delete(id);
    // NOT: Visit tablosunda FK yok, bu yüzden ziyaret kayıtları silinmez.
    // Stand silinse bile istatistik için locationName referansları kalır.
    return { success: true };
  }
}
