import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  CreateDateColumn,
  Index,
} from 'typeorm';

/**
 * İki cihaz arasında kurulmuş "contact" kaydı (60+ sn ve -80 dBm üstü).
 *
 * Aggregation mobilde yapılır; backend sadece depolar. Idempotency
 * (deviceId + clientEventId) unique index ile; visits ile aynı pattern.
 *
 * seenAnonId: karşı tarafın anonim kimliği (major:minor → "a1b2:c3d4").
 * Mobil cihazın kendi deviceId'si ile karşı tarafın seenAnonId'si
 * asimetrik — raporu kaydeden cihazın perspektifi depolanır.
 */
@Entity()
@Index('idx_contact_device_event', ['deviceId', 'clientEventId'], {
  unique: true,
  where: '"clientEventId" IS NOT NULL',
})
@Index('idx_contact_first_seen', ['firstSeenAt'])
@Index('idx_contact_seen_anon', ['seenAnonId'])
export class ContactEvent {
  @PrimaryGeneratedColumn()
  id: number;

  @Column()
  deviceId: string;

  @Column({ type: 'varchar', nullable: true })
  clientEventId: string | null;

  @Column()
  seenAnonId: string;

  @Column({ type: 'datetime' })
  firstSeenAt: Date;

  @Column({ type: 'datetime' })
  lastSeenAt: Date;

  @Column()
  durationSeconds: number;

  @Column({ type: 'float' })
  avgRssi: number;

  @Column()
  sampleCount: number;

  @CreateDateColumn()
  createdAt: Date;
}
