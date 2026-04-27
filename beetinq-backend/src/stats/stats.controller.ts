import { Controller, Get, Header, Query, Res } from '@nestjs/common';
import { IsOptional, IsDateString } from 'class-validator';
import type { Response } from 'express';
// eslint-disable-next-line @typescript-eslint/no-require-imports
import PDFDocument = require('pdfkit');

import { StatsService } from './stats.service';

class StatsQueryDto {
  @IsOptional()
  @IsDateString()
  from?: string;

  @IsOptional()
  @IsDateString()
  to?: string;
}

@Controller('stats')
export class StatsController {
  constructor(private readonly statsService: StatsService) {}

  @Get('dwell')
  getDwellStats(@Query() q: StatsQueryDto) {
    return this.statsService.getDwellStats(q.from, q.to);
  }

  @Get('heatmap')
  getHeatmapData(@Query() q: StatsQueryDto) {
    return this.statsService.getHeatmapData(q.from, q.to);
  }

  /**
   * Admin panel için özet: toplam visit, unique device sayısı, vb.
   */
  @Get('summary')
  getSummary(@Query() q: StatsQueryDto) {
    return this.statsService.getSummary(q.from, q.to);
  }

  /** Task 1.5.9 — contact tracing özeti. */
  @Get('contacts')
  getContactStats(@Query() q: StatsQueryDto) {
    return this.statsService.getContactStats(q.from, q.to);
  }

  /**
   * Task 2.3 — PDF rapor. Tarih aralığı filtre query'si visit/contact
   * stats'a uygulanır, pdfkit ile metinsel rapor üretilir. Heatmap snapshot
   * eklenmedi (headless canvas gerektiriyor, bitirme scope dışı).
   */
  @Get('report.pdf')
  @Header('Content-Type', 'application/pdf')
  @Header('Content-Disposition', 'attachment; filename="beetinq-rapor.pdf"')
  async getReportPdf(@Query() q: StatsQueryDto, @Res() res: Response) {
    const [summary, dwell, contacts] = await Promise.all([
      this.statsService.getSummary(q.from, q.to),
      this.statsService.getDwellStats(q.from, q.to),
      this.statsService.getContactStats(q.from, q.to),
    ]);

    const doc = new PDFDocument({ size: 'A4', margin: 50 });
    doc.pipe(res);

    // Başlık
    doc.fontSize(20).text('Beetinq Sense — Analiz Raporu', { align: 'center' });
    doc.moveDown(0.3);
    const rangeLabel =
      q.from || q.to
        ? `Aralık: ${q.from ?? '…'} → ${q.to ?? '…'}`
        : `Aralık: tüm veriler`;
    doc.fontSize(10).fillColor('#666').text(rangeLabel, { align: 'center' });
    doc.fillColor('black');
    doc.moveDown(1);

    // Özet
    doc.fontSize(14).text('Özet', { underline: true });
    doc.moveDown(0.3);
    doc.fontSize(11)
      .text(`Toplam ziyaret: ${summary.totalVisits}`)
      .text(`Benzersiz cihaz: ${summary.uniqueDevices}`)
      .text(`Ortalama bekleme: ${summary.avgDuration} sn`)
      .text(`Toplam bekleme: ${summary.totalDuration} sn`)
      .text(`Aktif stand: ${summary.activeStands}`);
    doc.moveDown(1);

    // Dwell listesi
    doc.fontSize(14).text('Stand bazlı bekleme süreleri', { underline: true });
    doc.moveDown(0.3);
    doc.fontSize(11);
    if (dwell.length === 0) {
      doc.fillColor('#666').text('Kayıt yok').fillColor('black');
    } else {
      for (const d of dwell) {
        doc.text(
          `• ${d.locationName} — ort. ${d.avgDuration}s, ` +
            `${d.visitCount} ziyaret, ${d.uniqueVisitors} cihaz`,
        );
      }
    }
    doc.moveDown(1);

    // Contact özeti
    doc.fontSize(14).text('Temas raporu', { underline: true });
    doc.moveDown(0.3);
    doc.fontSize(11)
      .text(`Toplam temas: ${contacts.totalContacts}`)
      .text(`Tahmini benzersiz cihaz: ~${contacts.uniqueDevicesInvolved}`)
      .text(`Ortalama temas süresi: ${contacts.avgDuration} sn`);
    if (contacts.topPairs.length > 0) {
      doc.moveDown(0.4);
      doc.text('En sık karşılaşan çiftler:');
      for (const p of contacts.topPairs) {
        doc.text(`  ${p.deviceId}  ↔  ${p.seenAnonId}  ×${p.count}`);
      }
    }

    // Footer
    doc.moveDown(2);
    doc.fontSize(9).fillColor('#888').text(
      `Oluşturulma: ${new Date().toISOString()} · Beetinq Sense (bitirme projesi)`,
      { align: 'center' },
    );

    doc.end();
  }
}
