import { NestFactory } from '@nestjs/core';
import { ValidationPipe, Logger } from '@nestjs/common';
import * as fs from 'fs';
import * as path from 'path';
import { AppModule } from './app.module';

// HTTPS_ENABLED=true ise TLS ile dinle, değilse düz HTTP.
// Tek port kullanılır (PORT env'i). Cert yolları HTTPS_KEY_PATH / HTTPS_CERT_PATH.
function buildHttpsOptions(): { key: Buffer; cert: Buffer } | undefined {
  if (process.env.HTTPS_ENABLED !== 'true') return undefined;

  const keyPath = process.env.HTTPS_KEY_PATH ?? path.resolve(__dirname, '..', 'certs', 'dev-key.pem');
  const certPath = process.env.HTTPS_CERT_PATH ?? path.resolve(__dirname, '..', 'certs', 'dev-cert.pem');

  if (!fs.existsSync(keyPath) || !fs.existsSync(certPath)) {
    throw new Error(
      `HTTPS_ENABLED=true ama cert dosyaları yok:\n  key: ${keyPath}\n  cert: ${certPath}\n` +
        `README'deki openssl komutuyla üret veya HTTPS_KEY_PATH/HTTPS_CERT_PATH ile yol belirt.`,
    );
  }

  return {
    key: fs.readFileSync(keyPath),
    cert: fs.readFileSync(certPath),
  };
}

async function bootstrap() {
  const httpsOptions = buildHttpsOptions();

  const app = await NestFactory.create(AppModule, {
    logger: ['log', 'error', 'warn', 'debug'],
    ...(httpsOptions ? { httpsOptions } : {}),
  });

  app.setGlobalPrefix('api');

  // CORS: Admin paneli farklı porttan gelirse (canvas HTML
  // static serve edildiğinde aynı origin — ama geliştirirken Vite/Next
  // 3001/5173'ten gelebilir) bu ayar gerekli.
  app.enableCors({
    origin: process.env.CORS_ORIGIN?.split(',') ?? true,
    credentials: true,
  });

  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,              // DTO'da olmayan alanlar payload'dan silinir
      forbidNonWhitelisted: true,   // Ekstra alan gelirse 400 döner
      transform: true,              // String → number otomatik cast
      transformOptions: { enableImplicitConversion: true },
      stopAtFirstError: false,
    }),
  );

  const port = parseInt(process.env.PORT ?? '3000', 10);
  await app.listen(port);

  const scheme = httpsOptions ? 'https' : 'http';
  Logger.log(`🚀 Beetinq API listening on ${scheme}://0.0.0.0:${port}`, 'Bootstrap');
}

bootstrap();
