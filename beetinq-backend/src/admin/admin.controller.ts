import { Body, Controller, Get, Post } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { AdminService } from './admin.service';
import { WipeDto } from './dto/wipe.dto';

@Controller('admin')
export class AdminController {
  constructor(private readonly adminService: AdminService) {}

  /**
   * Tüm veriyi sıfırlar. Geri dönüş yok, dikkat.
   * Body { resetDevices: true } ise bağlı telefonlar da bir sonraki sync'te
   * kendini sıfırlar (uzaktan reset epoch'u ilerletilir).
   *
   * BUG FIX (Backend R12): destructive endpoint — 1 dakikada en fazla 3 çağrı.
   * Yanlışlıkla/scripted ardışık wipe'ları (ve çift tıklamayı) sınırlar.
   */
  @Throttle({ default: { limit: 3, ttl: 60000 } })
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
