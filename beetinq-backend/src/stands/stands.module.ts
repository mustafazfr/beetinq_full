import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { StandsController } from './stands.controller';
import { StandsService } from './stands.service';
import { Stand } from './stand.entity';

@Module({
  imports: [TypeOrmModule.forFeature([Stand])],
  controllers: [StandsController],
  providers: [StandsService],
})
export class StandsModule {}