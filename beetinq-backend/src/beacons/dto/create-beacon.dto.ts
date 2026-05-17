import {
  IsString,
  IsNumber,
  IsOptional,
  Matches,
  Min,
  Max,
} from 'class-validator';

export class CreateBeaconDto {
  /**
   * Canonical UUID (uppercase, dashed).
   * Mobil `_normalizeUuid` ile bu formata çeviriyor.
   */
  @IsString()
  @Matches(/^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/, {
    message: 'uuid canonical format olmalı: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX',
  })
  uuid: string;

  @IsNumber()
  @Min(0)
  @Max(65535)
  major: number;

  @IsNumber()
  @Min(0)
  @Max(65535)
  minor: number;

  // x,y opsiyonel: verilmezse BeaconsService.create auto-grid (1m aralıklı)
  // pozisyona koyar. Mobil tarafında "Konum bilmiyorum" akışı için.
  @IsOptional()
  @IsNumber()
  @Min(-1000)
  @Max(1000)
  x?: number;

  @IsOptional()
  @IsNumber()
  @Min(-1000)
  @Max(1000)
  y?: number;

  @IsOptional()
  @IsString()
  name?: string;

  @IsOptional()
  @IsNumber()
  standId?: number;

  @IsOptional()
  @IsString()
  eventId?: string;
}
