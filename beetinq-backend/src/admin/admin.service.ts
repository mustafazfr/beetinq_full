import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';

import { Visit } from '../visits/visit.entity';
import { Stand } from '../stands/stand.entity';
import { Beacon } from '../beacons/beacon.entity';
import { ContactEvent } from '../contacts/contact-event.entity';

/**
 * Test/demo arası "tüm veriyi sıfırla" — visit + contact + stand + beacon
 * tablolarını boşaltır. Auth yok; bitirme scope'unda local network varsayımı.
 *
 * NOT: Production'da bu endpoint MUTLAKA admin auth gerektirir.
 */
@Injectable()
export class AdminService {
  private readonly logger = new Logger(AdminService.name);

  constructor(
    @InjectRepository(Visit) private visits: Repository<Visit>,
    @InjectRepository(Stand) private stands: Repository<Stand>,
    @InjectRepository(Beacon) private beacons: Repository<Beacon>,
    @InjectRepository(ContactEvent)
    private contacts: Repository<ContactEvent>,
  ) {}

  async wipeAll() {
    // clear() TRUNCATE benzeri — tüm satırları siler.
    // Sırada önemli: foreign key olan tablo önce (Beacon → Stand'a bağlı).
    const visitCount = await this.visits.count();
    const contactCount = await this.contacts.count();
    const beaconCount = await this.beacons.count();
    const standCount = await this.stands.count();

    await this.visits.clear();
    await this.contacts.clear();
    await this.beacons.clear();
    await this.stands.clear();

    this.logger.warn(
      `WIPE: visit=${visitCount}, contact=${contactCount}, ` +
        `beacon=${beaconCount}, stand=${standCount} kayıt silindi.`,
    );

    return {
      success: true,
      deleted: {
        visits: visitCount,
        contacts: contactCount,
        beacons: beaconCount,
        stands: standCount,
      },
    };
  }
}
