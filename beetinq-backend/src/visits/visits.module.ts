import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { VisitsController } from './visits.controller';
import { VisitsService } from './visits.service';
import { Visit } from './visit.entity';

@Module({
  imports: [TypeOrmModule.forFeature([Visit])],
  controllers: [VisitsController],
  providers: [VisitsService],
})
export class VisitsModule {}