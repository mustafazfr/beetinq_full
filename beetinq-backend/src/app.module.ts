import { Module } from '@nestjs/common';
import { TypeOrmModule } from '@nestjs/typeorm';
import { ServeStaticModule } from '@nestjs/serve-static';
import { ThrottlerModule, ThrottlerGuard } from '@nestjs/throttler';
import { ScheduleModule } from '@nestjs/schedule';
import { APP_GUARD } from '@nestjs/core';
import { join } from 'path';

import { VisitsModule } from './visits/visits.module';
import { StatsModule } from './stats/stats.module';
import { StandsModule } from './stands/stands.module';
import { BeaconsModule } from './beacons/beacons.module';
import { ContactsModule } from './contacts/contacts.module';
import { FingerprintsModule } from './fingerprints/fingerprints.module';
import { CommonModule } from './common/common.module';
import { AdminModule } from './admin/admin.module';

import { Visit } from './visits/visit.entity';
import { Stand } from './stands/stand.entity';
import { Beacon } from './beacons/beacon.entity';
import { ContactEvent } from './contacts/contact-event.entity';
import { Fingerprint } from './fingerprints/fingerprint.entity';

@Module({
  imports: [
    ServeStaticModule.forRoot({
      rootPath: join(__dirname, '..', 'public'),
    }),

    ScheduleModule.forRoot(),

    // Rate limit: 1 cihaz saniyede 10, dakikada 100 istek atabilir.
    // Offline flush sonrası queue patlaması için limit yüksek tutuldu.
    ThrottlerModule.forRoot([
      { name: 'short', ttl: 1000, limit: 10 },
      { name: 'long', ttl: 60000, limit: 100 },
    ]),

    TypeOrmModule.forRoot({
      type: 'better-sqlite3',
      database: process.env.DB_PATH ?? 'database.sqlite',
      entities: [Visit, Stand, Beacon, ContactEvent, Fingerprint],
      // ⚠️ PRODUCTION: synchronize false olmalı, migration kullanılmalı.
      // Development'ta true bırakmak sahada hızlı iterasyon için pratik.
      synchronize: process.env.NODE_ENV !== 'production',
    }),

    VisitsModule,
    StatsModule,
    StandsModule,
    BeaconsModule,
    ContactsModule,
    FingerprintsModule,
    CommonModule,
    AdminModule,
  ],
  providers: [
    {
      provide: APP_GUARD,
      useClass: ThrottlerGuard,
    },
  ],
})
export class AppModule {}
