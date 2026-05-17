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

import { BeaconsService } from './beacons.service';
import { CreateBeaconDto } from './dto/create-beacon.dto';
import { UpdateBeaconDto } from './dto/update-beacon.dto';

@Controller('beacons')
export class BeaconsController {
  constructor(private readonly beaconsService: BeaconsService) {}

  @Post()
  create(@Body() dto: CreateBeaconDto) {
    return this.beaconsService.create(dto);
  }

  /** Admin paneli için tam liste (stand ilişkisiyle) */
  @Get()
  findAll(@Query('eventId') eventId?: string) {
    return this.beaconsService.findAll(eventId);
  }

  /**
   * Mobil uyumlu endpoint: `api_service.fetchBeaconLocations` buraya
   * GET /api/beacons/locations?eventId=default ile istek atar.
   * Yanıt formatı `BeaconLocation.fromJson` ile eşleşir.
   */
  @Get('locations')
  getLocations(@Query('eventId') eventId?: string) {
    return this.beaconsService.getLocationsForMobile(eventId ?? 'default');
  }

  /** Drag-drop ile x,y güncelleme. */
  @Patch(':id')
  update(@Param('id') id: string, @Body() dto: UpdateBeaconDto) {
    return this.beaconsService.update(id, dto);
  }

  @Delete(':id')
  remove(@Param('id') id: string) {
    return this.beaconsService.remove(id);
  }
}
