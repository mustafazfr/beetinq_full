import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { AdminController } from './admin.controller';
import { AdminService } from './admin.service';
import { Visit } from '../visits/visit.entity';
import { Stand } from '../stands/stand.entity';
import { Beacon } from '../beacons/beacon.entity';
import { ContactEvent } from '../contacts/contact-event.entity';

@Module({
  imports: [TypeOrmModule.forFeature([Visit, Stand, Beacon, ContactEvent])],
  controllers: [AdminController],
  providers: [AdminService],
})
export class AdminModule {}
