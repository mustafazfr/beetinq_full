import { Injectable } from '@nestjs/common';

/**
 * Wipe yarış koruması (Backend R4).
 *
 * AdminService.wipeAll() tabloları sırayla clear() ederken, paralel gelen
 * POST /visit veya POST /contacts istekleri clear'lar arasına denk gelirse
 * "orphan" kayıt bırakabiliyordu (wipe sonrası veri tekrar belirir →
 * kullanıcının "wipe ettim ama veri geri geldi" şikâyetinin server tarafı).
 *
 * Bu servis kısa bir "wipe penceresi" tutar; Visits/Contacts create()
 * bu pencere açıkken 503 döndürür. Mobil offline kuyruğu zaten idempotent
 * retry yaptığı için 503 alan kayıt birkaç saniye sonra tekrar gönderilir,
 * veri kaybı olmaz.
 */
@Injectable()
export class WipeStateService {
  private wipingUntilMs = 0;

  /** Wipe başladı — kısa bir koruma penceresi aç (varsayılan 3 sn). */
  beginWipe(windowMs = 3000): void {
    this.wipingUntilMs = Date.now() + windowMs;
  }

  /** Pencere hâlâ açık mı? create() guard'ları bunu kontrol eder. */
  get isWiping(): boolean {
    return Date.now() < this.wipingUntilMs;
  }
}
