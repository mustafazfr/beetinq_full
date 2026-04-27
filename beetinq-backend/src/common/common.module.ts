import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { CleanupService } from './cleanup.service';
import { Visit } from '../visits/visit.entity';
import { ContactEvent } from '../contacts/contact-event.entity';

@Module({
  imports: [TypeOrmModule.forFeature([Visit, ContactEvent])],
  providers: [CleanupService],
  exports: [CleanupService],
})
export class CommonModule {}
