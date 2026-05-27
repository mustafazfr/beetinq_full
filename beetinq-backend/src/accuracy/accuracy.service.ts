import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';

import { AccuracySample } from './accuracy-sample.entity';
import { Stand } from '../stands/stand.entity';
import { CreateAccuracyDto } from './dto/create-accuracy.dto';

@Injectable()
export class AccuracyService {
  private readonly logger = new Logger(AccuracyService.name);

  constructor(
    @InjectRepository(AccuracySample)
    private repo: Repository<AccuracySample>,
    @InjectRepository(Stand)
    private standsRepository: Repository<Stand>,
  ) {}

  async create(dto: CreateAccuracyDto) {
    const predicted = dto.predictedLocation ?? null;
    // Fingerprint isabeti: tahmin gerçek stand'a eşit mi?
    const correct = predicted !== null && predicted === dto.groundTruth;

    // Trilaterasyon hatası: tahmin (x,y) ile GERÇEK stand (x,y) mesafesi.
    // Ground truth stand'ın konumu serverda (admin yerleştirir). Konumsuz
    // (-1,-1 sentinel) veya tahmin x,y yoksa hata hesaplanamaz → null.
    let errorMeters: number | null = null;
    if (dto.predictedX != null && dto.predictedY != null) {
      const stand = await this.standsRepository.findOne({
        where: { name: dto.groundTruth },
      });
      if (stand && stand.x >= 0 && stand.y >= 0) {
        errorMeters = Math.hypot(
          dto.predictedX - stand.x,
          dto.predictedY - stand.y,
        );
      }
    }

    const entity = this.repo.create({
      deviceId: dto.deviceId,
      groundTruth: dto.groundTruth,
      predictedLocation: predicted,
      positionSource: dto.positionSource ?? null,
      correct,
      errorMeters,
    });
    await this.repo.save(entity);
    this.logger.log(
      `Accuracy: gerçek=${dto.groundTruth} tahmin=${predicted ?? '∅'} ` +
        `doğru=${correct} hata=${errorMeters?.toFixed(2) ?? '-'}m`,
    );
    return { success: true, id: entity.id, correct, errorMeters };
  }
}
