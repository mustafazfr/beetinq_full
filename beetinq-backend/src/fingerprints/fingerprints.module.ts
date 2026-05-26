import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';

import { FingerprintsController } from './fingerprints.controller';
import { FingerprintsService } from './fingerprints.service';
import { Fingerprint } from './fingerprint.entity';

@Module({
  imports: [TypeOrmModule.forFeature([Fingerprint])],
  controllers: [FingerprintsController],
  providers: [FingerprintsService],
})
export class FingerprintsModule {}
