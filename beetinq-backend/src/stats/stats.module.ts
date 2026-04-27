import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { StatsController } from './stats.controller';
import { StatsService } from './stats.service';
import { Visit } from '../visits/visit.entity';
import { Stand } from '../stands/stand.entity';
import { ContactEvent } from '../contacts/contact-event.entity';

@Module({
  // Heatmap fingerprint fallback'i için Stand entity'si de gerekli
  imports: [TypeOrmModule.forFeature([Visit, Stand, ContactEvent])],
  controllers: [StatsController],
  providers: [StatsService],
})
export class StatsModule {}
