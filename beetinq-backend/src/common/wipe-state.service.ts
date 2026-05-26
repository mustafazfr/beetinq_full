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
  // Boolean begin/end: pencere TAM olarak clear() kritik bölümünü kapsar
  // (zaman bazlı değil). Böylece wipe response döndükten SONRA gelen POST'lar
  // (örn. seed/test) reddedilmez; yalnızca clear() süren birkaç ms içinde
  // gelen eşzamanlı POST'lar 503 alır.
  private wiping = false;

  beginWipe(): void {
    this.wiping = true;
  }

  endWipe(): void {
    this.wiping = false;
  }

  get isWiping(): boolean {
    return this.wiping;
  }
}
