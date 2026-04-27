import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { BeaconsController } from './beacons.controller';
import { BeaconsService } from './beacons.service';
import { Beacon } from './beacon.entity';
import { Stand } from '../stands/stand.entity';

@Module({
  imports: [TypeOrmModule.forFeature([Beacon, Stand])],
  controllers: [BeaconsController],
  providers: [BeaconsService],
})
export class BeaconsModule {}
