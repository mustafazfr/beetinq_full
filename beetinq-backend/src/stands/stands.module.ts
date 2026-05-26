import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { StandsController } from './stands.controller';
import { StandsService } from './stands.service';
import { Stand } from './stand.entity';
import { Visit } from '../visits/visit.entity';
import { ContactEvent } from '../contacts/contact-event.entity';

@Module({
  imports: [TypeOrmModule.forFeature([Stand, Visit, ContactEvent])],
  controllers: [StandsController],
  providers: [StandsService],
})
export class StandsModule {}