import {
  Controller,
  Get,
  Post,
  Delete,
  Body,
  Param,
  Query,
} from '@nestjs/common';

import { BeaconsService } from './beacons.service';
import { CreateBeaconDto } from './dto/create-beacon.dto';

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

  @Delete(':id')
  remove(@Param('id') id: string) {
    return this.beaconsService.remove(id);
  }
}
