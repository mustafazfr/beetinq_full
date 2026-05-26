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
   * Konumu verilmeyen stand "yerleştirilmemiş" sayılır: sentinel (-1, -1).
   *
   * Eskiden rastgele 1m grid konumu (nextAutoPosition) atanıyordu; kullanıcı
   * geri bildirimi: backend uydurma konum ATAMAMALI. Stand = fingerprint ile
   * isimlendirilen bölge; konumunu admin panelden drag-drop ile operatör verir.
   * x<0 || y<0 → "yerleştirilmemiş" işareti; panel bunları ayrı gösterip
   * haritaya sürükletir, yerleştirilince PATCH ile gerçek (x,y) yazılır.
   * DB şeması değişmedi (x/y hâlâ not-null), yalnızca değer sözleşmesi.
   * NOT: Beacon tarafı kendi auto-grid'ini korur (beacon'lar haritada görünür).
   */
  static readonly UNPLACED = -1;

  /**
   * Idempotent create: aynı isimde stand varsa yenisini eklemeden
   * mevcut'u döndürür. Mobilden fingerprint kaydı her seferinde aynı
   * locationName ile gelebilir; her birinde 409 atmak yerine sessizce
   * geçeriz. Davranış 200/201 ayrımı yok — controller her ikisinde de
   * objeyi döner.
   *
   * x/y verilmezse stand "yerleştirilmemiş" (UNPLACED) oluşturulur; mobil
   * o an bir tahmini konum (trilaterasyon) gönderirse o kullanılır.
   */
  async create(dto: CreateStandDto) {
    const existing = await this.standsRepository.findOne({
      where: { name: dto.name },
    });
    if (existing) return existing;

    const stand = this.standsRepository.create({
      name: dto.name,
      x: dto.x ?? StandsService.UNPLACED,
      y: dto.y ?? StandsService.UNPLACED,
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
