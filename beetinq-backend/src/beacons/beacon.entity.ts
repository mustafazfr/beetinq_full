import {
  Entity,
  Column,
  PrimaryColumn,
  ManyToOne,
  JoinColumn,
  CreateDateColumn,
  UpdateDateColumn,
} from 'typeorm';

import { Stand } from '../stands/stand.entity';

/**
 * Fiziksel alandaki bir beacon'ın sabit konumu.
 *
 * Primary key formatı: "UUID-MAJOR-MINOR" (mobil tarafın
 * `BeaconRow.key` formatıyla birebir aynı). Mobil bu id'yi
 * trilaterasyon `BeaconLocation.id` olarak kullanır.
 */
@Entity()
export class Beacon {
  /** "E2C56DB5-DFFB-48D2-B060-D0F5A71096E0-100-7" gibi */
  @PrimaryColumn()
  id: string;

  @Column()
  uuid: string;

  @Column()
  major: number;

  @Column()
  minor: number;

  @Column({ type: 'float' })
  x: number;

  @Column({ type: 'float' })
  y: number;

  /** Opsiyonel: admin bu beacon'a okunabilir isim verebilir */
  @Column({ type: 'varchar', nullable: true })
  name: string | null;

  /**
   * Opsiyonel stand ilişkisi. Beacon hangi stand'ın içindeyse oraya
   * bağlanır. Stand silinirse beacon kalır ama bağı kopar.
   */
  @ManyToOne(() => Stand, { nullable: true, onDelete: 'SET NULL' })
  @JoinColumn()
  stand: Stand | null;

  /** Çoklu etkinlik (fuar) senaryosu için */
  @Column({ default: 'default' })
  eventId: string;

  @CreateDateColumn()
  createdAt: Date;

  @UpdateDateColumn()
  updatedAt: Date;
}
