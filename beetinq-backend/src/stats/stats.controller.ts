import { Controller, Get, Query, Res, Header } from '@nestjs/common';
import type { Response } from 'express';
import { IsOptional, IsDateString, IsInt, Min, Max, IsString } from 'class-validator';
import { Type } from 'class-transformer';

import { StatsService } from './stats.service';

class StatsQueryDto {
  @IsOptional()
  @IsDateString()
  from?: string;

  @IsOptional()
  @IsDateString()
  to?: string;
}

class ActiveQueryDto {
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(1440)
  minutes?: number;
}

class DwellDistributionQueryDto extends StatsQueryDto {
  @IsOptional()
  @IsString()
  locationName?: string;
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

  /** Saatlik trafik dağılımı (24 kova). Dashboard bar chart için. */
  @Get('hourly')
  getHourlyTraffic(@Query() q: StatsQueryDto) {
    return this.statsService.getHourlyTraffic(q.from, q.to);
  }

  /**
   * Son N dakikada aktif olan unique cihaz sayısı. Default 5 dk.
   * Dashboard real-time badge için.
   */
  @Get('active')
  getActiveNow(@Query() q: ActiveQueryDto) {
    return this.statsService.getActiveNow(q.minutes ?? 5);
  }

  /** positionSource dağılımı: fingerprint / trilateration / unknown. */
  @Get('sources')
  getSourceDistribution(@Query() q: StatsQueryDto) {
    return this.statsService.getSourceDistribution(q.from, q.to);
  }

  /** Dwell time histogram (5 kova). Opsiyonel locationName filter. */
  @Get('dwell-distribution')
  getDwellDistribution(@Query() q: DwellDistributionQueryDto) {
    return this.statsService.getDwellDistribution(q.from, q.to, q.locationName);
  }

  /**
   * Etkinlik sonrası analiz raporu PDF (Sia ozeti "etkinlik sonrasi rapor"
   * maddesi). pdfkit ile A4 sayfaya özet + dwell tablosu + kaynak dağılımı
   * + temas top pairs + KVKK notu.
   */
  @Get('report.pdf')
  @Header('Content-Type', 'application/pdf')
  @Header(
    'Content-Disposition',
    'attachment; filename="beetinq-rapor.pdf"',
  )
  async getReportPdf(@Query() q: StatsQueryDto, @Res() res: Response) {
    await this.statsService.generatePdfReport(q.from, q.to, res);
  }

  /**
   * Tüm ziyaretleri CSV olarak indir. Excel uyumlu (UTF-8 BOM + CRLF).
   * Hassas alan: deviceId açık, hash zaten — kişisel veri yok.
   */
  @Get('visits.csv')
  @Header('Content-Type', 'text/csv; charset=utf-8')
  @Header(
    'Content-Disposition',
    'attachment; filename="beetinq-visits.csv"',
  )
  async getVisitsCsv(@Query() q: StatsQueryDto, @Res() res: Response) {
    const visits = await this.statsService.getAllVisitsForCsv(q.from, q.to);

    const cols = [
      'id',
      'deviceId',
      'locationName',
      'enteredAt',
      'exitedAt',
      'durationSeconds',
      'positionSource',
      'x',
      'y',
      'createdAt',
    ];

    const escape = (v: unknown): string => {
      if (v == null) return '';
      const s = String(v);
      // CSV escape: çift tırnak çift tırnağa, varsa tırnak içine al.
      if (s.includes(',') || s.includes('"') || s.includes('\n') || s.includes('\r')) {
        return `"${s.replace(/"/g, '""')}"`;
      }
      return s;
    };

    const lines: string[] = [];
    lines.push(cols.join(','));
    for (const v of visits) {
      lines.push(
        cols
          .map((c) => {
            const val = (v as unknown as Record<string, unknown>)[c];
            if (val instanceof Date) return escape(val.toISOString());
            return escape(val);
          })
          .join(','),
      );
    }

    // UTF-8 BOM: Excel'in TR karakterleri doğru göstermesi için.
    const bom = '﻿';
    res.send(bom + lines.join('\r\n'));
  }
}
