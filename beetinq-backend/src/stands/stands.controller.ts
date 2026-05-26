import {
  Controller,
  Get,
  Post,
  Patch,
  Delete,
  Body,
  Param,
  Query,
} from '@nestjs/common';
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

  /**
   * Stand sil. Query: cascade=true → bu stand adındaki visit ve contact
   * kayıtları da temizlenir (admin "ilişkili verilerle birlikte sil" akışı).
   */
  @Delete(':id')
  remove(@Param('id') id: string, @Query('cascade') cascade?: string) {
    return this.standsService.remove(+id, cascade === 'true');
  }
}
