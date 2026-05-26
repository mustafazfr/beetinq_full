import { Injectable, Logger } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import * as fs from 'fs';
import * as path from 'path';

import { Visit } from '../visits/visit.entity';
import { Stand } from '../stands/stand.entity';
import { Beacon } from '../beacons/beacon.entity';
import { ContactEvent } from '../contacts/contact-event.entity';
import { Fingerprint } from '../fingerprints/fingerprint.entity';
import { WipeStateService } from '../common/wipe-state.service';

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
    private readonly wipeState: WipeStateService,
  ) {
    this.deviceResetEpoch = this.loadEpoch();
  }

  /**
   * Uzaktan cihaz sıfırlama epoch'u (ms timestamp). Panelden "telefonları da
   * sıfırla" seçilince Date.now() ile ilerletilir. Telefonlar GET
   * /admin/device-reset-epoch ile sorgular; kendi sakladıkları son epoch'tan
   * büyükse yerel verilerini (fingerprint, oturum, kuyruk) sıfırlar.
   *
   * BUG FIX (Backend R9): Eskiden in-memory idi → backend restart'ta 0'a
   * dönüyordu. DB silinip yeniden kurulduğu (database.sqlite reset) bir
   * senaryoda telefonlar eski verilerini kullanmaya devam ediyordu. Artık
   * dosyaya (data/device-reset-epoch) kalıcı yazılıp restart'ta okunuyor.
   */
  private deviceResetEpoch = 0;

  private get epochFilePath(): string {
    // database.sqlite ile aynı dizinde tut (proje kökü).
    return path.join(process.cwd(), 'data', 'device-reset-epoch');
  }

  private loadEpoch(): number {
    try {
      const raw = fs.readFileSync(this.epochFilePath, 'utf8').trim();
      const v = parseInt(raw, 10);
      return Number.isFinite(v) && v > 0 ? v : 0;
    } catch {
      return 0; // dosya yok → ilk kurulum
    }
  }

  private saveEpoch(epoch: number): void {
    try {
      fs.mkdirSync(path.dirname(this.epochFilePath), { recursive: true });
      fs.writeFileSync(this.epochFilePath, String(epoch), 'utf8');
    } catch (e) {
      this.logger.warn(`Epoch dosyaya yazılamadı: ${e}`);
    }
  }

  getDeviceResetEpoch(): number {
    return this.deviceResetEpoch;
  }

  async wipeAll(resetDevices = false) {
    // Wipe yarış koruması (R4): clear'lar sürerken gelen POST'ları guard'lar
    // 503 ile reddetsin → wipe sonrası orphan kayıt kalmasın. Pencere TAM
    // olarak clear() kritik bölümünü kapsar (finally'de kapanır); response
    // döndükten sonra gelen POST'lar (seed/test) reddedilmez.
    this.wipeState.beginWipe();

    try {
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
      // sonraki sync'te bunu görüp kendi yerel verilerini silecek. Kalıcı yaz
      // (restart sonrası korunsun).
      if (resetDevices) {
        this.deviceResetEpoch = Date.now();
        this.saveEpoch(this.deviceResetEpoch);
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
    } finally {
      this.wipeState.endWipe();
    }
  }

  /**
   * Seçerek silme: yalnızca işaretli kategorileri siler. visits ve contacts
   * için opsiyonel tarih aralığı uygulanır (from/to, enteredAt / firstSeenAt).
   * stands/beacons/fingerprints zaten tarihsiz → seçilirse tablo komple silinir.
   *
   * Cihaz tarafı dokunulmaz (uzaktan reset epoch'u ilerletilmez). "Sıfırla"
   * butonları nükleer seçenek; bu seçici silme cerrahi.
   */
  async wipeSelective(dto: {
    visits?: boolean;
    contacts?: boolean;
    stands?: boolean;
    beacons?: boolean;
    fingerprints?: boolean;
    from?: string;
    to?: string;
  }) {
    // En az bir kategori seçilmiş mi?
    const anySelected = !!(
      dto.visits || dto.contacts || dto.stands || dto.beacons || dto.fingerprints
    );
    if (!anySelected) {
      return { success: false, error: 'Hiç kategori seçilmedi' };
    }

    this.wipeState.beginWipe();
    try {
      const deleted = { visits: 0, contacts: 0, stands: 0, beacons: 0, fingerprints: 0 };
      const fromDate = dto.from ? new Date(dto.from) : null;
      const toDate = dto.to ? new Date(dto.to) : null;

      if (dto.visits) {
        const qb = this.visits.createQueryBuilder().delete();
        if (fromDate) qb.andWhere('enteredAt >= :from', { from: fromDate });
        if (toDate) qb.andWhere('enteredAt <= :to', { to: toDate });
        const r = await qb.execute();
        deleted.visits = r.affected ?? 0;
      }
      if (dto.contacts) {
        const qb = this.contacts.createQueryBuilder().delete();
        if (fromDate) qb.andWhere('firstSeenAt >= :from', { from: fromDate });
        if (toDate) qb.andWhere('firstSeenAt <= :to', { to: toDate });
        const r = await qb.execute();
        deleted.contacts = r.affected ?? 0;
      }
      if (dto.stands) {
        deleted.stands = await this.stands.count();
        await this.stands.clear();
      }
      if (dto.beacons) {
        deleted.beacons = await this.beacons.count();
        await this.beacons.clear();
      }
      if (dto.fingerprints) {
        deleted.fingerprints = await this.fingerprints.count();
        await this.fingerprints.clear();
      }

      const range = fromDate || toDate
        ? ` [${fromDate?.toISOString() ?? '*'} → ${toDate?.toISOString() ?? '*'}]`
        : '';
      this.logger.warn(
        `WIPE-SELECTIVE${range}: visit=${deleted.visits}, contact=${deleted.contacts}, ` +
          `stand=${deleted.stands}, beacon=${deleted.beacons}, fingerprint=${deleted.fingerprints}`,
      );

      return { success: true, deleted };
    } finally {
      this.wipeState.endWipe();
    }
  }
}
