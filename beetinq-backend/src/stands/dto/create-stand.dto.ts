import { IsString, IsNumber, IsOptional } from 'class-validator';

export class CreateStandDto {
  @IsString()
  name: string;

  // x,y opsiyonel: verilmezse StandsService.create auto-grid pozisyon atar.
  // Mobil "fingerprint kaydet = stand oluştur" akışı için.
  @IsOptional()
  @IsNumber()
  x?: number;

  @IsOptional()
  @IsNumber()
  y?: number;
}