import { Body, Controller, Get, Post } from '@nestjs/common';
import { Throttle } from '@nestjs/throttler';
import { AdminService } from './admin.service';
import { WipeDto } from './dto/wipe.dto';
import { WipeSelectiveDto } from './dto/wipe-selective.dto';

@Controller('admin')
export class AdminController {
  constructor(private readonly adminService: AdminService) {}

  /**
   * Tüm veriyi sıfırlar. Geri dönüş yok, dikkat.
   * Body { resetDevices: true } ise bağlı telefonlar da bir sonraki sync'te
   * kendini sıfırlar (uzaktan reset epoch'u ilerletilir).
   *
   * BUG FIX (Backend R12): destructive endpoint — 1 dakikada en fazla 10 çağrı.
   * Runaway script/sabotaj ve çift tıklamayı sınırlar ama normal test akışını
   * (seed/sandbox-test birkaç wipe yapar) engellemez.
   */
  @Throttle({ default: { limit: 10, ttl: 60000 } })
  @Post('wipe')
  wipe(@Body() dto: WipeDto) {
    return this.adminService.wipeAll(dto.resetDevices ?? false);
  }

  /**
   * Seçerek silme: kullanıcı admin panelden hangi kategorileri silmek
   * istediğini işaretler. Mevcut "Sıfırla" nükleer iken bu cerrahi.
   */
  @Throttle({ default: { limit: 10, ttl: 60000 } })
  @Post('wipe-selective')
  wipeSelective(@Body() dto: WipeSelectiveDto) {
    return this.adminService.wipeSelective(dto);
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
