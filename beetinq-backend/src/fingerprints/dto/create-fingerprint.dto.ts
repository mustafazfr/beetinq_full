import {
  IsString,
  IsObject,
  IsOptional,
  Length,
  IsNotEmpty,
} from 'class-validator';

/**
 * Fingerprint (radio map) kaydı. Mobil "Konum Kaydet" sonrası gönderir.
 * id mobilin ürettiği client id; aynı id ile tekrar gelirse backend upsert eder.
 */
export class CreateFingerprintDto {
  @IsString()
  @Length(1, 100)
  id: string;

  @IsString()
  @Length(1, 200)
  name: string;

  /**
   * { beaconKey: rssi } haritası. Anahtarlar dinamik (UUID-major-minor),
   * o yüzden nested validation yerine obje + boş-değil kontrolü yeterli;
   * değerler mobilde zaten int RSSI.
   */
  @IsObject()
  @IsNotEmpty()
  rssiMap: Record<string, number>;

  @IsOptional()
  @IsString()
  @Length(1, 50)
  eventId?: string;
}
