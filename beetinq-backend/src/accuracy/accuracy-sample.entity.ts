import {
  Entity,
  Column,
  PrimaryGeneratedColumn,
  CreateDateColumn,
  Index,
} from 'typeorm';

/**
 * Konum doğruluğu ölçümü. Kullanıcı sahada "şu an X standındayım" (ground
 * truth) işaretler; o anki sistem tahmini ile karşılaştırılır. Tez için
 * accuracy metriği (fingerprint isabet %, trilaterasyon median hata m) buradan
 * çıkar. Mevcut tabloları etkilemez (yeni tablo).
 */
@Entity()
@Index('idx_accuracy_created', ['createdAt'])
export class AccuracySample {
  @PrimaryGeneratedColumn()
  id: number;

  @Column()
  deviceId: string;

  /** Kullanıcının işaretlediği gerçek stand (ground truth). */
  @Column()
  groundTruth: string;

  /** Sistemin o an tahmin ettiği stand (null = konum bulunamadı). */
  @Column({ type: 'varchar', nullable: true })
  predictedLocation: string | null;

  /** fingerprint | trilateration | unknown | null */
  @Column({ type: 'varchar', nullable: true })
  positionSource: string | null;

  /** Fingerprint tahmini doğru muydu (predicted == groundTruth). */
  @Column()
  correct: boolean;

  /** Trilaterasyon hatası (m): tahmin (x,y) ile gerçek stand (x,y) mesafesi.
   *  Hesaplanamadıysa (ground truth stand konumsuz / x,y yok) null. */
  @Column({ type: 'float', nullable: true })
  errorMeters: number | null;

  @CreateDateColumn()
  createdAt: Date;
}
