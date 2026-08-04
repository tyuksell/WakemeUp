import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'hive_service.dart';
import 'notification_service.dart';
import '../utils/distance_calculator.dart';

@pragma('vm:entry-point')
class MyBackgroundService {
  // Production setting: Replace with your public server IP or domain when testing on a real device
  static const String serverBaseUrl = 'https://coveting-finless-cosmetics.ngrok-free.dev'; // Ngrok public URL

  // In-memory state for the background isolate to bypass cross-isolate Hive deadlock issues
  static double? _destLat;
  static double? _destLng;
  static String? _destName;
  static int? _routeId;
  static bool _isTracking = false;
  static bool _isMuted = false;

  // Local notification triggers in-memory
  static bool _notified1km = false;
  static bool _notified500m = false;
  static bool _notified250m = false;
  static bool _notifiedArrival = false; // Varış noktasına ulaşıldığında tetiklenir

  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();
    
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: NotificationService.serviceChannelId,
        initialNotificationTitle: 'Geofence Takibi',
        initialNotificationContent: 'Konum takibi arka planda aktif.',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    return true;
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();
    debugPrint('[BgService] onStart entry point.');
    
    // Initialize notifications only since it's stateless and doesn't hit database locks
    try {
      await NotificationService.init();
      debugPrint('[BgService] NotificationService initialized successfully.');
    } catch (e) {
      debugPrint('[BgService] NotificationService init failed: $e');
    }

    // Register all listeners synchronously so they receive events immediately
    if (service is AndroidServiceInstance) {
      service.on('setAsForeground').listen((event) {
        service.setAsForegroundService();
      });
      service.on('setAsBackground').listen((event) {
        service.setAsBackgroundService();
      });
    }

    service.on('stopService').listen((event) async {
      debugPrint('[BgService] stopService tetiklendi.');
      _isTracking = false;
      service.stopSelf();
    });

    service.on('sync').listen((event) async {
      debugPrint('[BgService] sync tetiklendi.');
      if (event != null) {
        _routeId = event['routeId'] as int? ?? _routeId;
        _destName = event['name'] as String? ?? _destName;
        _destLat = (event['latitude'] as num?)?.toDouble() ?? _destLat;
        _destLng = (event['longitude'] as num?)?.toDouble() ?? _destLng;
        _isTracking = true;
        debugPrint('[BgService] sync update: Hedef=$_destName, Lat=$_destLat, Lng=$_destLng');
      }
      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 10),
          ),
        );
        await _processPosition(service, position);
      } catch (e) {
        debugPrint('[BgService] sync konum alınamadı: $e');
        try {
          final lastPosition = await Geolocator.getLastKnownPosition();
          if (lastPosition != null) {
            debugPrint('[BgService] sync fallback olarak son bilinen konum kullanılıyor.');
            await _processPosition(service, lastPosition);
          }
        } catch (err) {
          debugPrint('[BgService] sync fallback de başarısız: $err');
        }
      }
    });

    service.on('startTracking').listen((event) async {
      debugPrint('[BgService] startTracking tetiklendi.');
      if (event != null) {
        _routeId = event['routeId'] as int?;
        _destName = event['name'] as String?;
        _destLat = (event['latitude'] as num?)?.toDouble();
        _destLng = (event['longitude'] as num?)?.toDouble();
        _isTracking = true;
        _isMuted = false;
        _notified1km = false;
        _notified500m = false;
        _notified250m = false;
        _notifiedArrival = false; // Yeni oturumda varış bildirimi sıfırla
        debugPrint('[BgService] startTracking: Hedef=$_destName, Lat=$_destLat, Lng=$_destLng');
        await _acquireAndProcess(service);
      }
    });

    // ── Sürekli konum akışı (her 15 metrede bir) ───────────────────────────
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 15,
      ),
    ).listen((Position position) async {
      debugPrint('[BgService] Stream üzerinden yeni konum geldi.');

      // İzolat yeniden başlatılmışsa (_isTracking false iken stream gelirse)
      // Hive'dan tracking durumunu ve koordinatları yükle.
      if (!_isTracking) {
        try {
          final bool isTracking = await HiveService.getIsTracking();
          if (isTracking) {
            _routeId ??= await HiveService.getActiveRouteId();
            _destName ??= await HiveService.getDestName();
            _destLat ??= await HiveService.getDestLatitude();
            _destLng ??= await HiveService.getDestLongitude();
            final bool isMuted = await HiveService.getIsMuted();
            _isTracking = true;
            _isMuted = isMuted;
            debugPrint('[BgService] Stream: Hive\'dan takip durumu geri yüklendi — '
                'Hedef=$_destName Lat=$_destLat Lng=$_destLng');
          }
        } catch (e) {
          debugPrint('[BgService] Stream: Hive okuma hatası: $e');
        }
      }

      await _processPosition(service, position);
    });
  }

  /// Taze konum alır ve işler.
  static Future<void> _acquireAndProcess(ServiceInstance service) async {
    try {
      debugPrint('[BgService] Mevcut konum alınıyor...');
      final Position initialPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      debugPrint('[BgService] Mevcut konum alındı, işleniyor.');
      await _processPosition(service, initialPosition);
    } catch (e) {
      debugPrint('[BgService] Konum alınamadı (Initial): $e');
      try {
        final lastPosition = await Geolocator.getLastKnownPosition();
        if (lastPosition != null) {
          debugPrint('[BgService] Initial fallback olarak son bilinen konum kullanılıyor.');
          await _processPosition(service, lastPosition);
        }
      } catch (err) {
        debugPrint('[BgService] Initial fallback de başarısız: $err');
      }
    }
  }

  /// Tek bir konum güncellemesini işler:
  /// mesafe hesaplar, UI'ı günceller, API'ye bildirir.
  static Future<void> _processPosition(
    ServiceInstance service,
    Position position,
  ) async {
    if (!_isTracking || _isMuted) {
      debugPrint('[BgService] Konum işleme pas geçildi: _isTracking=$_isTracking, _isMuted=$_isMuted');
      return;
    }

    // SORUN 4 DÜZELTMESİ: Koordinatlar null ise Hive'dan fallback olarak yükle.
    // Bu durum; servis event kaybından (race condition), izolat yeniden başlatılmasından
    // veya cihaz uyanmasından kaynaklanabilir.
    if (_destLat == null || _destLng == null || _routeId == null) {
      debugPrint('[BgService] Koordinatlar null — Hive\'dan yüklemeye çalışılıyor...');
      try {
        _routeId ??= await HiveService.getActiveRouteId();
        _destName ??= await HiveService.getDestName();
        final double? hiveLat = await HiveService.getDestLatitude();
        final double? hiveLng = await HiveService.getDestLongitude();
        if (hiveLat != null && hiveLat != 0.0) _destLat = hiveLat;
        if (hiveLng != null && hiveLng != 0.0) _destLng = hiveLng;
        debugPrint('[BgService] Hive fallback: Hedef=$_destName, '
            'Lat=$_destLat, Lng=$_destLng, RouteId=$_routeId');
      } catch (e) {
        debugPrint('[BgService] Hive fallback okuma hatası: $e');
      }
    }

    if (_destLat == null || _destLng == null || _routeId == null) {
      debugPrint('[BgService] UYARI: destLat/destLng/routeId Hive\'dan da alınamadı — mesafe hesaplanamıyor.');
      return;
    }

    // LOGLAMA: Koordinatların doğru geçtiğini doğrula
    debugPrint('[BgService] Mevcut: lat=${position.latitude.toStringAsFixed(6)}, '
        'lng=${position.longitude.toStringAsFixed(6)}, '
        'accuracy=${position.accuracy.toStringAsFixed(1)}m');
    debugPrint('[BgService] Hedef : lat=${_destLat!.toStringAsFixed(6)}, '
        'lng=${_destLng!.toStringAsFixed(6)}');

    // Güvenlik: Null Island (0,0) kontrolü
    if (position.latitude == 0.0 && position.longitude == 0.0) {
      debugPrint('[BgService] UYARI: Mevcut konum (0,0) — GPS sinyali yok!');
    }

    // 1. Haversine ile kuş uçuşu mesafeyi hesapla
    final double distance = DistanceCalculator.calculateDistance(
      position.latitude,
      position.longitude,
      _destLat!,
      _destLng!,
    );

    debugPrint('[BgService] Hesaplanan mesafe: ${distance.toStringAsFixed(1)} m');

    // Hız hesaplama kaldırıldı

    // Invoke UI update — 5m veya daha az kaldıysa arrived:true ilet
    print('[BackgroundService] Hive yazılıyor: distance=$distance');
    service.invoke('update', {
      "latitude": position.latitude,
      "longitude": position.longitude,
      "distance": distance,
      "arrived": distance <= 5,
    });

    // 2. Synchronize with django server API
    if (_routeId != 9999) {
      try {
        final response = await http.post(
          Uri.parse('$serverBaseUrl/api/routes/$_routeId/update-location/'),
          headers: {
            "Content-Type": "application/json",
            "ngrok-skip-browser-warning": "true",
          },
          body: jsonEncode({
            "current_latitude": position.latitude,
            "current_longitude": position.longitude,
          }),
        ).timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final bool backendMuted = data['is_muted'] ?? false;
          final bool triggerAlarm = data['trigger_alarm'] ?? false;
          final String targetStage = data['target_stage'] ?? 'OUT_OF_RANGE';

          if (backendMuted) {
            _isMuted = true;
            service.invoke('backendMute');
            service.stopSelf();
            return;
          }

          if (triggerAlarm) {
            _triggerIsolateNotification(targetStage, _destName ?? "Hedef");
          }
        } else {
          _handleLocalGeofence(distance, _destName ?? "Hedef");
        }
      } catch (e) {
        _handleLocalGeofence(distance, _destName ?? "Hedef");
      }
    } else {
      _handleLocalGeofence(distance, _destName ?? "Hedef");
    }
  }

  static void _handleLocalGeofence(double distance, String destination) {
    // Varış noktası: 5 metre veya daha az kaldığında bir kez bildir
    if (distance <= 5 && !_notifiedArrival) {
      _notifiedArrival = true;
      _notified250m = true;
      _notified500m = true;
      _notified1km = true;
      NotificationService.showAlert(
        id: 4,
        title: 'Varış Noktasına Ulaşıldı! 🎯',
        body: '$destination hedefine ulaştınız.',
      );
    } else if (distance <= 250 && !_notified250m) {
      _notified250m = true;
      _notified500m = true;
      _notified1km = true;
      NotificationService.showAlert(
        id: 3,
        title: 'Hedefe Ulaşılmak Üzere! (250m)',
        body: '$destination noktasına 250m mesafe kaldı.',
      );
    } else if (distance <= 500 && !_notified500m) {
      _notified500m = true;
      _notified1km = true;
      NotificationService.showAlert(
        id: 2,
        title: 'Hedefe Yaklaşıldı! (500m)',
        body: '$destination noktasına 500m mesafe kaldı.',
      );
    } else if (distance <= 1000 && !_notified1km) {
      _notified1km = true;
      NotificationService.showAlert(
        id: 1,
        title: 'Menzile Girildi (1km)',
        body: '$destination noktasına 1km mesafe kaldı.',
      );
    }
  }

  static void _triggerIsolateNotification(String stage, String destination) {
    if (stage == 'STAGE_ARRIVED') {
      _notifiedArrival = true;
      _notified250m = true;
      _notified500m = true;
      _notified1km = true;
      NotificationService.showAlert(
        id: 4,
        title: 'Varış Noktasına Ulaşıldı! 🎯',
        body: '$destination hedefine ulaştınız.',
      );
    } else if (stage == 'STAGE_250M') {
      _notified250m = true;
      _notified500m = true;
      _notified1km = true;
      NotificationService.showAlert(
        id: 3,
        title: 'Hedefe Ulaşılmak Üzere! (250m)',
        body: '$destination noktasına 250m mesafe kaldı.',
      );
    } else if (stage == 'STAGE_500M') {
      _notified500m = true;
      _notified1km = true;
      NotificationService.showAlert(
        id: 2,
        title: 'Hedefe Yaklaşıldı! (500m)',
        body: '$destination noktasına 500m mesafe kaldı.',
      );
    } else if (stage == 'STAGE_1KM') {
      _notified1km = true;
      NotificationService.showAlert(
        id: 1,
        title: 'Menzile Girildi (1km)',
        body: '$destination noktasına 1km mesafe kaldı.',
      );
    }
  }
}
