import { Module } from '@nestjs/common';
import { EventsGateway } from './events.gateway';

/**
 * WebSocket gateway'ini paylaşan modül. VisitsModule ve ContactsModule bunu
 * import eder; yeni kayıt sonrası `EventsGateway.emitDataChanged` çağrılır.
 */
@Module({
  providers: [EventsGateway],
  exports: [EventsGateway],
})
export class EventsModule {}
