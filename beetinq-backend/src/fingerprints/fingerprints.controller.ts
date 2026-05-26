import {
  Controller,
  Get,
  Post,
  Delete,
  Body,
  Param,
  Query,
} from '@nestjs/common';

import { FingerprintsService } from './fingerprints.service';
import { CreateFingerprintDto } from './dto/create-fingerprint.dto';

@Controller('fingerprints')
export class FingerprintsController {
  constructor(private readonly service: FingerprintsService) {}

  /** Mobil "Konum Kaydet" sonrası RSSI parmak izini buraya gönderir. */
  @Post()
  create(@Body() dto: CreateFingerprintDto) {
    return this.service.create(dto);
  }

  /** Diğer cihazlar açılışta tüm fingerprint'leri buradan indirir. */
  @Get()
  findAll(@Query('eventId') eventId?: string) {
    return this.service.findAll(eventId ?? 'default');
  }

  @Delete(':id')
  remove(@Param('id') id: string) {
    return this.service.remove(id);
  }
}
