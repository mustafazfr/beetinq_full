import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';

import { Visit } from '../visits/visit.entity';
import { Stand } from '../stands/stand.entity';
import { Beacon } from '../beacons/beacon.entity';
import { ContactEvent } from '../contacts/contact-event.entity';
import { Fingerprint } from '../fingerprints/fingerprint.entity';

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
    @InjectRepository(Fingerprint)
    private fingerprints: Repository<Fingerprint>,
  ) {}

  /**
   * Uzaktan cihaz sıfırlama epoch'u (in-memory, ms timestamp). Panelden
   * "telefonları da sıfırla" seçilince Date.now() ile ilerletilir. Telefonlar
   * GET /admin/device-reset-epoch ile sorgular; kendi sakladıkları son
   * epoch'tan büyükse yerel verilerini (fingerprint, oturum, kuyruk) sıfırlar.
   *
   * Kalıcı saklamaya gerek yok: restart'ta 0'a döner, telefon kendi (daha
   * büyük) epoch'u ile karşılaştırınca wipe etmez. Date.now() monoton arttığı
   * için yeni wipe her zaman telefon epoch'unu aşar.
   */
  private deviceResetEpoch = 0;

  getDeviceResetEpoch(): number {
    return this.deviceResetEpoch;
  }

  async wipeAll(resetDevices = false) {
    // clear() TRUNCATE benzeri — tüm satırları siler.
    // Sırada önemli: foreign key olan tablo önce (Beacon → Stand'a bağlı).
    const visitCount = await this.visits.count();
    const contactCount = await this.contacts.count();
    const beaconCount = await this.beacons.count();
    const standCount = await this.stands.count();
    const fingerprintCount = await this.fingerprints.count();

    await this.visits.clear();
    await this.contacts.clear();
    await this.beacons.clear();
    await this.stands.clear();
    await this.fingerprints.clear();

    // Telefonlar da sıfırlanacaksa epoch'u ilerlet → bağlı cihazlar bir
    // sonraki sync'te bunu görüp kendi yerel verilerini silecek.
    if (resetDevices) {
      this.deviceResetEpoch = Date.now();
    }

    this.logger.warn(
      `WIPE: visit=${visitCount}, contact=${contactCount}, ` +
        `beacon=${beaconCount}, stand=${standCount}, fingerprint=${fingerprintCount} kayıt silindi.` +
        (resetDevices ? ` Cihaz sıfırlama epoch=${this.deviceResetEpoch}.` : ''),
    );

    return {
      success: true,
      resetDevices,
      deviceResetEpoch: this.deviceResetEpoch,
      deleted: {
        visits: visitCount,
        contacts: contactCount,
        beacons: beaconCount,
        stands: standCount,
        fingerprints: fingerprintCount,
      },
    };
  }
}
