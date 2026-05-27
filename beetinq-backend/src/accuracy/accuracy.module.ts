import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { AccuracyController } from './accuracy.controller';
import { AccuracyService } from './accuracy.service';
import { AccuracySample } from './accuracy-sample.entity';
import { Stand } from '../stands/stand.entity';

@Module({
  imports: [TypeOrmModule.forFeature([AccuracySample, Stand])],
  controllers: [AccuracyController],
  providers: [AccuracyService],
})
export class AccuracyModule {}
