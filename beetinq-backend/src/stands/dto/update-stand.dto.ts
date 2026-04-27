import { IsNumber } from 'class-validator';

export class UpdateStandDto {
  @IsNumber()
  x: number;

  @IsNumber()
  y: number;
}