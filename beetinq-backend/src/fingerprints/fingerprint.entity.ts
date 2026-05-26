import {
  Entity,
  Column,
  PrimaryColumn,
  CreateDateColumn,
  UpdateDateColumn,
  Index,
} from 'typeorm';

/**
 * Bir stand/bölgenin RSSI parmak izi (radio map kaydı).
 *
 * Mobil bir cihaz "Konum Kaydet" yapınca o noktadaki beacon→RSSI haritasını
 * (rssiMap) buraya gönderir. DİĞER cihazlar açılışta bunları indirip kendi
 * FingerprintEngine'ine yükler → biri mekânı haritalar, herkes fingerprint
 * konumlama yapabilir. (Beacon koordinatlarının senkronu zaten vardı; bu onun
 * fingerprint karşılığı.)
 *
 * id: mobilin ürettiği client id (millisecondsSinceEpoch string). Aynı id ile
 * tekrar gelirse upsert (güncellenir), duplicate satır oluşmaz.
 */
@Entity()
@Index('idx_fingerprint_event', ['eventId'])
export class Fingerprint {
  @PrimaryColumn()
  id: string;

  @Column()
  name: string;

  /**
   * { "UUID-major-minor": rssi, ... } — beacon anahtarı → ortalama RSSI.
   * simple-json: TypeORM objeyi JSON metin olarak saklar/okur.
   */
  @Column({ type: 'simple-json' })
  rssiMap: Record<string, number>;

  /** Çoklu etkinlik (fuar) ayrımı için. */
  @Column({ default: 'default' })
  eventId: string;

  @CreateDateColumn()
  createdAt: Date;

  @UpdateDateColumn()
  updatedAt: Date;
}
