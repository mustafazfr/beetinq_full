import { IsString, IsNumber, IsOptional, Min, Max, Length } from 'class-validator';

export class CreateStandDto {
  @IsString()
  @Length(1, 200)
  name: string;

  // x,y opsiyonel: verilmezse StandsService.create "yerleştirilmemiş"
  // (-1,-1) sentinel atar; admin panelden drag-drop ile konumlandırılır.
  // BUG FIX (Backend R7): NaN/Infinity/aşırı değer reddi (UpdateStand ile aynı).
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
