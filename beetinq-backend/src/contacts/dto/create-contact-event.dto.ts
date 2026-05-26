import {
  IsString,
  IsNumber,
  IsOptional,
  IsDateString,
  IsInt,
  Min,
  Max,
  Length,
  Matches,
  IsUUID,
} from 'class-validator';

/**
 * Contact event payload. Mobil aggregation sonrası gönderir.
 * Idempotency için clientEventId (uuid v4).
 */
export class CreateContactEventDto {
  @IsString()
  @Length(16, 200)
  @Matches(/^[a-z0-9_-]+$/i, { message: 'deviceId geçersiz karakter içeriyor' })
  deviceId: string;

  @IsOptional()
  @IsUUID('4')
  clientEventId?: string;

  /**
   * Karşı tarafın anonim kimliği, format "xxxx:yyyy" (hex major:minor).
   * Mobilde contact_config.decodeAnonId ile üretilir.
   */
  @IsString()
  @Matches(/^[0-9a-f]{4}:[0-9a-f]{4}$/, {
    message: 'seenAnonId formatı "xxxx:yyyy" (hex) olmalı',
  })
  seenAnonId: string;

  @IsDateString()
  firstSeenAt: string;

  @IsDateString()
  lastSeenAt: string;

  /**
   * Saniye cinsinden temas süresi. Min 0; max 86400 (24 saat) — daha
   * uzun bir contact fiziksel olarak mantıksız, saat manipülasyonu sayılır.
   */
  @IsNumber({ allowNaN: false, allowInfinity: false })
  @Min(0)
  @Max(86400)
  durationSeconds: number;

  /**
   * Ortalama RSSI (dBm). Negatif değer beklenir; -100 .. 0 aralığı
   * pratikte tüm BLE donanımını kapsar.
   */
  @IsNumber({ allowNaN: false, allowInfinity: false })
  @Min(-100)
  @Max(0)
  avgRssi: number;

  @IsInt()
  @Min(1)
  @Max(100000)
  sampleCount: number;

  /**
   * Temas anındaki stand/konum adı (opsiyonel). Mobil, temas tetiklendiğinde
   * o anki detectedLocation'ı gönderir; konum bilinmiyorsa hiç gönderilmez.
   */
  @IsOptional()
  @IsString()
  @Length(1, 200)
  locationName?: string;
}
