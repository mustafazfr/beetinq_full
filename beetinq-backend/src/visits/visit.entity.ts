import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  CreateDateColumn,
  Index,
} from 'typeorm';

/**
 * Bir ziyaretçinin bir stand'daki kalış kaydı.
 *
 * Idempotency: (deviceId + clientEventId) kombinasyonu unique.
 * Mobil offline queue'da aynı event'i birden çok kez gönderirse
 * ikinci INSERT benzersizlik ihlaliyle reddedilir ve service
 * bunu "duplicate" olarak yakalar.
 */
@Entity()
@Index('idx_visit_device_event', ['deviceId', 'clientEventId'], {
  unique: true,
  where: '"clientEventId" IS NOT NULL',
})
@Index('idx_visit_location', ['locationName'])
@Index('idx_visit_entered', ['enteredAt'])
export class Visit {
  @PrimaryGeneratedColumn()
  id: number;

  @Column()
  deviceId: string;

  /**
   * Mobil tarafın ürettiği benzersiz event id (uuid v4).
   * Eski sürüm mobil göndermediği için nullable bırakıldı; yeni
   * sürüm her zaman gönderir ve unique index aktif olur.
   */
  @Column({ type: 'varchar', nullable: true })
  clientEventId: string | null;

  @Column()
  locationName: string;

  @Column({ type: 'datetime' })
  enteredAt: Date;

  @Column({ type: 'datetime' })
  exitedAt: Date;

  @Column()
  durationSeconds: number;

  @Column({ type: 'varchar', nullable: true })
  positionSource: string | null;

  @Column({ type: 'float', nullable: true })
  x: number | null;

  @Column({ type: 'float', nullable: true })
  y: number | null;

  @CreateDateColumn()
  createdAt: Date;
}
