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
import '../utils/constants.dart';

@pragma('vm:entry-point')
class MyBackgroundService {
  // Production URL — Render deployment
  static const String serverBaseUrl = 'https://wakemeup-fq0i.onrender.com';

  // In-memory state for the background isolate to bypass cross-isolate Hive deadlock issues
  static double? _destLat;
  static double? _destLng;
  static String? _destName;
  static int? _routeId;
  static String? _deviceId;
  static bool _isTracking = false;
  static bool _isMuted = false;
  static AlarmThresholds _thresholds = AlarmThresholds.defaults;

  // Local notification triggers in-memory
  static bool _notified1km = false;
  static bool _notified500m = false;
  static bool _notified250m = false;
  static bool _notifiedArrival = false; // Varış noktasına ulaşıldığında tetiklenir

  // ── SORUN 4 DÜZELTMESİ: ETA (tahmini varış süresi) güvenlik ağı ──────────
  // Sabit metre eşikleri taşıma aracından bağımsız değildir: 1000m eşiği bir
  // yürüyüşte ~12 dakika önceden uyarırken, saatte 120km giden bir trende
  // sadece ~30 saniye önceden uyarır — tam da uyuyakalma riskinin en yüksek
  // olduğu durumda en az reaksiyon süresini bırakır. Aşağıdaki ETA eşikleri
  // mesafe eşiklerinin YERİNE değil, ONLARA EK bir güvenlik ağı olarak
  // çalışır (bkz. _maybeEscalateByEta): hız yüksekse ilgili aşama, mesafe
  // eşiği henüz aşılmamış olsa bile erken tetiklenir.
  static double? _smoothedSpeedMps;
  static const Duration _etaFar = Duration(minutes: 5);
  static const Duration _etaMid = Duration(minutes: 2);
  static const Duration _etaNear = Duration(seconds: 45);

  /// GPS "speed" bu değerin altındayken (dururken/çok yavaşken) ETA
  /// hesaplanmaz — mesafe/hız bölmesi anlamsız derecede büyük/gürültülü
  /// sürelere yol açar.
  static const double _minSpeedForEtaMps = 1.0; // ~3.6 km/h

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
        _deviceId = event['deviceId'] as String? ?? _deviceId;
        _thresholds = _thresholdsFromEvent(event) ?? _thresholds;
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
        _deviceId = event['deviceId'] as String? ?? _deviceId;
        _thresholds = _thresholdsFromEvent(event) ?? AlarmThresholds.defaults;
        _isTracking = true;
        _isMuted = false;
        _notified1km = false;
        _notified500m = false;
        _notified250m = false;
        _notifiedArrival = false; // Yeni oturumda varış bildirimi sıfırla
        _smoothedSpeedMps = null; // Yeni oturumda ETA hız ortalaması sıfırla
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
            _deviceId ??= await HiveService.getDeviceId();
            _thresholds = await HiveService.getThresholds();
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
        _deviceId ??= await HiveService.getDeviceId();
        _thresholds = await HiveService.getThresholds();
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

    // ETA güvenlik ağı: online/offline modundan bağımsız olarak her konum
    // güncellemesinde çalışır; mesafe bazlı tetikleme (backend ya da yerel
    // fallback) ile aynı _notifiedXXX bayraklarını paylaştığı için aynı
    // aşamanın iki kez tetiklenmesi mümkün değildir.
    _maybeEscalateByEta(distance, position.speed, _destName ?? "Hedef");

    // Invoke UI update — 5m veya daha az kaldıysa arrived:true ilet
    debugPrint('[BgService] UI güncelleniyor: distance=$distance');
    service.invoke('update', {
      "latitude": position.latitude,
      "longitude": position.longitude,
      "distance": distance,
      "arrived": distance <= 5,
    });

    // Kalıcı bildirimde canlı mesafeyi göster (yalnızca Android foreground service).
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'WakeMeUp — ${_destName ?? "Hedef"}',
        content: 'Kalan mesafe: ${_formatDistanceForNotification(distance)}',
      );
    }

    // 2. Synchronize with django server API
    if (_routeId != kOfflineRouteId) {
      try {
        final response = await http.post(
          Uri.parse('$serverBaseUrl/api/routes/$_routeId/update-location/'),
          headers: {
            "Content-Type": "application/json",
            "X-Device-Id": _deviceId ?? '',
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

  /// 'sync'/'startTracking' olayıyla gelen eşik verisini [AlarmThresholds]'e çevirir.
  /// Üçü de eksiksiz gelmediyse null döner (çağıran taraf mevcut/varsayılan değeri korur).
  static AlarmThresholds? _thresholdsFromEvent(Map? event) {
    if (event == null) return null;
    final far = (event['thresholdFarM'] as num?)?.toInt();
    final mid = (event['thresholdMidM'] as num?)?.toInt();
    final near = (event['thresholdNearM'] as num?)?.toInt();
    if (far == null || mid == null || near == null) return null;
    return AlarmThresholds(farM: far, midM: mid, nearM: near);
  }

  static String _formatDistanceForNotification(double meters) {
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(2)} km';
    return '${meters.toStringAsFixed(0)} m';
  }

  /// SORUN 4 DÜZELTMESİ: Mesafe eşiklerine ek bir güvenlik ağı. GPS
  /// "speed" alanından (Doppler tabanlı, cihaz tarafından hesaplanır) EMA ile
  /// yumuşatılmış bir hız çıkarır ve tahmini varış süresi (ETA = mesafe/hız)
  /// [_etaFar]/[_etaMid]/[_etaNear] eşiklerinin altına düşerse ilgili aşamayı,
  /// mesafe eşiği henüz aşılmamış olsa bile erken tetikler. Böylece hızlı bir
  /// taşıma aracında (tren/otobüs) sabit metre eşiğinin bırakacağı reaksiyon
  /// süresi, yürüyüşe kıyasla orantısız şekilde kısalmaz.
  static void _maybeEscalateByEta(
    double distanceMeters,
    double? rawSpeedMps,
    String destination,
  ) {
    if (rawSpeedMps == null || rawSpeedMps < 0) return;

    _smoothedSpeedMps = _smoothedSpeedMps == null
        ? rawSpeedMps
        : (_smoothedSpeedMps! * 0.7 + rawSpeedMps * 0.3);

    final double speed = _smoothedSpeedMps!;
    // Dururken/çok yavaşken (ör. yürüyüş molası) ETA anlamsız derecede büyük
    // veya gürültülü olur; bu aşamada yalnızca mesafe eşiklerine güvenilir.
    if (speed < _minSpeedForEtaMps) return;

    final Duration eta = Duration(seconds: (distanceMeters / speed).round());

    if (eta <= _etaNear && !_notified250m) {
      _notified250m = true;
      _notified500m = true;
      _notified1km = true;
      debugPrint('[BgService] ETA güvenlik ağı: ~${eta.inSeconds}sn kaldı (hız=${speed.toStringAsFixed(1)}m/s) — NEAR erken tetiklendi.');
      NotificationService.ringAlarm(
        id: 3,
        title: 'Hedefe Ulaşılmak Üzere! (~${eta.inSeconds}sn kaldı)',
        body: 'Hızınıza göre $destination noktasına yaklaşık ${eta.inSeconds} saniye kaldı.',
      );
    } else if (eta <= _etaMid && !_notified500m) {
      _notified500m = true;
      _notified1km = true;
      debugPrint('[BgService] ETA güvenlik ağı: ~${eta.inMinutes}dk kaldı (hız=${speed.toStringAsFixed(1)}m/s) — MID erken tetiklendi.');
      NotificationService.showAlert(
        id: 2,
        title: 'Hedefe Yaklaşıldı! (~${eta.inMinutes} dk kaldı)',
        body: 'Hızınıza göre $destination noktasına yaklaşık ${eta.inMinutes} dakika kaldı.',
      );
    } else if (eta <= _etaFar && !_notified1km) {
      _notified1km = true;
      debugPrint('[BgService] ETA güvenlik ağı: ~${eta.inMinutes}dk kaldı (hız=${speed.toStringAsFixed(1)}m/s) — FAR erken tetiklendi.');
      NotificationService.showAlert(
        id: 1,
        title: 'Menzile Girildi (~${eta.inMinutes} dk kaldı)',
        body: 'Hızınıza göre $destination noktasına yaklaşık ${eta.inMinutes} dakika kaldı.',
      );
    }
  }

  static void _handleLocalGeofence(double distance, String destination) {
    // Varış noktası: 5 metre veya daha az kaldığında bir kez bildir
    if (distance <= 5 && !_notifiedArrival) {
      _notifiedArrival = true;
      _notified250m = true;
      _notified500m = true;
      _notified1km = true;
      // SORUN 1/2 DÜZELTMESİ: Tek seferlik bildirim yerine, kullanıcı
      // durdurana kadar döngüyle çalan gerçek alarm (bkz. NotificationService.ringAlarm).
      NotificationService.ringAlarm(
        id: 4,
        title: 'Varış Noktasına Ulaşıldı! 🎯',
        body: '$destination hedefine ulaştınız.',
      );
    } else if (distance <= _thresholds.nearM && !_notified250m) {
      _notified250m = true;
      _notified500m = true;
      _notified1km = true;
      NotificationService.ringAlarm(
        id: 3,
        title: 'Hedefe Ulaşılmak Üzere! (${_thresholds.nearM}m)',
        body: '$destination noktasına ${_thresholds.nearM}m mesafe kaldı.',
      );
    } else if (distance <= _thresholds.midM && !_notified500m) {
      _notified500m = true;
      _notified1km = true;
      NotificationService.showAlert(
        id: 2,
        title: 'Hedefe Yaklaşıldı! (${_thresholds.midM}m)',
        body: '$destination noktasına ${_thresholds.midM}m mesafe kaldı.',
      );
    } else if (distance <= _thresholds.farM && !_notified1km) {
      _notified1km = true;
      NotificationService.showAlert(
        id: 1,
        title: 'Menzile Girildi (${_thresholds.farM}m)',
        body: '$destination noktasına ${_thresholds.farM}m mesafe kaldı.',
      );
    }
  }

  static void _triggerIsolateNotification(String stage, String destination) {
    if (stage == 'STAGE_NEAR') {
      _notified250m = true;
      _notified500m = true;
      _notified1km = true;
      NotificationService.ringAlarm(
        id: 3,
        title: 'Hedefe Ulaşılmak Üzere! (${_thresholds.nearM}m)',
        body: '$destination noktasına ${_thresholds.nearM}m mesafe kaldı.',
      );
    } else if (stage == 'STAGE_MID') {
      _notified500m = true;
      _notified1km = true;
      NotificationService.showAlert(
        id: 2,
        title: 'Hedefe Yaklaşıldı! (${_thresholds.midM}m)',
        body: '$destination noktasına ${_thresholds.midM}m mesafe kaldı.',
      );
    } else if (stage == 'STAGE_FAR') {
      _notified1km = true;
      NotificationService.showAlert(
        id: 1,
        title: 'Menzile Girildi (${_thresholds.farM}m)',
        body: '$destination noktasına ${_thresholds.farM}m mesafe kaldı.',
      );
    }
  }
}
