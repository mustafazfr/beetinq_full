import {
  Injectable,
  ConflictException,
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

  async create(dto: CreateStandDto) {
    const existing = await this.standsRepository.findOne({
      where: { name: dto.name },
    });
    if (existing) {
      throw new ConflictException(
        `"${dto.name}" adında stand zaten var`,
      );
    }
    const stand = this.standsRepository.create(dto);
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
