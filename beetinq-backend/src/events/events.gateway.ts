import { WebSocketGateway, WebSocketServer } from '@nestjs/websockets';
import { Logger } from '@nestjs/common';
import { Server } from 'socket.io';

/**
 * Gerçek zamanlı panel yayını (Sia özeti "Paneller için WebSocket veri yayını").
 *
 * Mimari: panel verileri yine REST'ten çeker; bu gateway sadece "veri değişti"
 * tetikleyicisi yayınlar. Yani payload minimal — panel `data-changed` event'i
 * alınca mevcut `loadAll()` akışını çalıştırır. Böylece WebSocket eklenirken
 * REST/stats endpoint'lerine dokunulmaz ve WS koparsa panel polling'e düşer
 * (admin panel hem WS hem polling fallback kullanır).
 *
 * cors: '*' — admin panel aynı origin'den serve edilse de, geliştirme sırasında
 * farklı porttan (Vite vs.) bağlanırsa bağlantı kurulabilsin.
 */
@WebSocketGateway({ cors: { origin: '*' } })
export class EventsGateway {
  private readonly logger = new Logger(EventsGateway.name);

  @WebSocketServer()
  server: Server;

  /**
   * Yeni veri kaydedildiğinde panele "yenile" sinyali gönderir.
   * server henüz init olmadan çağrılırsa (?.), sessizce geçilir.
   */
  emitDataChanged(kind: 'visit' | 'contact') {
    this.server?.emit('data-changed', {
      kind,
      at: new Date().toISOString(),
    });
  }
}
