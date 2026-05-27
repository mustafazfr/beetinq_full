import { Body, Controller, Post } from '@nestjs/common';
import { AccuracyService } from './accuracy.service';
import { CreateAccuracyDto } from './dto/create-accuracy.dto';

@Controller('accuracy')
export class AccuracyController {
  constructor(private readonly service: AccuracyService) {}

  /** Mobil "Doğruluk Testi": ground truth + sistem tahmini gönderir. */
  @Post()
  create(@Body() dto: CreateAccuracyDto) {
    return this.service.create(dto);
  }
}
