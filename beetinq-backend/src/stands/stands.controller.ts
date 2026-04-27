import { Controller, Get, Post, Patch, Delete, Body, Param } from '@nestjs/common';
import { StandsService } from './stands.service';
import { CreateStandDto } from './dto/create-stand.dto';
import { UpdateStandDto } from './dto/update-stand.dto';

@Controller('stands')
export class StandsController {
  constructor(private readonly standsService: StandsService) {}

  @Post()
  create(@Body() dto: CreateStandDto) {
    return this.standsService.create(dto);
  }

  @Get()
  findAll() {
    return this.standsService.findAll();
  }

  @Patch(':id')
  update(@Param('id') id: string, @Body() dto: UpdateStandDto) {
    return this.standsService.updatePosition(+id, dto);
  }

  @Delete(':id')
  remove(@Param('id') id: string) {
    return this.standsService.remove(+id);
  }
}