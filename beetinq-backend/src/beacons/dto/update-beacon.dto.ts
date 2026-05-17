import { IsNumber, IsOptional, Min, Max } from 'class-validator';

/** Drag-drop için x,y güncellemesi. Diğer alanlar değişmez. */
export class UpdateBeaconDto {
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
