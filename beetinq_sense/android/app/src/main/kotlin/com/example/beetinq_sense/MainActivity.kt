package com.example.beetinq_sense

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    // Dart tarafındaki beacon_service.dart ile aynı olmalı:
    // static const _channel = MethodChannel('com.beetinq.sense/beacon_service');
    private val CHANNEL = "com.beetinq.sense/beacon_service"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        // Android 12+ (API 31): uygulama arka plandayken startForegroundService()
                        // çağrısı ForegroundServiceStartNotAllowedException fırlatır.
                        // try-catch ile yakalayıp Dart'a hata döndürerek crash önlenir.
                        try {
                            BeaconScanService.start(applicationContext)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("FGS_START_FAILED", e.message, null)
                        }
                    }
                    "stopService" -> {
                        BeaconScanService.stop(applicationContext)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}