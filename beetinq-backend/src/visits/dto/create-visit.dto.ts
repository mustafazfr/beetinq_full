import {
  IsString,
  IsNumber,
  IsOptional,
  IsDateString,
  Min,
  Max,
  Length,
  Matches,
  IsIn,
  IsUUID,
} from 'class-validator';

export class CreateVisitDto {
  // SHA-256 hash (64 hex) veya fallback_<32 hex> formatı
  @IsString()
  @Length(16, 200)
  @Matches(/^[a-z0-9_-]+$/i, { message: 'deviceId geçersiz karakter içeriyor' })
  deviceId: string;

  /**
   * Idempotency anahtarı. Mobil her event için bir uuid v4 üretir
   * ve offline retry'larda aynı uuid'yi gönderir. Backend aynı
   * (deviceId, clientEventId) ikilisini ikinci kez görürse duplicate
   * kabul eder.
   * Geriye dönük uyumluluk için optional (eski sürüm göndermez).
   */
  @IsOptional()
  @IsUUID('4')
  clientEventId?: string;

  @IsString()
  @Length(1, 200)
  locationName: string;

  @IsDateString()
  enteredAt: string;

  @IsDateString()
  exitedAt: string;

  /**
   * Kalış süresi saniye cinsinden.
   * - Min 0: negatif süre fiziksel olarak imkânsız.
   * - Max 86400 (24 saat): bir telefon 24 saatten uzun bir "aktif
   *   beacon session"ı tutmayı başaramaz; bu değer aşılırsa saat
   *   manipülasyonu veya bug var demektir.
   */
  @IsNumber({ allowNaN: false, allowInfinity: false })
  @Min(0)
  @Max(86400)
  durationSeconds: number;

  @IsOptional()
  @IsIn(['fingerprint', 'trilateration', 'unknown'])
  positionSource?: string;

  @IsOptional()
  @IsNumber({ allowNaN: false, allowInfinity: false })
  @Min(-1000)
  @Max(1000)
  x?: number;

  @IsOptional()
  @IsNumber({ allowNaN: false, allowInfinity: false })
  @Min(-1000)
  @Max(1000)
  y?: number;
}
