import {
  IsString,
  IsOptional,
  IsNumber,
  IsIn,
  Length,
  Matches,
} from 'class-validator';

/**
 * Mobilin gönderdiği doğruluk ölçümü. correct ve errorMeters BACKEND'de
 * hesaplanır (ground truth stand'ın gerçek x,y'si serverda) — istemci yalnızca
 * gerçek konumu + sistem tahminini bildirir.
 */
export class CreateAccuracyDto {
  @IsString()
  @Length(16, 200)
  @Matches(/^[a-z0-9_-]+$/i)
  deviceId: string;

  @IsString()
  @Length(1, 200)
  groundTruth: string;

  @IsOptional()
  @IsString()
  @Length(1, 200)
  predictedLocation?: string;

  @IsOptional()
  @IsIn(['fingerprint', 'trilateration', 'unknown'])
  positionSource?: string;

  /** Sistemin tahmin ettiği konum (trilaterasyon varsa). */
  @IsOptional()
  @IsNumber({ allowNaN: false, allowInfinity: false })
  predictedX?: number;

  @IsOptional()
  @IsNumber({ allowNaN: false, allowInfinity: false })
  predictedY?: number;
}
