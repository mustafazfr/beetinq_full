import { IsString, IsNumber } from 'class-validator';

export class CreateStandDto {
  @IsString()
  name: string;

  @IsNumber()
  x: number;

  @IsNumber()
  y: number;
}