import { IsBoolean, IsOptional } from 'class-validator';

/**
 * Wipe isteği gövdesi. resetDevices=true ise sunucu verisi silinmekle
 * kalmaz, "uzaktan sıfırlama epoch'u" da ilerletilir; bağlı telefonlar
 * bir sonraki sync'te (~30sn) bunu görüp kendi yerel verilerini de
 * (fingerprint, oturum, offline kuyruk) sıfırlar.
 */
export class WipeDto {
  @IsOptional()
  @IsBoolean()
  resetDevices?: boolean;
}
