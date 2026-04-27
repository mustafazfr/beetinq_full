package com.example.beetinq_sense

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * BeaconScanService — Android Foreground Service
 *
 * iOS'ta Region Monitoring ile sistem uygulamayı arka planda uyandırır.
 * Android'de bu mekanizma yoktur; bunun yerine Foreground Service açık
 * kalır ve bildirim çubuğunda kalıcı bir ikon gösterir.
 *
 * Bu servis Flutter tarafından değil doğrudan Android sistemi tarafından
 * yönetilir. Flutter (dchs_flutter_beacon) kütüphanesi kendi içinde
 * bu servisi başlatır — bizim görevimiz servisi tanımlamak ve
 * bildirim kanalını hazırlamak.
 */
class BeaconScanService : Service() {

    companion object {
        const val CHANNEL_ID = "beetinq_beacon_channel"
        const val NOTIFICATION_ID = 1001

        /** Flutter tarafından servisi başlatmak için çağrılır */
        fun start(context: Context) {
            val intent = Intent(context, BeaconScanService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** Flutter tarafından servisi durdurmak için çağrılır */
        fun stop(context: Context) {
            context.stopService(Intent(context, BeaconScanService::class.java))
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification())
        // START_NOT_STICKY: sistem servisi öldürürse yeniden başlatma.
        // START_STICKY kullanılsaydı: native servis ayağa kalkardı ama Flutter/Dart
        // motoru çalışmadığı için "zombi bildirim" oluşurdu — beacon verisi gitmeden
        // ekranda "tarama aktif" yazardı.
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        // STOP_FOREGROUND_REMOVE yalnızca API 24+ (Nougat) var.
        // minSdk=21 olduğu için eski cihazlarda NoSuchMethodError crash'i önlemek için
        // versiyon kontrolü gerekli.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    // ── BİLDİRİM KANALI ──────────────────────────────────────────────────
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Beacon Tarama",
                NotificationManager.IMPORTANCE_LOW  // Ses çıkarmasın
            ).apply {
                description = "Beetinq Sense arka planda beacon taraması yapıyor"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    // ── BİLDİRİM İÇERİĞİ ─────────────────────────────────────────────────
    private fun buildNotification(): Notification {
        // Bildirime tıklanınca uygulamayı aç
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Beetinq Sense")
            .setContentText("Beacon taraması aktif")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentIntent(pendingIntent)
            .setOngoing(true)       // Kullanıcı kapatamaz
            .setSilent(true)        // Ses/titreşim yok
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}