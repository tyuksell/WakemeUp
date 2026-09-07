import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:http/http.dart' as http;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:uuid/uuid.dart';
import 'hive_service.dart';
import 'background_service.dart';
import 'notification_service.dart';
import '../utils/constants.dart';
import '../../features/presentation/pages/tracking_page.dart';
import '../../features/presentation/widgets/center_toast.dart';

/// Bir hedefe (yeni seçilmiş ya da geçmişten tekrar başlatılan) takip
/// oturumu başlatmak için gereken tüm akışı (izinler, backend'e kayıt,
/// offline düşüş, arka plan servisini ayağa kaldırma) tek bir yerde toplar.
/// map_page.dart (yeni rota) ve history_page.dart (geçmişten tekrar
/// başlatma) tarafından ortak kullanılır — backend'in kendisine dokunmaz,
/// yalnızca mobil taraftaki başlatma mantığını tekilleştirir.
class RouteLauncher {
  RouteLauncher._();

  static final Uuid _uuid = const Uuid();

  static Future<bool> hasActualInternet() async {
    try {
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult.contains(ConnectivityResult.none)) return false;

      final String host = Uri.parse(MyBackgroundService.serverBaseUrl).host;
      final result = await InternetAddress.lookup(host.isEmpty ? 'mapbox.com' : host)
          .timeout(const Duration(seconds: 4));

      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (_) {
      try {
        final result =
            await InternetAddress.lookup('mapbox.com').timeout(const Duration(seconds: 3));
        return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
      } catch (__) {
        return false;
      }
    }
  }

  /// Bir hedefe rota başlatır: bildirim izni + platforma özgü arka plan
  /// takip güvencesini ister, internet varsa backend'e kaydeder, yoksa ya da
  /// backend hata verirse offline devam etme onayı ister, ardından arka plan
  /// takip servisini başlatıp [TrackingPage]'e yönlendirir.
  static Future<void> launch({
    required BuildContext context,
    required String destName,
    required double lat,
    required double lng,
  }) async {
    await NotificationService.requestPermissions();

    // Konum izni + platforma özgü arka plan takip güvencesi (iOS "Always",
    // Android pil optimizasyonu istisnası). Kullanıcı reddederse yine de
    // devam edilir; ancak arka plan takibi güvenilir çalışmayabilir.
    await _ensureReliableBackgroundTracking(context);

    final bool isOnline = await hasActualInternet();

    if (isOnline) {
      final String deviceId = await HiveService.getOrCreateDeviceId();
      final AlarmThresholds thresholds = await HiveService.getThresholds();
      final Uri uri = Uri.parse('${MyBackgroundService.serverBaseUrl}/api/routes/');
      final Map<String, String> headers = {
        'Content-Type': 'application/json',
        'ngrok-skip-browser-warning': 'true',
        'X-Device-Id': deviceId,
      };
      final String body = jsonEncode({
        'destination_name': destName,
        'dest_latitude': lat,
        'dest_longitude': lng,
        'threshold_far_m': thresholds.farM,
        'threshold_mid_m': thresholds.midM,
        'threshold_near_m': thresholds.nearM,
      });

      http.Response? response;
      try {
        response = await http.post(uri, headers: headers, body: body).timeout(const Duration(seconds: 8));
      } on TimeoutException {
        // Render'ın ücretsiz katmanı 15 dakika hareketsizlikten sonra uyur;
        // ilk istek 30-50sn sürebilir. Bunu gerçek bir bağlantı hatası/
        // "offline" sanıp kullanıcıya yanlışlıkla "offline devam edilsin
        // mi?" diye sormak yerine, sunucunun uyandığını bildirip daha uzun
        // bir zaman aşımıyla bir kez daha deniyoruz.
        if (context.mounted) {
          CenterToast.show(context, message: 'Sunucu uyanıyor, tekrar deneniyor...', type: ToastType.info);
        }
        try {
          response = await http.post(uri, headers: headers, body: body).timeout(const Duration(seconds: 45));
        } catch (e) {
          response = null;
        }
      } catch (e) {
        response = null;
      }

      if (response != null && response.statusCode == 201) {
        final data = jsonDecode(response.body);
        final int routeId = data['id'];

        await HiveService.setTrackingState(
          routeId: routeId,
          name: destName,
          lat: lat,
          lng: lng,
        );

        await _startTracking(context);
      } else if (response != null) {
        if (context.mounted) {
          CenterToast.show(
            context,
            message: 'Backend sunucusu hata verdi. Durum: ${response.statusCode}',
            type: ToastType.error,
          );
        }
        if (context.mounted) {
          await _confirmOfflineFallback(
              context, destName, lat, lng, 'Sunucuya bağlanılamadı, offline devam edilsin mi?');
        }
      } else if (context.mounted) {
        await _confirmOfflineFallback(
            context, destName, lat, lng, 'İşlem sırasında bir hata oluştu. Offline devam edilsin mi?');
      }
    } else {
      if (context.mounted) {
        CenterToast.show(context, message: 'İnternet bulunamadı. Offline-First takip modu başlatıldı.', type: ToastType.success);
      }
      await _startOfflineTracking(context, destName, lat, lng);
    }
  }

  /// Platforma özgü, arka planda güvenilir konum takibi için gereken izin/ayar
  /// akışını yürütür. Her iki platformda da kullanıcı reddederse akış
  /// engellenmez; sadece takip arka planda düzensiz çalışabilir.
  static Future<void> _ensureReliableBackgroundTracking(BuildContext context) async {
    // Konum izni (When In Use / Always) — servis başlamadan önce alınmalı.
    geo.LocationPermission locPerm = await geo.Geolocator.checkPermission();
    if (locPerm == geo.LocationPermission.denied) {
      locPerm = await geo.Geolocator.requestPermission();
    }
    if (locPerm == geo.LocationPermission.deniedForever) return;

    if (Platform.isIOS) {
      // iOS'ta arka planda GPS almak için "Her Zaman İzin Ver" (Always) şart;
      // "Uygulamayı Kullanırken" (whileInUse) izni ekran kilitlenince veya
      // uygulama arka plana alınınca konum akışını durdurur. iOS bu izni
      // ikinci bir sistem isteğiyle (veya kullanıcı Ayarlar'dan) verir.
      final geo.LocationPermission refreshed = await geo.Geolocator.checkPermission();
      if (refreshed == geo.LocationPermission.whileInUse && context.mounted) {
        final bool? openSettings = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Arka Planda Takip İçin İzin Gerekli'),
            content: const Text(
              'WakeMeUp, ekranınız kilitliyken veya uygulama arka plandayken de '
              'hedefe yaklaştığınızı algılayabilmek için konum iznini "Her Zaman '
              'İzin Ver" olarak ayarlamanızı gerektirir. Aksi halde alarm yalnızca '
              'uygulama ekranda açıkken tetiklenir.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Şimdilik Devam Et'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Ayarları Aç'),
              ),
            ],
          ),
        );
        if (openSettings == true) {
          await geo.Geolocator.openAppSettings();
        }
      }
    } else if (Platform.isAndroid) {
      // Android'de üretici pil optimizasyonları (Xiaomi/Huawei/Samsung vb.)
      // foreground service'i yine de arka planda öldürebilir. Kullanıcıdan
      // uygulamayı optimizasyon istisnasına almasını istiyoruz.
      final ph.PermissionStatus batteryStatus =
          await ph.Permission.ignoreBatteryOptimizations.status;
      if (!batteryStatus.isGranted && context.mounted) {
        final bool? requestExemption = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Güvenilir Arka Plan Takibi'),
            content: const Text(
              'Telefonunuzun pil tasarrufu ayarları, ekran kapalıyken konum '
              'takibini durdurabilir. Alarmın güvenilir çalışması için WakeMeUp\'ı '
              'pil optimizasyonundan muaf tutmanızı öneririz.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Şimdilik Geç'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('İzin Ver'),
              ),
            ],
          ),
        );
        if (requestExemption == true) {
          await ph.Permission.ignoreBatteryOptimizations.request();
        }
      }

      // `alarm` paketinin STAGE_NEAR/varış anlarında gerçek çalar saat gibi
      // neredeyse anında tetiklenebilmesi için Android 12+ üzerinde gereken izin.
      try {
        final ph.PermissionStatus exactAlarmStatus =
            await ph.Permission.scheduleExactAlarm.status;
        if (!exactAlarmStatus.isGranted) {
          await ph.Permission.scheduleExactAlarm.request();
        }
      } catch (_) {
        // Bu izin tipini desteklemeyen OS sürümlerinde sessizce geç.
      }
    }
  }

  static Future<void> _confirmOfflineFallback(
    BuildContext context,
    String destName,
    double lat,
    double lng,
    String message,
  ) async {
    final bool? proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Bağlantı Sorunu'),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false), child: const Text('İptal')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Offline Devam Et')),
        ],
      ),
    );
    if (proceed == true && context.mounted) {
      await _startOfflineTracking(context, destName, lat, lng);
    }
  }

  static Future<void> _startOfflineTracking(
    BuildContext context,
    String destName,
    double lat,
    double lng,
  ) async {
    await HiveService.setTrackingState(
      routeId: kOfflineRouteId,
      name: destName,
      lat: lat,
      lng: lng,
    );
    await _startTracking(context);
  }

  static Future<void> _startTracking(BuildContext context) async {
    final service = FlutterBackgroundService();
    final alreadyRunning = await service.isRunning();

    if (alreadyRunning) {
      // Temiz bellek ve yeni isolate dinleyicileri garanti etmek için mevcut servisi kapatıyoruz.
      debugPrint('[RouteLauncher] Eski arka plan servisi kapatılıyor...');
      service.invoke('stopService');
      // Eski servisin durması ve OS'un kaynakları serbest bırakması için yeterli süre.
      await Future.delayed(const Duration(milliseconds: 600));
    }

    await service.startService();

    // Arka plan izolatının ayağa kalkıp tüm service.on(...).listen() çağrılarını
    // kaydetmesi için yeterli süre tanınıyor. Düşük sınıf cihazlarda 300ms yetersizdi.
    await Future.delayed(const Duration(milliseconds: 800));

    // Hive'dan onaylanan hedef bilgilerini oku.
    final routeId = await HiveService.getActiveRouteId() ?? kOfflineRouteId;
    final name = await HiveService.getDestName() ?? "Hedef";
    final lat = await HiveService.getDestLatitude() ?? 0.0;
    final lng = await HiveService.getDestLongitude() ?? 0.0;
    final deviceId = await HiveService.getOrCreateDeviceId();
    final thresholds = await HiveService.getThresholds();

    // Bu takip oturumu için cihazda kalıcı bir geçmiş kaydı oluştur.
    // Backend'e bağlı değildir; böylece sunucu yeniden başlasa veya
    // internet olmasa bile "Geçmiş Rotalar" ekranı bu kaydı gösterir.
    // Önce, backend'in de kendi tarafında yaptığı gibi, hâlâ "ACTIVE"
    // görünen önceki oturumu kapatıyoruz (üzerine yeni bir rota başlatılıyor).
    await HiveService.closeStaleActiveHistoryEntries();
    final String historyId = _uuid.v4();
    await HiveService.setActiveHistoryId(historyId);
    await HiveService.addHistoryEntry(RouteHistoryEntry(
      id: historyId,
      destinationName: name,
      lat: lat,
      lng: lng,
      status: 'ACTIVE',
      isMuted: false,
      createdAt: DateTime.now(),
    ));

    // Birincil mesaj: startTracking — ilk konum alımını ve tüm state'i initialize eder.
    service.invoke('startTracking', {
      'routeId': routeId,
      'name': name,
      'latitude': lat,
      'longitude': lng,
      'deviceId': deviceId,
      'thresholdFarM': thresholds.farM,
      'thresholdMidM': thresholds.midM,
      'thresholdNearM': thresholds.nearM,
    });

    // Ek güvence: startTracking kaybolursa diye 1s sonra bir de sync gönder.
    // sync listener mevcut GPS konumunu anında alıp UI'a iletir.
    Future.delayed(const Duration(milliseconds: 1000), () {
      service.invoke('sync', {
        'routeId': routeId,
        'name': name,
        'latitude': lat,
        'longitude': lng,
        'deviceId': deviceId,
        'thresholdFarM': thresholds.farM,
        'thresholdMidM': thresholds.midM,
        'thresholdNearM': thresholds.nearM,
      });
    });

    if (context.mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const TrackingPage()),
      );
    }
  }
}
