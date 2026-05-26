import { IsBoolean, IsOptional, IsDateString } from 'class-validator';

/**
 * Seçerek silme: kullanıcı admin panelden hangi kategorileri silmek istediğini
 * checkbox'larla seçer; opsiyonel tarih aralığı yalnızca tarih-tabanlı tablolara
 * (visits, contacts) uygulanır. stands/beacons/fingerprints zaten tarihsiz —
 * seçilirse tablo tamamen silinir.
 */
export class WipeSelectiveDto {
  @IsOptional() @IsBoolean() visits?: boolean;
  @IsOptional() @IsBoolean() contacts?: boolean;
  @IsOptional() @IsBoolean() stands?: boolean;
  @IsOptional() @IsBoolean() beacons?: boolean;
  @IsOptional() @IsBoolean() fingerprints?: boolean;

  /** Sadece visits ve contacts için: bu tarihten itibaren (ISO). */
  @IsOptional() @IsDateString() from?: string;
  /** Sadece visits ve contacts için: bu tarihe kadar (ISO). */
  @IsOptional() @IsDateString() to?: string;
}
