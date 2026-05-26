import { IsNumber, Min, Max } from 'class-validator';

export class UpdateStandDto {
  // BUG FIX (Backend R7): NaN/Infinity/aşırı koordinat reddedilsin. Eskiden
  // sadece @IsNumber vardı; {x: NaN} veya {x: 999999} kabul edilip DB'ye
  // yazılıyor, heatmap/canvas render'ı bozuyordu. Beacon DTO ile aynı sınır.
  @IsNumber({ allowNaN: false, allowInfinity: false })
  @Min(-1000)
  @Max(1000)
  x: number;

  @IsNumber({ allowNaN: false, allowInfinity: false })
  @Min(-1000)
  @Max(1000)
  y: number;
}
