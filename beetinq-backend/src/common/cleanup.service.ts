import { Injectable, Logger } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import { InjectRepository } from '@nestjs/typeorm';
import { LessThan, Repository } from 'typeorm';

import { Visit } from '../visits/visit.entity';
import { ContactEvent } from '../contacts/contact-event.entity';

/**
 * KVKK retention (Task 2.2): 14 günden eski visit ve contact kayıtlarını
 * her gece 03:00'te siler. Retention süresi env ile override edilebilir
 * (ör. test/demo sırasında 1 gün).
 */
@Injectable()
export class CleanupService {
  private readonly logger = new Logger(CleanupService.name);

  // 14 gün default; RETENTION_DAYS env ile override.
  private get retentionDays(): number {
    const raw = process.env.RETENTION_DAYS;
    if (!raw) return 14;
    const n = parseInt(raw, 10);
    return Number.isFinite(n) && n > 0 ? n : 14;
  }

  constructor(
    @InjectRepository(Visit)
    private visits: Repository<Visit>,
    @InjectRepository(ContactEvent)
    private contacts: Repository<ContactEvent>,
  ) {}

  // Her gece 03:00'te. CronExpression.EVERY_DAY_AT_3AM ile aynı — sabiti
  // kullanmak daha okunaklı.
  @Cron(CronExpression.EVERY_DAY_AT_3AM)
  async handleNightlyCleanup() {
    await this.runCleanup('cron');
  }

  /**
   * Manuel tetikleme noktası — ileride admin butonu veya test için.
   */
  async runCleanup(trigger: 'cron' | 'manual'): Promise<{
    visitsDeleted: number;
    contactsDeleted: number;
    cutoff: string;
  }> {
    const days = this.retentionDays;
    const cutoff = new Date(Date.now() - days * 24 * 60 * 60 * 1000);

    this.logger.log(
      `Retention cleanup (${trigger}) başlıyor — cutoff=${cutoff.toISOString()}, days=${days}`,
    );

    const visitsRes = await this.visits.delete({ enteredAt: LessThan(cutoff) });
    const contactsRes = await this.contacts.delete({
      firstSeenAt: LessThan(cutoff),
    });

    const visitsDeleted = visitsRes.affected ?? 0;
    const contactsDeleted = contactsRes.affected ?? 0;

    this.logger.log(
      `Retention cleanup tamam — visit silindi=${visitsDeleted}, contact silindi=${contactsDeleted}`,
    );

    return {
      visitsDeleted,
      contactsDeleted,
      cutoff: cutoff.toISOString(),
    };
  }
}
