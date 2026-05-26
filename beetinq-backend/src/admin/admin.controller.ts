import { Body, Controller, Get, Post } from '@nestjs/common';
import { AdminService } from './admin.service';
import { WipeDto } from './dto/wipe.dto';

@Controller('admin')
export class AdminController {
  constructor(private readonly adminService: AdminService) {}

  /**
   * Tüm test/demo verisini sıfırlar. Geri dönüş yok, dikkat.
   * Body { resetDevices: true } ise bağlı telefonlar da bir sonraki sync'te
   * kendini sıfırlar (uzaktan reset epoch'u ilerletilir).
   */
  @Post('wipe')
  wipe(@Body() dto: WipeDto) {
    return this.adminService.wipeAll(dto.resetDevices ?? false);
  }

  /**
   * Uzaktan cihaz sıfırlama epoch'u. Telefonlar periyodik olarak sorgular;
   * kendi sakladıkları epoch'tan büyükse yerel verilerini sıfırlar.
   */
  @Get('device-reset-epoch')
  deviceResetEpoch() {
    return { epoch: this.adminService.getDeviceResetEpoch() };
  }
}
